#!/usr/bin/env python3
"""
Orchestrator v4: status + dry-run only. Workers are managed by tmux sessions.

Usage:
    python3 orchestrate.py --status                     # show system state
    python3 orchestrate.py --dry-run --workers 5        # preview target claims
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent.parent
DB_PATH = REPO_ROOT / "tools" / "perf-dashboard" / "db" / "perf.db"
RUN_DIR = SCRIPT_DIR / "run"
def _get_tmux_sessions() -> dict:
    """Get active perf-* tmux sessions."""
    try:
        result = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}"],
            capture_output=True, text=True, timeout=5,
        )
        sessions = [s for s in result.stdout.strip().split("\n") if s]
        return {
            "server": "perf-server" in sessions,
            "workers": [s for s in sessions if s.startswith("perf-worker-") or s.startswith("W:")],
        }
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {"server": False, "workers": []}


def _pid_alive(pid: int) -> bool:
    """Check if a process is running (cross-platform)."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def get_running_workers() -> list[dict]:
    """Read live worker status files, filter to actually running PIDs."""
    status_dir = RUN_DIR / "status"
    workers = []
    if status_dir.exists():
        for f in sorted(status_dir.glob("*.json")):
            try:
                data = json.loads(f.read_text())
                pid = data.get("pid", 0)
                if pid and _pid_alive(pid):
                    data["alive"] = True
                    workers.append(data)
                else:
                    f.unlink(missing_ok=True)
            except (json.JSONDecodeError, OSError):
                pass
    return workers


def show_status():
    tmux = _get_tmux_sessions()
    running = get_running_workers()

    print("=" * 64)
    print("  PERF-AI AGENT SYSTEM STATUS")
    print("=" * 64)

    print(f"\n  Server session:  {'ACTIVE' if tmux['server'] else 'not running'}")
    if tmux["workers"]:
        print(f"  Worker sessions: {', '.join(tmux['workers'])}")
    else:
        print("  Worker sessions: (none)")
    if not tmux["server"] and not tmux["workers"]:
        print("    Start with: bash tools/perf-agents/start.sh")

    print(f"\n  Running workers: {len(running)}")
    for w in running:
        print(f"    {w.get('id','?'):8s}  {w.get('targetId','?'):10s}  "
              f"{w.get('status','?'):20s}  attempt {w.get('attempt',0)}/{w.get('maxAttempts',3)}")

    if DB_PATH.exists():
        conn = sqlite3.connect(str(DB_PATH))
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                "SELECT id, target_id, status, verdict FROM loop_runs ORDER BY created_at DESC LIMIT 20"
            ).fetchall()
            print(f"\n  Recent loops ({len(rows)}):")
            for r in rows:
                v = f" → {r['verdict']}" if r["verdict"] else ""
                print(f"    {r['id']:8s}  {r['target_id']:10s}  {r['status']:20s}{v}")

            pending = conn.execute(
                "SELECT id, target_id FROM loop_runs WHERE status='pending_decision'"
            ).fetchall()
            if pending:
                print(f"\n  * PENDING DECISIONS ({len(pending)}):")
                for r in pending:
                    print(f"    {r['id']}  {r['target_id']}")
        finally:
            conn.close()

    print()


def main():
    parser = argparse.ArgumentParser(description="Perf optimization system status and preview")
    parser.add_argument("--workers", type=int, default=1, help="Number of workers to preview (for --dry-run)")
    parser.add_argument("--target", default=None, help="Preview a specific target (for --dry-run)")
    parser.add_argument("--exclude", default="", help="Comma-separated targets to skip (for --dry-run)")
    parser.add_argument("--dry-run", action="store_true", help="Preview target claims without spawning")
    parser.add_argument("--status", action="store_true", help="Show system status")
    args = parser.parse_args()

    if args.status:
        show_status()
        return

    if args.dry_run:
        from claim_target import parse_targets, TARGETS_FILE
        targets = parse_targets(TARGETS_FILE)
        count = 1 if args.target else args.workers

        print(f"\nAvailable targets ({len(targets)}):")
        for i, t in enumerate(targets):
            marker = ">" if i < count else " "
            print(f"  {marker} {t['target_id']:10s}  score={t['priority_score']:.0f}  "
                  f"difficulty={t['difficulty']}  impact={t['impact']}  {t['title'][:50]}")
        print(f"\nWould claim {count} target(s)")
        return

    # Default: show status
    show_status()


if __name__ == "__main__":
    main()
