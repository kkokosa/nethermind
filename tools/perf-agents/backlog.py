#!/usr/bin/env python3
"""
Backlog management CLI for optimization targets.

Subcommands:
    seed     — Populate DB from OPTIMIZATION-TARGETS.md
    status   — Show target counts by status
    reset    — Clear all targets (--full clears related tables too)
    review   — List proposed (unreviewed) targets
    approve  — Move a proposed target to ready
    reject   — Reject a proposed target with reason

Usage:
    python backlog.py seed
    python backlog.py status [--json]
    python backlog.py reset [--full] [--yes]
    python backlog.py review
    python backlog.py approve EVM-5
    python backlog.py reject EVM-5 --reason "Too vague"
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path

from target_utils import parse_targets, derive_area

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent.parent
DB_PATH = REPO_ROOT / "tools" / "perf-dashboard" / "db" / "perf.db"
TARGETS_FILE = REPO_ROOT / "docs" / "perf-ai" / "OPTIMIZATION-TARGETS.md"


def get_conn(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def cmd_seed(args):
    """Seed targets from OPTIMIZATION-TARGETS.md into DB."""
    targets = parse_targets(Path(args.targets_file))
    if not targets:
        print("No targets found in targets file", file=sys.stderr)
        sys.exit(1)

    conn = get_conn(args.db)
    inserted = 0
    skipped = 0
    try:
        for t in targets:
            try:
                conn.execute(
                    """INSERT OR IGNORE INTO optimization_targets
                       (id, area, title, description, difficulty, impact,
                        priority_score, status, source)
                       VALUES (?, ?, ?, ?, ?, ?, ?, 'ready', 'seed')""",
                    (t["target_id"], t["area"], t["title"], t["description"],
                     t["difficulty"], t["impact"], t["priority_score"]),
                )
                if conn.total_changes > inserted + skipped:
                    inserted += 1
                else:
                    skipped += 1
            except sqlite3.IntegrityError:
                skipped += 1
        conn.commit()
        print(f"Seeded {inserted} targets ({skipped} already existed)")
    finally:
        conn.close()


def cmd_status(args):
    """Show target counts by status."""
    conn = get_conn(args.db)
    try:
        # Status summary
        rows = conn.execute(
            "SELECT status, COUNT(*) as cnt FROM optimization_targets GROUP BY status ORDER BY status"
        ).fetchall()

        if args.json:
            summary = {r["status"]: r["cnt"] for r in rows}
            ready = conn.execute(
                """SELECT id, area, title, difficulty, impact, priority_score, source
                   FROM optimization_targets WHERE status='ready'
                   ORDER BY priority_score DESC"""
            ).fetchall()
            summary["ready_targets"] = [dict(r) for r in ready]
            print(json.dumps(summary, indent=2))
        else:
            total = sum(r["cnt"] for r in rows)
            print(f"Backlog: {total} targets")
            for r in rows:
                print(f"  {r['status']:12s} {r['cnt']}")
            print()

            ready = conn.execute(
                """SELECT id, title, priority_score, difficulty, impact
                   FROM optimization_targets WHERE status='ready'
                   ORDER BY priority_score DESC"""
            ).fetchall()
            if ready:
                print("Ready targets (by priority):")
                for r in ready:
                    print(f"  {r['id']:10s} [{r['difficulty']}/{r['impact']}] "
                          f"prio={r['priority_score']:.0f}  {r['title'][:60]}")
    finally:
        conn.close()


def cmd_reset(args):
    """Clear all optimization targets."""
    if not args.yes:
        answer = input("Delete all optimization targets? [y/N] ")
        if answer.lower() not in ("y", "yes"):
            print("Aborted.")
            return

    conn = get_conn(args.db)
    try:
        conn.execute("DELETE FROM optimization_targets")
        if args.full:
            for table in ("loop_runs", "benchmark_results", "comparisons",
                          "null_runs", "progress_snapshots"):
                conn.execute(f"DELETE FROM {table}")
            print("Full reset: cleared targets + all loop data")
        else:
            print("Cleared all optimization targets")
        conn.commit()
    finally:
        conn.close()


def cmd_review(args):
    """List proposed (unreviewed) targets."""
    conn = get_conn(args.db)
    try:
        rows = conn.execute(
            """SELECT id, title, source, confidence, proposed_by, created_at
               FROM optimization_targets WHERE status='proposed'
               ORDER BY created_at DESC"""
        ).fetchall()
        if not rows:
            print("No proposed targets to review")
            return
        print(f"Proposed targets ({len(rows)}):")
        for r in rows:
            conf = f"conf={r['confidence']:.1f}" if r["confidence"] else "conf=?"
            print(f"  {r['id']:10s} {conf:10s} src={r['source'] or '?':20s} {r['title'][:55]}")
            print(f"  {'':10s} created: {r['created_at']}")
    finally:
        conn.close()


def cmd_approve(args):
    """Approve a proposed target (move to ready)."""
    conn = get_conn(args.db)
    try:
        cursor = conn.execute(
            "UPDATE optimization_targets SET status='ready', updated_at=datetime('now') "
            "WHERE id=? AND status='proposed'",
            (args.target_id,),
        )
        conn.commit()
        if cursor.rowcount > 0:
            print(f"Approved {args.target_id} -> ready")
        else:
            print(f"Target {args.target_id} not found or not in 'proposed' status",
                  file=sys.stderr)
            sys.exit(1)
    finally:
        conn.close()


def cmd_reject(args):
    """Reject a proposed target."""
    conn = get_conn(args.db)
    try:
        cursor = conn.execute(
            "UPDATE optimization_targets SET status='rejected', reject_reason=?, "
            "updated_at=datetime('now') WHERE id=? AND status='proposed'",
            (args.reason, args.target_id),
        )
        conn.commit()
        if cursor.rowcount > 0:
            print(f"Rejected {args.target_id}: {args.reason}")
        else:
            print(f"Target {args.target_id} not found or not in 'proposed' status",
                  file=sys.stderr)
            sys.exit(1)
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="Manage optimization target backlog")
    parser.add_argument("--db", default=str(DB_PATH))
    parser.add_argument("--targets-file", default=str(TARGETS_FILE))
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("seed", help="Seed targets from markdown")

    sp_status = sub.add_parser("status", help="Show backlog status")
    sp_status.add_argument("--json", action="store_true")

    sp_reset = sub.add_parser("reset", help="Clear all targets")
    sp_reset.add_argument("--full", action="store_true", help="Also clear loop_runs etc.")
    sp_reset.add_argument("--yes", action="store_true", help="Skip confirmation")

    sub.add_parser("review", help="List proposed targets")

    sp_approve = sub.add_parser("approve", help="Approve a proposed target")
    sp_approve.add_argument("target_id")

    sp_reject = sub.add_parser("reject", help="Reject a proposed target")
    sp_reject.add_argument("target_id")
    sp_reject.add_argument("--reason", required=True)

    args = parser.parse_args()

    cmds = {
        "seed": cmd_seed, "status": cmd_status, "reset": cmd_reset,
        "review": cmd_review, "approve": cmd_approve, "reject": cmd_reject,
    }
    cmds[args.command](args)


if __name__ == "__main__":
    main()
