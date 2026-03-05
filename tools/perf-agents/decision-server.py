#!/usr/bin/env python3
"""
Decision Server v2 — single HTTP server for dashboard data + human decisions.

All dashboard data comes from SQLite via /api/* endpoints.
No JSON files on disk, no export script, no stale data.

Usage:
    python tools/perf-agents/decision-server.py --port 4040

Endpoints:
    GET  /                  → React dashboard (static files from dist/ or dev)
    GET  /api/loops         → All loop runs with comparison summaries
    GET  /api/progress      → Performance index time series
    GET  /api/benchmarks    → Key benchmark trends
    GET  /api/agents        → Agent stats, area effectiveness, failures
    GET  /api/pending       → Pending decisions with detailed context
    GET  /api/workers       → Live worker status from run/status/*.json
    POST /api/decision      → Submit approve/discard verdict
"""

import http.server
import json
import mimetypes
import os
import sqlite3
import subprocess
import sys
import urllib.parse
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent.parent
DB_PATH = REPO_ROOT / "tools" / "perf-dashboard" / "db" / "perf.db"
DASHBOARD_DIST = REPO_ROOT / "tools" / "perf-dashboard" / "dashboard" / "dist"
DASHBOARD_DEV = REPO_ROOT / "tools" / "perf-dashboard" / "dashboard"
STATUS_DIR = SCRIPT_DIR / "run" / "status"
LOOP_STATE_ROOT = REPO_ROOT / "loop-state"
WORKTREE_ROOT = REPO_ROOT / ".worktrees"


# ── SQLite helpers ───────────────────────────────────────────────────────────

def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def rows_to_dicts(cursor) -> list[dict]:
    cols = [d[0] for d in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]


# ── API: /api/loops ──────────────────────────────────────────────────────────

def api_loops() -> list[dict]:
    """All loop runs with comparison summaries. Same shape as export_dashboard_data loops.json."""
    conn = get_db()
    try:
        # Use the view if it exists, otherwise join manually
        try:
            cursor = conn.execute("SELECT * FROM v_loop_summary ORDER BY created_at DESC")
            rows = rows_to_dicts(cursor)
        except sqlite3.OperationalError:
            # View doesn't exist, do the join
            cursor = conn.execute("""
                SELECT lr.*,
                    COUNT(c.id) as compared_benchmarks,
                    MIN(c.delta_mean_pct) as best_delta_pct,
                    AVG(c.delta_mean_pct) as avg_delta_pct,
                    SUM(CASE WHEN c.is_significant=1 AND c.delta_mean_pct<0 THEN 1 ELSE 0 END) as significant_improvements,
                    SUM(CASE WHEN c.is_significant=1 AND c.delta_mean_pct>0 THEN 1 ELSE 0 END) as significant_regressions
                FROM loop_runs lr
                LEFT JOIN comparisons c ON lr.id = c.loop_run_id
                GROUP BY lr.id
                ORDER BY lr.created_at DESC
            """)
            rows = rows_to_dicts(cursor)

        return [{
            "id": r.get("id"),
            "targetId": r.get("target_id"),
            "targetArea": r.get("target_area"),
            "hypothesis": r.get("hypothesis"),
            "approach": r.get("approach"),
            "status": "merged" if r.get("status") == "done" else r.get("status"),
            "verdict": r.get("verdict"),
            "difficulty": r.get("difficulty"),
            "impact": r.get("expected_impact"),
            "branch": r.get("branch"),
            "agent": r.get("agent_type"),
            "cost": r.get("cost_usd") or 0,
            "tokens": r.get("total_tokens") or 0,
            "iterations": r.get("iterations") or 0,
            "date": (r.get("created_at") or "")[:10] or None,
            "deltaMean": r.get("avg_delta_pct"),
            "deltaAlloc": None,
            "confidence": r.get("verdict_confidence"),
            "pValue": None,
            "comparedBenchmarks": r.get("compared_benchmarks"),
            "significantImprovements": r.get("significant_improvements"),
            "significantRegressions": r.get("significant_regressions"),
            "bestDeltaPct": r.get("best_delta_pct"),
        } for r in rows]
    finally:
        conn.close()


# ── API: /api/progress ───────────────────────────────────────────────────────

def api_progress() -> list[dict]:
    conn = get_db()
    try:
        cursor = conn.execute("SELECT * FROM progress_snapshots ORDER BY snapshot_date")
        return [{
            "date": r["snapshot_date"],
            "perfIndex": r["perf_index"],
            "evmIndex": r["evm_index"],
            "trieIndex": r["trie_index"],
            "stateIndex": r["state_index"],
            "rlpIndex": r["rlp_index"],
            "dbIndex": r["db_index"],
            "bpIndex": r["bp_index"],
            "noiseFloor": r["noise_floor_pct"],
            "triggerLoopId": r["trigger_loop_id"],
        } for r in cursor.fetchall()]
    finally:
        conn.close()


# ── API: /api/benchmarks ────────────────────────────────────────────────────

def api_benchmarks() -> list[dict]:
    conn = get_db()
    try:
        # Try key benchmarks first, fall back to all
        cursor = conn.execute(
            "SELECT full_name, short_name FROM benchmark_registry WHERE is_key_benchmark = 1"
        )
        key_benchmarks = cursor.fetchall()

        if not key_benchmarks:
            cursor = conn.execute(
                "SELECT DISTINCT full_name, full_name as short_name FROM benchmark_results WHERE side='candidate'"
            )
            key_benchmarks = cursor.fetchall()

        trends = []
        for row in key_benchmarks:
            full_name = row["full_name"]
            short_name = row["short_name"] or full_name.rsplit(".", 1)[-1]

            data = conn.execute("""
                SELECT lr.created_at, br.mean_ns
                FROM benchmark_results br
                JOIN loop_runs lr ON br.loop_run_id = lr.id
                WHERE br.full_name = ? AND br.side = 'candidate'
                ORDER BY lr.created_at
            """, (full_name,)).fetchall()

            points = [{"date": (r["created_at"] or "")[:10], "ns": r["mean_ns"]} for r in data]
            if points:
                trends.append({"name": short_name, "data": points})

        return trends
    finally:
        conn.close()


# ── API: /api/agents ─────────────────────────────────────────────────────────

def api_agents() -> dict:
    conn = get_db()
    try:
        # Agent stats
        agent_stats = []
        try:
            for r in conn.execute("SELECT * FROM v_agent_stats").fetchall():
                agent_stats.append({
                    "agent": r["agent_type"],
                    "loops": r["total_loops"],
                    "improvements": r["improvements"],
                    "regressions": r["regressions"],
                    "neutral": r["neutrals"],
                    "inProgress": r["in_progress"],
                    "hitRate": r["hit_rate_pct"] or 0,
                    "avgCost": r["avg_cost"] or 0,
                    "totalCost": r["total_cost"] or 0,
                    "avgTokens": r["avg_tokens"] or 0,
                })
        except sqlite3.OperationalError:
            pass

        # Area effectiveness
        area_map = {"evm": "EVM", "trie": "Trie", "state": "State",
                     "rlp": "RLP", "db": "DB", "bp": "Block Proc"}
        areas = []
        try:
            for r in conn.execute("SELECT * FROM v_area_stats").fetchall():
                areas.append({
                    "area": area_map.get(r["target_area"], r["target_area"]),
                    "attempted": r["attempted"],
                    "improved": r["improved"],
                    "hitRate": r["hit_rate_pct"] or 0,
                    "avgDelta": r["avg_significant_delta"] or 0,
                })
        except sqlite3.OperationalError:
            pass

        # Failure taxonomy
        total_disc = conn.execute(
            "SELECT COUNT(*) as c FROM loop_runs WHERE status='discarded'"
        ).fetchone()["c"]

        regression_c = conn.execute(
            "SELECT COUNT(*) as c FROM loop_runs WHERE verdict='regression'"
        ).fetchone()["c"]
        neutral_c = conn.execute(
            "SELECT COUNT(*) as c FROM loop_runs WHERE verdict='neutral'"
        ).fetchone()["c"]
        error_c = conn.execute(
            "SELECT COUNT(*) as c FROM loop_runs WHERE status='error'"
        ).fetchone()["c"]
        inconclusive_c = conn.execute(
            "SELECT COUNT(*) as c FROM loop_runs WHERE verdict='inconclusive'"
        ).fetchone()["c"]

        failures = []
        for reason, count in [
            ("Below noise floor", neutral_c),
            ("Regression detected", regression_c),
            ("Agent gave up", error_c),
            ("Inconclusive", inconclusive_c),
        ]:
            pct = (count / total_disc * 100) if total_disc > 0 else 0
            failures.append({"reason": reason, "count": count, "pct": round(pct, 1)})

        return {
            "agentStats": agent_stats,
            "areaEffectiveness": areas,
            "failureTaxonomy": failures,
        }
    finally:
        conn.close()


# ── API: /api/pending ────────────────────────────────────────────────────────

def api_pending() -> list[dict]:
    """Pending decisions with full benchmark detail, hypothesis text, diff stats."""
    conn = get_db()
    try:
        runs = conn.execute("""
            SELECT lr.*,
                COUNT(c.id) as compared_benchmarks,
                MIN(c.delta_mean_pct) as best_delta_pct,
                SUM(CASE WHEN c.is_significant=1 AND c.delta_mean_pct<0 THEN 1 ELSE 0 END) as improvements,
                SUM(CASE WHEN c.is_significant=1 AND c.delta_mean_pct>0 THEN 1 ELSE 0 END) as regressions
            FROM loop_runs lr
            LEFT JOIN comparisons c ON lr.id = c.loop_run_id
            WHERE lr.status = 'pending_decision'
            GROUP BY lr.id
            ORDER BY lr.updated_at DESC
        """).fetchall()

        results = []
        for run in runs:
            d = dict(run)

            # Per-benchmark comparisons
            comparisons = conn.execute("""
                SELECT full_name, delta_mean_pct, delta_alloc_pct,
                       p_value, is_significant, effect_size,
                       baseline_mean_ns, candidate_mean_ns,
                       baseline_alloc, candidate_alloc
                FROM comparisons WHERE loop_run_id = ?
                ORDER BY ABS(delta_mean_pct) DESC
            """, (d["id"],)).fetchall()
            d["comparisons"] = [dict(c) for c in comparisons]

            # Read markdown artifacts from loop-state (check worktree first, then repo root)
            for dirname in [d.get("worktree_path", ""), str(REPO_ROOT)]:
                if not dirname:
                    continue
                state_dir = Path(dirname) / "loop-state" / d["id"]
                for fname, key in [
                    ("hypothesis.md", "hypothesis_full"),
                    ("research-brief.md", "research_brief"),
                    ("measurement-report.md", "measurement_report"),
                ]:
                    fpath = state_dir / fname
                    if fpath.exists() and key not in d:
                        try:
                            d[key] = fpath.read_text(errors="replace")[:10000]
                        except OSError:
                            pass

            # Git diff stats
            branch = d.get("branch", "")
            if branch:
                try:
                    diff_stat = subprocess.check_output(
                        ["git", "diff", "--stat", "perf-ai/setup", branch],
                        cwd=str(REPO_ROOT), timeout=10, stderr=subprocess.DEVNULL,
                    ).decode().strip()
                    d["diff_stat"] = diff_stat
                except (subprocess.SubprocessError, FileNotFoundError):
                    d["diff_stat"] = ""

            results.append(d)

        return results
    finally:
        conn.close()


# ── API: /api/workers ────────────────────────────────────────────────────────

def _pid_alive(pid: int) -> bool:
    """Check if a process is running (cross-platform)."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def api_workers() -> list[dict]:
    """Live worker status from run/status/*.json files. Removes stale entries."""
    results = []
    if STATUS_DIR.exists():
        for f in sorted(STATUS_DIR.glob("*.json")):
            try:
                data = json.loads(f.read_text())
                pid = data.get("pid", 0)
                if pid and _pid_alive(pid):
                    data["alive"] = True
                    results.append(data)
                else:
                    f.unlink(missing_ok=True)
            except (json.JSONDecodeError, OSError):
                pass
    return results


# ── API: POST /api/decision ──────────────────────────────────────────────────

def api_decision(body: dict) -> dict:
    """
    Submit a human decision.
    On approve: push branch + create PR. If autoMerge=true, squash-merge immediately.
    On discard: update status, delete remote branch.
    """
    loop_run_id = body.get("loopRunId", "")
    verdict = body.get("verdict", "")
    notes = body.get("notes", "")
    auto_merge = body.get("autoMerge", False)

    valid = {"improvement", "regression", "neutral", "inconclusive"}
    if verdict not in valid:
        return {"error": f"Invalid verdict. Must be one of: {list(valid)}"}
    if not loop_run_id:
        return {"error": "loopRunId is required"}

    conn = get_db()
    try:
        row = conn.execute(
            "SELECT id, status, branch, target_id, worktree_path FROM loop_runs WHERE id = ?",
            (loop_run_id,)
        ).fetchone()
        if not row:
            return {"error": f"Loop run {loop_run_id} not found"}
        if row["status"] != "pending_decision":
            return {"error": f"Not pending (status: {row['status']})"}

        branch = row["branch"] or ""
        target_id = row["target_id"] or ""
        worktree = row["worktree_path"] or ""

        # Compute confidence from comparison p-values
        p_rows = conn.execute(
            "SELECT p_value FROM comparisons WHERE loop_run_id = ? AND is_significant = 1",
            (loop_run_id,)
        ).fetchall()
        confidence = 0.0
        if p_rows:
            confidence = sum(1 - r["p_value"] for r in p_rows) / len(p_rows)

        # Update SQLite
        new_status = "done" if verdict == "improvement" else "discarded"
        conn.execute("""
            UPDATE loop_runs
            SET verdict=?, verdict_notes=?, verdict_confidence=?,
                status=?, updated_at=datetime('now')
            WHERE id=?
        """, (verdict, notes, confidence, new_status, loop_run_id))
        conn.commit()

        result = {
            "ok": True,
            "loopRunId": loop_run_id,
            "verdict": verdict,
            "status": new_status,
        }

        # ── On approve: push + create PR ──
        if verdict == "improvement" and branch:
            # Ensure branch is pushed (might already be)
            try:
                subprocess.run(
                    ["git", "push", "origin", branch],
                    cwd=str(REPO_ROOT), timeout=60,
                    capture_output=True,
                )
            except subprocess.SubprocessError:
                pass

            # Create PR via gh CLI
            if _gh_available():
                # Read measurement report for PR body
                pr_body = f"## Loop Run: {loop_run_id}\n\n"
                report_path = None
                for base in [worktree, str(REPO_ROOT)]:
                    if not base:
                        continue
                    p = Path(base) / "loop-state" / loop_run_id / "measurement-report.md"
                    if p.exists():
                        report_path = p
                        break
                if report_path:
                    pr_body += report_path.read_text(errors="replace")[:5000]
                pr_body += "\n\n---\n*Generated by perf-ai agent system*"

                # Best delta for title
                best = conn.execute(
                    "SELECT MIN(delta_mean_pct) as d FROM comparisons WHERE loop_run_id=? AND is_significant=1",
                    (loop_run_id,)
                ).fetchone()
                delta_str = f"{best['d']:.1f}%" if best and best["d"] else "improvement"

                try:
                    pr_result = subprocess.run(
                        ["gh", "pr", "create",
                         "--base", "perf-ai/setup",
                         "--head", branch,
                         "--title", f"perf({target_id}): AI-optimized — {delta_str}",
                         "--body", pr_body],
                        cwd=str(REPO_ROOT), timeout=30,
                        capture_output=True, text=True,
                    )
                    if pr_result.returncode == 0:
                        pr_url = pr_result.stdout.strip()
                        result["pr_url"] = pr_url

                        # Auto-merge: squash-merge the PR immediately
                        if auto_merge:
                            try:
                                merge_result = subprocess.run(
                                    ["gh", "pr", "merge", branch,
                                     "--squash",
                                     "--delete-branch",
                                     "--subject", f"perf({target_id}): AI-optimized — {delta_str}"],
                                    cwd=str(REPO_ROOT), timeout=60,
                                    capture_output=True, text=True,
                                )
                                if merge_result.returncode == 0:
                                    result["merged"] = True
                                else:
                                    result["merged"] = False
                                    result["merge_error"] = merge_result.stderr.strip()[:200]
                            except subprocess.SubprocessError as e:
                                result["merged"] = False
                                result["merge_error"] = str(e)[:200]
                        else:
                            result["merged"] = False
                except subprocess.SubprocessError:
                    pass

        # ── On discard: delete remote branch ──
        elif verdict != "improvement" and branch:
            try:
                subprocess.run(
                    ["git", "push", "origin", "--delete", branch],
                    cwd=str(REPO_ROOT), timeout=30,
                    capture_output=True,
                )
            except subprocess.SubprocessError:
                pass

        # ── Clean up worktree (for both outcomes) ──
        if worktree and Path(worktree).exists():
            try:
                subprocess.run(
                    ["git", "worktree", "remove", worktree, "--force"],
                    cwd=str(REPO_ROOT), timeout=30,
                    capture_output=True,
                )
            except subprocess.SubprocessError:
                pass

        return result
    finally:
        conn.close()


def _gh_available() -> bool:
    try:
        subprocess.run(["gh", "--version"], capture_output=True, timeout=5)
        return True
    except (FileNotFoundError, subprocess.SubprocessError):
        return False


# ── HTTP Handler ─────────────────────────────────────────────────────────────

# Route table: path → handler function
API_GET_ROUTES = {
    "/api/loops": api_loops,
    "/api/progress": api_progress,
    "/api/benchmarks": api_benchmarks,
    "/api/agents": api_agents,
    "/api/pending": api_pending,
    "/api/workers": api_workers,
}


class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{self.log_date_time_string()}] {fmt % args}\n")

    def _send_json(self, data, status=200):
        body = json.dumps(data, default=str, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, fpath: Path):
        ct = mimetypes.guess_type(str(fpath))[0] or "application/octet-stream"
        body = fpath.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path

        # API routes
        handler = API_GET_ROUTES.get(path)
        if handler:
            try:
                self._send_json(handler())
            except Exception as e:
                self._send_json({"error": str(e)}, 500)
            return

        # Static files (dashboard)
        if path == "/":
            path = "/index.html"

        for base in [DASHBOARD_DIST, DASHBOARD_DEV]:
            fpath = base / path.lstrip("/")
            if fpath.is_file():
                self._send_file(fpath)
                return

        self.send_response(404)
        self.end_headers()
        self.wfile.write(b"Not found")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path

        if path == "/api/decision":
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length))
            except (json.JSONDecodeError, ValueError):
                self._send_json({"error": "Invalid JSON"}, 400)
                return

            result = api_decision(body)
            status = 200 if "ok" in result else 400
            self._send_json(result, status)
            return

        self.send_response(404)
        self.end_headers()


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Perf-AI dashboard + decision server")
    parser.add_argument("--port", type=int, default=4040)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    if not DB_PATH.exists():
        print(f"Warning: {DB_PATH} not found. API will return errors until DB is initialized.",
              file=sys.stderr)

    server = http.server.HTTPServer((args.host, args.port), Handler)
    print(f"Perf-AI Decision Server")
    print(f"  URL:      http://localhost:{args.port}")
    print(f"  DB:       {DB_PATH}")
    print(f"  Workers:  {STATUS_DIR}")
    print()
    print(f"  GET  /api/loops       -> loop runs")
    print(f"  GET  /api/progress    -> perf index time series")
    print(f"  GET  /api/benchmarks  -> benchmark trends")
    print(f"  GET  /api/agents      -> agent effectiveness")
    print(f"  GET  /api/pending     -> pending decisions")
    print(f"  GET  /api/workers     -> live worker status")
    print(f"  POST /api/decision    -> submit verdict")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutdown.")
        server.server_close()


if __name__ == "__main__":
    main()
