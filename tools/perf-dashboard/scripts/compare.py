#!/usr/bin/env python3
"""Statistical comparison of baseline vs candidate benchmark results."""

import argparse
import math
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(SCRIPT_DIR, "..", "db", "perf.db")

try:
    from scipy.stats import mannwhitneyu
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False


def heuristic_p_value(b_mean, b_std, c_mean, c_std):
    """Fallback p-value estimate when scipy is not available.

    Uses overlap of mean +/- 2*stddev ranges as a rough significance indicator.
    """
    b_lo, b_hi = b_mean - 2 * b_std, b_mean + 2 * b_std
    c_lo, c_hi = c_mean - 2 * c_std, c_mean + 2 * c_std

    overlap = max(0, min(b_hi, c_hi) - max(b_lo, c_lo))
    total_range = max(b_hi, c_hi) - min(b_lo, c_lo)

    if total_range == 0:
        return 1.0

    overlap_ratio = overlap / total_range
    # Low overlap → likely significant (low p-value)
    return min(1.0, overlap_ratio)


def compute_cohen_d(b_mean, b_std, c_mean, c_std):
    """Cohen's d effect size: positive means baseline is faster (improvement)."""
    pooled_std = math.sqrt((b_std ** 2 + c_std ** 2) / 2)
    if pooled_std == 0:
        return 0.0
    return (b_mean - c_mean) / pooled_std


def main():
    parser = argparse.ArgumentParser(description="Compare baseline vs candidate benchmark results")
    parser.add_argument("--loop-run", required=True, help="Loop run ID")
    parser.add_argument("--db", default=DEFAULT_DB, help="Path to SQLite database")
    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    if not os.path.exists(db_path):
        print(f"Error: database not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        # Get paired baseline/candidate results
        rows = conn.execute("""
            SELECT
                b.full_name,
                b.mean_ns AS b_mean, b.stddev_ns AS b_std, b.allocated_bytes AS b_alloc,
                c.mean_ns AS c_mean, c.stddev_ns AS c_std, c.allocated_bytes AS c_alloc
            FROM benchmark_results b
            JOIN benchmark_results c
                ON b.loop_run_id = c.loop_run_id AND b.full_name = c.full_name
            WHERE b.loop_run_id = ? AND b.side = 'baseline' AND c.side = 'candidate'
        """, (args.loop_run,)).fetchall()

        if not rows:
            print(f"No paired results found for {args.loop_run}", file=sys.stderr)
            sys.exit(1)

        results = []
        for row in rows:
            full_name = row["full_name"]
            b_mean = row["b_mean"]
            c_mean = row["c_mean"]
            b_std = row["b_std"] or 0
            c_std = row["c_std"] or 0
            b_alloc = row["b_alloc"]
            c_alloc = row["c_alloc"]

            # Delta mean %
            delta_mean_pct = ((c_mean - b_mean) / b_mean * 100) if b_mean else 0

            # Delta alloc %
            delta_alloc_pct = None
            if b_alloc is not None and c_alloc is not None and b_alloc > 0:
                delta_alloc_pct = (c_alloc - b_alloc) / b_alloc * 100
            elif b_alloc is not None and c_alloc is not None:
                if b_alloc == 0 and c_alloc == 0:
                    delta_alloc_pct = 0.0
                elif b_alloc == 0:
                    delta_alloc_pct = 100.0  # went from 0 to something

            # P-value
            if HAS_SCIPY and b_std > 0 and c_std > 0:
                # Generate synthetic samples from reported stats for Mann-Whitney
                # BDN reports summary stats, not raw samples, so we approximate
                import numpy as np
                rng = np.random.default_rng(42)
                b_samples = rng.normal(b_mean, b_std, 100)
                c_samples = rng.normal(c_mean, c_std, 100)
                try:
                    _, p_value = mannwhitneyu(b_samples, c_samples, alternative="two-sided")
                except ValueError:
                    p_value = heuristic_p_value(b_mean, b_std, c_mean, c_std)
            else:
                p_value = heuristic_p_value(b_mean, b_std, c_mean, c_std)

            # Significance
            is_significant = 1 if p_value < 0.05 else 0

            # Effect size (Cohen's d)
            effect_size = compute_cohen_d(b_mean, b_std, c_mean, c_std)

            # 95% CI approximation
            if b_mean > 0:
                relative_stderr = math.sqrt(b_std ** 2 + c_std ** 2) / b_mean * 100
                ci_lower = delta_mean_pct - 1.96 * relative_stderr
                ci_upper = delta_mean_pct + 1.96 * relative_stderr
            else:
                ci_lower = ci_upper = 0

            results.append({
                "full_name": full_name,
                "delta_mean_pct": delta_mean_pct,
                "delta_alloc_pct": delta_alloc_pct,
                "p_value": p_value,
                "is_significant": is_significant,
                "effect_size": effect_size,
                "ci_lower_pct": ci_lower,
                "ci_upper_pct": ci_upper,
                "baseline_mean_ns": b_mean,
                "candidate_mean_ns": c_mean,
                "baseline_alloc": b_alloc,
                "candidate_alloc": c_alloc,
            })

            # Upsert into comparisons
            conn.execute("""
                INSERT INTO comparisons
                    (loop_run_id, full_name, delta_mean_pct, delta_alloc_pct,
                     p_value, is_significant, effect_size, ci_lower_pct, ci_upper_pct,
                     baseline_mean_ns, candidate_mean_ns, baseline_alloc, candidate_alloc)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(loop_run_id, full_name) DO UPDATE SET
                    delta_mean_pct=excluded.delta_mean_pct,
                    delta_alloc_pct=excluded.delta_alloc_pct,
                    p_value=excluded.p_value,
                    is_significant=excluded.is_significant,
                    effect_size=excluded.effect_size,
                    ci_lower_pct=excluded.ci_lower_pct,
                    ci_upper_pct=excluded.ci_upper_pct,
                    baseline_mean_ns=excluded.baseline_mean_ns,
                    candidate_mean_ns=excluded.candidate_mean_ns,
                    baseline_alloc=excluded.baseline_alloc,
                    candidate_alloc=excluded.candidate_alloc,
                    computed_at=datetime('now')
            """, (args.loop_run, full_name, delta_mean_pct, delta_alloc_pct,
                  p_value, is_significant, effect_size, ci_lower, ci_upper,
                  b_mean, c_mean, b_alloc, c_alloc))

        conn.commit()

        # Print markdown table
        print(f"\n## Comparison: {args.loop_run}\n")
        print("| Benchmark | Baseline (ns) | Candidate (ns) | Delta | Alloc Delta | p-value | Sig | Effect |")
        print("|-----------|--------------|----------------|-------|-------------|---------|-----|--------|")
        for r in results:
            short_name = r["full_name"].rsplit(".", 1)[-1] if "." in r["full_name"] else r["full_name"]
            alloc_str = f"{r['delta_alloc_pct']:+.1f}%" if r["delta_alloc_pct"] is not None else "N/A"
            sig_mark = "**YES**" if r["is_significant"] else "no"
            print(f"| {short_name} | {r['baseline_mean_ns']:.1f} | {r['candidate_mean_ns']:.1f} "
                  f"| {r['delta_mean_pct']:+.1f}% | {alloc_str} "
                  f"| {r['p_value']:.3f} | {sig_mark} | {r['effect_size']:.2f} |")

        # Recommendation
        significant_improvements = [r for r in results if r["is_significant"] and r["delta_mean_pct"] < -5]
        significant_regressions = [r for r in results if r["is_significant"] and r["delta_mean_pct"] > 0]
        any_improvements = [r for r in results if r["delta_mean_pct"] < 0]

        print()
        if significant_improvements and not significant_regressions:
            print("**Recommendation: MERGE** — Significant improvement(s) detected, no regressions.")
        elif any_improvements and not significant_regressions:
            print("**Recommendation: ITERATE** — Improvements exist but below significance threshold or <5%.")
        elif significant_regressions:
            print("**Recommendation: DISCARD** — Regression(s) detected.")
        else:
            print("**Recommendation: ITERATE** — Mixed or inconclusive results.")

    finally:
        conn.close()


if __name__ == "__main__":
    main()
