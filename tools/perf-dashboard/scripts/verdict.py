#!/usr/bin/env python3
"""Record a verdict for a loop run."""

import argparse
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(SCRIPT_DIR, "..", "db", "perf.db")


def compute_confidence(conn: sqlite3.Connection, loop_run_id: str) -> float:
    """Compute verdict confidence from comparisons: avg of (1 - p_value) for significant results."""
    rows = conn.execute(
        "SELECT p_value FROM comparisons WHERE loop_run_id = ? AND is_significant = 1",
        (loop_run_id,),
    ).fetchall()
    if not rows:
        return 0.0
    return sum(1 - row[0] for row in rows) / len(rows)


def main():
    parser = argparse.ArgumentParser(description="Record verdict for a loop run")
    parser.add_argument("--loop-run", required=True, help="Loop run ID")
    parser.add_argument("--verdict", required=True,
                        choices=["improvement", "regression", "neutral", "inconclusive"],
                        help="Verdict for this loop run")
    parser.add_argument("--notes", default="", help="Verdict notes")
    parser.add_argument("--db", default=DEFAULT_DB, help="Path to SQLite database")
    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    if not os.path.exists(db_path):
        print(f"Error: database not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    try:
        # Verify loop run exists
        row = conn.execute("SELECT id FROM loop_runs WHERE id = ?", (args.loop_run,)).fetchone()
        if row is None:
            print(f"Error: loop run '{args.loop_run}' not found", file=sys.stderr)
            sys.exit(1)

        confidence = compute_confidence(conn, args.loop_run)
        status = "done" if args.verdict == "improvement" else "discarded"

        conn.execute(
            """UPDATE loop_runs
               SET verdict = ?, verdict_notes = ?, verdict_confidence = ?,
                   status = ?, updated_at = datetime('now')
               WHERE id = ?""",
            (args.verdict, args.notes, confidence, status, args.loop_run),
        )
        conn.commit()

        print(f"Verdict recorded for {args.loop_run}:")
        print(f"  verdict: {args.verdict}")
        print(f"  status: {status}")
        print(f"  confidence: {confidence:.2f}")
        if args.notes:
            print(f"  notes: {args.notes}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
