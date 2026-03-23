#!/usr/bin/env python3
"""Ingest null-run calibration data (same benchmark run twice) for noise floor estimation."""

import argparse
import glob
import json
import math
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(SCRIPT_DIR, "..", "db", "perf.db")


def parse_bdn_file(path):
    """Parse a BDN JSON file into a dict of full_name -> {mean, stddev}."""
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    results = {}
    for bench in data.get("Benchmarks", []):
        full_name = bench.get("FullName", "")
        if not full_name:
            continue
        stats = bench.get("Statistics", {})
        results[full_name] = {
            "mean": stats.get("Mean", 0),
            "stddev": stats.get("StandardDeviation", 0),
        }
    return results


def main():
    parser = argparse.ArgumentParser(description="Ingest null-run calibration data")
    parser.add_argument("--bdn-json", required=True, nargs="+", help="Two BDN JSON files (same benchmark, run twice)")
    parser.add_argument("--db", default=DEFAULT_DB, help="Path to SQLite database")
    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    if not os.path.exists(db_path):
        print(f"Error: database not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    # Expand glob patterns
    json_files = []
    for pattern in args.bdn_json:
        expanded = glob.glob(pattern)
        if expanded:
            json_files.extend(expanded)
        elif os.path.exists(pattern):
            json_files.append(pattern)

    if len(json_files) < 2:
        print("Error: need at least 2 BDN JSON files for null-run comparison", file=sys.stderr)
        sys.exit(1)

    run1 = parse_bdn_file(json_files[0])
    run2 = parse_bdn_file(json_files[1])

    # Find common benchmarks
    common = set(run1.keys()) & set(run2.keys())
    if not common:
        print("Error: no common benchmarks found between the two files", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    try:
        count = 0
        for full_name in sorted(common):
            r1 = run1[full_name]
            r2 = run2[full_name]

            if r1["mean"] == 0:
                continue

            delta_mean_pct = (r2["mean"] - r1["mean"]) / r1["mean"] * 100
            stddev_pct = math.sqrt(r1["stddev"] ** 2 + r2["stddev"] ** 2) / r1["mean"] * 100

            conn.execute(
                "INSERT INTO null_runs (full_name, delta_mean_pct, stddev_pct) VALUES (?, ?, ?)",
                (full_name, delta_mean_pct, stddev_pct),
            )
            count += 1

        conn.commit()

        # Print summary
        print(f"\nNull-run calibration: {count} benchmarks from {len(json_files)} files\n")
        print("| Benchmark | Delta Mean | Noise Floor (stddev) |")
        print("|-----------|-----------|---------------------|")

        rows = conn.execute(
            "SELECT full_name, delta_mean_pct, stddev_pct FROM null_runs ORDER BY run_date DESC, full_name LIMIT ?",
            (count,),
        ).fetchall()
        for row in rows:
            short = row[0].rsplit(".", 1)[-1] if "." in row[0] else row[0]
            print(f"| {short} | {row[1]:+.2f}% | \u00B1{row[2]:.2f}% |")

        avg_noise = sum(abs(r[1]) for r in rows) / len(rows) if rows else 0
        avg_stddev = sum(r[2] for r in rows) / len(rows) if rows else 0
        print(f"\nAvg |delta|: {avg_noise:.2f}%  Avg noise floor: \u00B1{avg_stddev:.2f}%")

    finally:
        conn.close()


if __name__ == "__main__":
    main()
