#!/usr/bin/env python3
"""
Orchestrator v2: spawn N identical workers. Each claims its own target.

Usage:
    python orchestrate.py --workers 3                  # spawn 3 workers
    python orchestrate.py --workers 2 --exclude EVM-1  # skip EVM-1
    python orchestrate.py --target EVM-1               # one worker, forced target
    python orchestrate.py --status                     # show system state
    python orchestrate.py --dry-run --workers 5        # preview claims
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
WORKER_SCRIPT = SCRIPT_DIR / "worker.sh"
RUN_DIR = SCRIPT_DIR / "run"
PID_FILE = RUN_DIR / "workers.pid"


def get_running_workers() -> list[dict]:
    """Read live worker status files, filter to actually running PIDs."""
    status_dir = RUN_DIR / "status"
    workers = []
    if status_dir.exists():
        for f in sorted(status_dir.glob("*.json")):
            try:
                data = json.loads(f.read_text())
                pid = data.get("pid", 0)
                if pid and os.path.exists(f"/proc/{pid}"):
                    data["alive"] = True
                    workers.append(data)
                else:
                    f.unlink(missing_ok=True)
            except (json.JSONDecodeError, OSError):
                pass
    return workers


def show_status():
    running = get_running_workers()

    print("=" * 64)
    print("  PERF-AI AGENT SYSTEM STATUS")
    print("=" * 64)

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
                print(f"\n  ★ PENDING DECISIONS ({len(pending)}):")
                for r in pending:
                    print(f"    {r['id']}  {r['target_id']}")
        finally:
            conn.close()

    print()


def spawn_worker(extra_args: list[str] = None) -> int:
    """Spawn one worker.sh process. Returns PID."""
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    log_dir = RUN_DIR / "logs"
    log_dir.mkdir(exist_ok=True)

    cmd = ["bash", str(WORKER_SCRIPT)]
    if extra_args:
        cmd.extend(extra_args)

    log_file = log_dir / f"worker-{os.getpid()}-{len(list(log_dir.glob('*.log')))}.log"

    proc = subprocess.Popen(
        cmd,
        stdout=open(str(log_file), "w"),
        stderr=subprocess.STDOUT,
        cwd=str(REPO_ROOT),
        start_new_session=True,
    )
    return proc.pid


def main():
    parser = argparse.ArgumentParser(description="Spawn perf optimization workers")
    parser.add_argument("--workers", type=int, default=1, help="Number of workers (default: 1)")
    parser.add_argument("--target", default=None, help="Force a specific target (spawns 1 worker)")
    parser.add_argument("--exclude", default="", help="Comma-separated targets to skip")
    parser.add_argument("--dry-run", action="store_true", help="Preview without spawning")
    parser.add_argument("--status", action="store_true", help="Show system status")
    args = parser.parse_args()

    if args.status:
        show_status()
        return

    running = get_running_workers()
    print(f"Currently running: {len(running)} workers")

    if args.target:
        # One worker, forced target
        worker_args = ["--target", args.target]
        if args.exclude:
            worker_args.extend(["--exclude", args.exclude])

        if args.dry_run:
            print(f"Would spawn 1 worker for {args.target}")
            return

        pid = spawn_worker(worker_args)
        RUN_DIR.mkdir(parents=True, exist_ok=True)
        with open(str(PID_FILE), "a") as f:
            f.write(f"{pid}\n")
        print(f"Spawned worker for {args.target} — PID {pid}")

    else:
        # N generic workers, each claims its own target
        count = args.workers

        if args.dry_run:
            from claim_target import parse_targets, TARGETS_FILE
            targets = parse_targets(TARGETS_FILE)
            print(f"\nAvailable targets ({len(targets)}):")
            for i, t in enumerate(targets):
                marker = "→" if i < count else " "
                print(f"  {marker} {t['target_id']:10s}  score={t['priority_score']:.0f}  "
                      f"difficulty={t['difficulty']}  impact={t['impact']}  {t['title'][:50]}")
            print(f"\nWould spawn {count} workers (each claims next best target)")
            return

        worker_args = []
        if args.exclude:
            worker_args = ["--exclude", args.exclude]

        RUN_DIR.mkdir(parents=True, exist_ok=True)
        pids = []
        for i in range(count):
            pid = spawn_worker(worker_args)
            pids.append(pid)
            with open(str(PID_FILE), "a") as f:
                f.write(f"{pid}\n")
            print(f"  Worker {i+1}/{count} — PID {pid}")

        print(f"\n{count} workers spawned. Each will claim its own target.")
        print(f"  Logs:      {RUN_DIR / 'logs'}/")
        print(f"  Status:    python {SCRIPT_DIR / 'orchestrate.py'} --status")
        print(f"  Dashboard: http://localhost:4040")


if __name__ == "__main__":
    main()
