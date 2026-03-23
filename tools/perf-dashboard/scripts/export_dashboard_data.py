#!/usr/bin/env python3
"""Export SQLite data to JSON files for the React dashboard."""

import argparse
import json
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(SCRIPT_DIR, "..", "db", "perf.db")
DEFAULT_OUTPUT = os.path.join(SCRIPT_DIR, "..", "dashboard", "src", "data")


def dict_from_row(row, cursor):
    """Convert a sqlite3.Row to a dict."""
    return {desc[0]: row[i] for i, desc in enumerate(cursor.description)}


def export_loops(conn: sqlite3.Connection, output_dir: str):
    """Export loop runs with comparison stats to loops.json."""
    cursor = conn.execute("SELECT * FROM v_loop_summary ORDER BY created_at DESC")
    rows = cursor.fetchall()

    loops = []
    for row in rows:
        d = dict_from_row(row, cursor)
        loops.append({
            "id": d["id"],
            "targetId": d["target_id"],
            "targetArea": d["target_area"],
            "hypothesis": d["hypothesis"],
            "approach": d["approach"],
            "status": "merged" if d["status"] == "done" else d["status"],
            "verdict": d["verdict"],
            "difficulty": d["difficulty"],
            "impact": d["expected_impact"],
            "branch": d["branch"],
            "agent": d["agent_type"],
            "cost": d["cost_usd"] or 0,
            "tokens": d["total_tokens"] or 0,
            "iterations": d["iterations"] or 0,
            "date": d["created_at"][:10] if d["created_at"] else None,
            "deltaMean": d["avg_delta_pct"],
            "deltaAlloc": None,  # would need separate aggregation
            "confidence": d["verdict_confidence"],
            "pValue": None,  # per-benchmark, not aggregated
            "comparedBenchmarks": d["compared_benchmarks"],
            "significantImprovements": d["significant_improvements"],
            "significantRegressions": d["significant_regressions"],
            "bestDeltaPct": d["best_delta_pct"],
        })

    path = os.path.join(output_dir, "loops.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(loops, f, indent=2)
    print(f"Exported {len(loops)} loop runs to {path}")


def export_progress(conn: sqlite3.Connection, output_dir: str):
    """Export progress snapshots to progress.json."""
    cursor = conn.execute("SELECT * FROM progress_snapshots ORDER BY snapshot_date")
    rows = cursor.fetchall()

    progress = []
    for row in rows:
        d = dict_from_row(row, cursor)
        progress.append({
            "date": d["snapshot_date"],
            "perfIndex": d["perf_index"],
            "evmIndex": d["evm_index"],
            "trieIndex": d["trie_index"],
            "stateIndex": d["state_index"],
            "rlpIndex": d["rlp_index"],
            "dbIndex": d["db_index"],
            "bpIndex": d["bp_index"],
            "noiseFloor": d["noise_floor_pct"],
            "triggerLoopId": d["trigger_loop_id"],
            "totalBenchmarks": d.get("total_benchmarks", 0),
            "improvedBenchmarks": d.get("improved_benchmarks", 0),
            "touchedBenchmarks": d.get("touched_benchmarks", 0),
        })

    path = os.path.join(output_dir, "progress.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(progress, f, indent=2)
    print(f"Exported {len(progress)} progress snapshots to {path}")


def export_benchmarks(conn: sqlite3.Connection, output_dir: str):
    """Export key benchmark trends to benchmarks.json."""
    # Get key benchmarks from registry
    cursor = conn.execute(
        "SELECT full_name, short_name FROM benchmark_registry WHERE is_key_benchmark = 1"
    )
    key_benchmarks = cursor.fetchall()

    trends = []
    for row in key_benchmarks:
        full_name = row[0]
        short_name = row[1] or full_name.rsplit(".", 1)[-1]

        data_cursor = conn.execute("""
            SELECT lr.created_at, br.mean_ns
            FROM benchmark_results br
            JOIN loop_runs lr ON br.loop_run_id = lr.id
            WHERE br.full_name = ? AND br.side = 'candidate'
            ORDER BY lr.created_at
        """, (full_name,))

        data_points = []
        for data_row in data_cursor.fetchall():
            data_points.append({
                "date": data_row[0][:10] if data_row[0] else None,
                "ns": data_row[1],
            })

        if data_points:
            trends.append({"name": short_name, "data": data_points})

    # If no key benchmarks registered, export all unique benchmarks with data
    if not trends:
        cursor = conn.execute("""
            SELECT DISTINCT full_name FROM benchmark_results
            WHERE side = 'candidate' ORDER BY full_name
        """)
        for row in cursor.fetchall():
            full_name = row[0]
            short_name = full_name.rsplit(".", 1)[-1]
            data_cursor = conn.execute("""
                SELECT lr.created_at, br.mean_ns
                FROM benchmark_results br
                JOIN loop_runs lr ON br.loop_run_id = lr.id
                WHERE br.full_name = ? AND br.side = 'candidate'
                ORDER BY lr.created_at
            """, (full_name,))
            data_points = [{"date": r[0][:10] if r[0] else None, "ns": r[1]}
                           for r in data_cursor.fetchall()]
            if data_points:
                trends.append({"name": short_name, "data": data_points})

    path = os.path.join(output_dir, "benchmarks.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(trends, f, indent=2)
    print(f"Exported {len(trends)} benchmark trends to {path}")


def export_agents(conn: sqlite3.Connection, output_dir: str):
    """Export agent stats, area effectiveness, and failure taxonomy to agents.json."""
    # Agent stats
    cursor = conn.execute("SELECT * FROM v_agent_stats")
    agent_rows = cursor.fetchall()
    agents = []
    for row in agent_rows:
        d = dict_from_row(row, cursor)
        agents.append({
            "agent": d["agent_type"],
            "loops": d["total_loops"],
            "improvements": d["improvements"],
            "regressions": d["regressions"],
            "neutral": d["neutrals"],
            "inProgress": d["in_progress"],
            "hitRate": d["hit_rate_pct"] or 0,
            "avgCost": d["avg_cost"] or 0,
            "totalCost": d["total_cost"] or 0,
            "avgTokens": d["avg_tokens"] or 0,
        })

    # Area effectiveness
    cursor = conn.execute("SELECT * FROM v_area_stats")
    area_rows = cursor.fetchall()
    area_map = {"evm": "EVM", "trie": "Trie", "state": "State", "rlp": "RLP", "db": "DB", "bp": "Block Proc"}
    areas = []
    for row in area_rows:
        d = dict_from_row(row, cursor)
        areas.append({
            "area": area_map.get(d["target_area"], d["target_area"]),
            "attempted": d["attempted"],
            "improved": d["improved"],
            "hitRate": d["hit_rate_pct"] or 0,
            "avgDelta": d["avg_significant_delta"] or 0,
        })

    # Failure taxonomy
    total_failed = conn.execute(
        "SELECT COUNT(*) FROM loop_runs WHERE status = 'discarded'"
    ).fetchone()[0]

    failure_reasons = {
        "Below noise floor": 0,
        "Regression detected": 0,
        "Build/test failure": 0,
        "Agent gave up": 0,
    }

    # Count regressions
    regression_count = conn.execute(
        "SELECT COUNT(*) FROM loop_runs WHERE verdict = 'regression'"
    ).fetchone()[0]
    failure_reasons["Regression detected"] = regression_count

    # Below noise floor: neutral verdict
    neutral_count = conn.execute(
        "SELECT COUNT(*) FROM loop_runs WHERE verdict = 'neutral'"
    ).fetchone()[0]
    failure_reasons["Below noise floor"] = neutral_count

    # Error status as "Agent gave up"
    error_count = conn.execute(
        "SELECT COUNT(*) FROM loop_runs WHERE status = 'error'"
    ).fetchone()[0]
    failure_reasons["Agent gave up"] = error_count

    failures = []
    for reason, count in failure_reasons.items():
        pct = (count / total_failed * 100) if total_failed > 0 else 0
        failures.append({"reason": reason, "count": count, "pct": round(pct, 1)})

    output = {
        "agentStats": agents,
        "areaEffectiveness": areas,
        "failureTaxonomy": failures,
    }

    path = os.path.join(output_dir, "agents.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)
    print(f"Exported agent data to {path}")


def main():
    parser = argparse.ArgumentParser(description="Export dashboard data from SQLite to JSON")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT, help="Output directory for JSON files")
    parser.add_argument("--db", default=DEFAULT_DB, help="Path to SQLite database")
    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    output_dir = os.path.abspath(args.output_dir)

    if not os.path.exists(db_path):
        print(f"Error: database not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    conn = sqlite3.connect(db_path)
    try:
        export_loops(conn, output_dir)
        export_progress(conn, output_dir)
        export_benchmarks(conn, output_dir)
        export_agents(conn, output_dir)
        print(f"\nAll data exported to {output_dir}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
