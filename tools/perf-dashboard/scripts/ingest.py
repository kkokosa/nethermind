#!/usr/bin/env python3
"""Ingest BenchmarkDotNet JSON results into the perf-ai database."""

import argparse
import glob
import json
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(SCRIPT_DIR, "..", "db", "perf.db")


def parse_full_name(full_name: str):
    """Extract benchmark_class, benchmark_method, and params from BDN FullName.

    Examples:
        "Nethermind.Evm.Benchmark.EvmStackBenchmarks.Uint256"
        → class="EvmStackBenchmarks", method="Uint256", params=None

        "Nethermind.Evm.Benchmark.EvmStackBenchmarks.Pop(count: 10)"
        → class="EvmStackBenchmarks", method="Pop", params='{"count": "10"}'
    """
    params = None
    name = full_name

    # Extract params from parentheses at the end
    paren_idx = name.find("(")
    if paren_idx != -1:
        params_str = name[paren_idx + 1:].rstrip(")")
        name = name[:paren_idx]
        # Parse "key: value, key2: value2" format
        params_dict = {}
        for part in params_str.split(","):
            part = part.strip()
            if ":" in part:
                k, v = part.split(":", 1)
                params_dict[k.strip()] = v.strip()
            elif part:
                params_dict["param"] = part
        if params_dict:
            params = json.dumps(params_dict)

    parts = name.rsplit(".", 2)
    if len(parts) >= 2:
        method = parts[-1]
        class_name = parts[-2]
    else:
        method = parts[-1]
        class_name = ""

    return class_name, method, params


def ingest_file(conn: sqlite3.Connection, loop_run_id: str, side: str, json_path: str) -> int:
    """Ingest a single BDN JSON file. Returns number of benchmarks ingested."""
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    benchmarks = data.get("Benchmarks", [])
    count = 0

    for bench in benchmarks:
        full_name = bench.get("FullName", "")
        if not full_name:
            continue

        class_name, method, params = parse_full_name(full_name)

        stats = bench.get("Statistics", {})
        memory = bench.get("Memory")

        mean_ns = stats.get("Mean")
        median_ns = stats.get("Median")
        stddev_ns = stats.get("StandardDeviation")
        min_ns = stats.get("Min")
        max_ns = stats.get("Max")
        iterations = stats.get("N")

        percentiles = stats.get("Percentiles", {})
        p95_ns = percentiles.get("P95")

        allocated_bytes = None
        gen0 = None
        gen1 = None
        gen2 = None
        if memory is not None:
            allocated_bytes = memory.get("BytesAllocatedPerOperation")
            gen0 = memory.get("Gen0Collections")
            gen1 = memory.get("Gen1Collections")
            gen2 = memory.get("Gen2Collections")

        conn.execute(
            """INSERT INTO benchmark_results
               (loop_run_id, side, benchmark_class, benchmark_method, benchmark_params,
                full_name, mean_ns, median_ns, stddev_ns, min_ns, max_ns, p95_ns,
                iterations, allocated_bytes, gen0_collections, gen1_collections,
                gen2_collections, bdn_json_path)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(loop_run_id, side, full_name) DO UPDATE SET
                mean_ns=excluded.mean_ns, median_ns=excluded.median_ns,
                stddev_ns=excluded.stddev_ns, min_ns=excluded.min_ns,
                max_ns=excluded.max_ns, p95_ns=excluded.p95_ns,
                iterations=excluded.iterations,
                allocated_bytes=excluded.allocated_bytes,
                gen0_collections=excluded.gen0_collections,
                gen1_collections=excluded.gen1_collections,
                gen2_collections=excluded.gen2_collections,
                bdn_json_path=excluded.bdn_json_path,
                ingested_at=datetime('now')""",
            (loop_run_id, side, class_name, method, params, full_name,
             mean_ns, median_ns, stddev_ns, min_ns, max_ns, p95_ns,
             iterations, allocated_bytes, gen0, gen1, gen2, json_path),
        )
        count += 1

    return count


def main():
    parser = argparse.ArgumentParser(description="Ingest BDN JSON results into perf-ai database")
    parser.add_argument("--loop-run", required=True, help="Loop run ID (e.g. LR-001)")
    parser.add_argument("--side", required=True, choices=["baseline", "candidate"], help="baseline or candidate")
    parser.add_argument("--bdn-json", required=True, nargs="+", help="BDN JSON file paths (glob patterns supported)")
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
        else:
            print(f"Warning: no files matched pattern '{pattern}'", file=sys.stderr)

    if not json_files:
        print("Error: no JSON files found", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    try:
        # Verify loop run exists
        row = conn.execute("SELECT id FROM loop_runs WHERE id = ?", (args.loop_run,)).fetchone()
        if row is None:
            print(f"Error: loop run '{args.loop_run}' not found", file=sys.stderr)
            sys.exit(1)

        total = 0
        for json_path in json_files:
            count = ingest_file(conn, args.loop_run, args.side, json_path)
            total += count

        conn.commit()
        print(f"Ingested {total} benchmarks for {args.loop_run} ({args.side})")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
