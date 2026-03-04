#!/usr/bin/env python3
"""Register a new optimization loop run."""

import argparse
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(SCRIPT_DIR, "..", "db", "perf.db")

TARGET_AREA_MAP = {
    "EVM": "evm",
    "TRIE": "trie",
    "STATE": "state",
    "RLP": "rlp",
    "DB": "db",
    "BP": "bp",
}


def derive_target_area(target_id: str) -> str:
    prefix = target_id.split("-")[0].upper()
    area = TARGET_AREA_MAP.get(prefix)
    if area is None:
        print(f"Error: unknown target prefix '{prefix}' in target_id '{target_id}'", file=sys.stderr)
        print(f"Expected one of: {', '.join(TARGET_AREA_MAP.keys())}", file=sys.stderr)
        sys.exit(1)
    return area


def next_loop_id(conn: sqlite3.Connection) -> str:
    row = conn.execute("SELECT id FROM loop_runs ORDER BY id DESC LIMIT 1").fetchone()
    if row is None:
        return "LR-001"
    last_id = row[0]
    try:
        num = int(last_id.split("-")[1])
    except (IndexError, ValueError):
        num = 0
    return f"LR-{num + 1:03d}"


def main():
    parser = argparse.ArgumentParser(description="Register a new loop run")
    parser.add_argument("--target-id", required=True, help="Optimization target ID (e.g. EVM-1)")
    parser.add_argument("--hypothesis", required=True, help="What we expect to improve and why")
    parser.add_argument("--branch", required=True, help="Git branch name")
    parser.add_argument("--agent", required=True, help="Agent type (e.g. claude-code)")
    parser.add_argument("--difficulty", required=True, choices=["S", "M", "L"], help="Difficulty estimate")
    parser.add_argument("--expected-impact", required=True, choices=["low", "med", "high"], help="Expected impact")
    parser.add_argument("--db", default=DEFAULT_DB, help="Path to SQLite database")
    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    if not os.path.exists(db_path):
        print(f"Error: database not found: {db_path}", file=sys.stderr)
        print("Run init_db.py first.", file=sys.stderr)
        sys.exit(1)

    target_area = derive_target_area(args.target_id)

    conn = sqlite3.connect(db_path)
    try:
        loop_id = next_loop_id(conn)
        conn.execute(
            """INSERT INTO loop_runs (id, target_id, target_area, hypothesis, branch,
                                      agent_type, difficulty, expected_impact, status)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'research')""",
            (loop_id, args.target_id, target_area, args.hypothesis,
             args.branch, args.agent, args.difficulty, args.expected_impact),
        )
        conn.commit()
        print(loop_id)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
