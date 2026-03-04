#!/usr/bin/env python3
"""
Atomically claim the next best optimization target.

Uses SQLite's single-writer property: BEGIN IMMEDIATE acquires the write lock
before the SELECT, so two workers cannot claim the same target.

Usage:
    python claim_target.py                          # claim best available
    python claim_target.py --target EVM-1           # claim specific target
    python claim_target.py --exclude EVM-1,TRIE-2   # skip these
    python claim_target.py --dry-run                # show what would be claimed

Output (on success): prints JSON to stdout:
    {"loop_run_id": "LR-007", "target_id": "EVM-1", "branch": "perf/evm-1/ai-20250615-1430"}

Exit codes:
    0 = claimed successfully
    1 = error
    2 = nothing to claim (all targets active or completed)
"""

import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent.parent
DB_PATH = REPO_ROOT / "tools" / "perf-dashboard" / "db" / "perf.db"
TARGETS_FILE = REPO_ROOT / "docs" / "perf-ai" / "OPTIMIZATION-TARGETS.md"

IMPACT_SCORE = {"high": 3, "med": 2, "low": 1}
DIFFICULTY_SCORE = {"S": 3, "M": 2, "L": 1}

TARGET_AREA_MAP = {
    "EVM": "evm", "TRIE": "trie", "STATE": "state",
    "RLP": "rlp", "DB": "db", "BP": "bp",
}


def parse_targets(filepath: Path) -> list[dict]:
    """Parse OPTIMIZATION-TARGETS.md to extract targets with priority scores."""
    content = filepath.read_text()
    targets = []

    for match in re.finditer(r"### (\w+-\d+):\s*(.+?)(?=\n)", content):
        target_id = match.group(1)
        title = match.group(2).strip()

        section_start = match.end()
        section_end = content.find("\n### ", section_start)
        if section_end == -1:
            section_end = len(content)
        section = content[section_start:section_end]

        diff_match = re.search(r"\*\*Difficulty\*\*:\s*(\w+)", section)
        impact_match = re.search(r"\*\*Impact\*\*:\s*(\w+)", section)

        difficulty = diff_match.group(1) if diff_match else "M"
        impact = impact_match.group(1) if impact_match else "med"

        impact_w = IMPACT_SCORE.get(impact.lower(), 1)
        ease_w = DIFFICULTY_SCORE.get(difficulty.upper(), 1)

        targets.append({
            "target_id": target_id,
            "title": title,
            "difficulty": difficulty,
            "impact": impact.lower(),
            "priority_score": impact_w * ease_w,
        })

    targets.sort(key=lambda t: t["priority_score"], reverse=True)
    return targets


def next_loop_id(conn: sqlite3.Connection) -> str:
    row = conn.execute("SELECT id FROM loop_runs ORDER BY id DESC LIMIT 1").fetchone()
    if row is None:
        return "LR-001"
    try:
        num = int(row[0].split("-")[1])
    except (IndexError, ValueError):
        num = 0
    return f"LR-{num + 1:03d}"


def derive_area(target_id: str) -> str:
    prefix = target_id.split("-")[0].upper()
    return TARGET_AREA_MAP.get(prefix, prefix.lower())


def claim(db_path: Path, targets_file: Path,
          force_target: str = None, exclude: set = None,
          dry_run: bool = False) -> dict | None:
    """
    Atomically claim a target. Returns claim dict or None.
    """
    all_targets = parse_targets(targets_file)
    exclude = exclude or set()

    conn = sqlite3.connect(str(db_path), timeout=30)
    try:
        # BEGIN IMMEDIATE acquires write lock before SELECT
        conn.execute("BEGIN IMMEDIATE")

        # Get targets already claimed (not discarded/error)
        active_rows = conn.execute(
            """SELECT DISTINCT target_id FROM loop_runs
               WHERE status NOT IN ('discarded', 'error')"""
        ).fetchall()
        active_targets = {row[0] for row in active_rows}

        if force_target:
            # Force specific target (may re-attempt a previously failed one)
            candidates = [t for t in all_targets if t["target_id"] == force_target]
            if not candidates:
                conn.rollback()
                print(f"Error: target {force_target} not found", file=sys.stderr)
                return None
            if force_target in active_targets:
                conn.rollback()
                print(f"Warning: {force_target} already active, claiming anyway",
                      file=sys.stderr)
            chosen = candidates[0]
        else:
            # Pick highest priority unclaimed target
            available = [
                t for t in all_targets
                if t["target_id"] not in active_targets
                and t["target_id"] not in exclude
            ]
            if not available:
                conn.rollback()
                return None
            chosen = available[0]  # already sorted by priority

        target_id = chosen["target_id"]
        now = datetime.now(timezone.utc)
        timestamp = now.strftime("%Y%m%d-%H%M")
        branch = f"perf/{target_id.lower()}/ai-{timestamp}"
        loop_id = next_loop_id(conn)
        area = derive_area(target_id)

        if dry_run:
            conn.rollback()
            return {
                "loop_run_id": loop_id,
                "target_id": target_id,
                "branch": branch,
                "difficulty": chosen["difficulty"],
                "impact": chosen["impact"],
                "priority_score": chosen["priority_score"],
                "dry_run": True,
            }

        conn.execute(
            """INSERT INTO loop_runs
               (id, target_id, target_area, hypothesis, branch,
                agent_type, difficulty, expected_impact, status)
               VALUES (?, ?, ?, ?, ?, 'claude-code', ?, ?, 'research')""",
            (loop_id, target_id, area,
             f"Claimed by worker, research pending ({chosen['title'][:80]})",
             branch, chosen["difficulty"], chosen["impact"]),
        )
        conn.commit()

        return {
            "loop_run_id": loop_id,
            "target_id": target_id,
            "branch": branch,
            "difficulty": chosen["difficulty"],
            "impact": chosen["impact"],
            "priority_score": chosen["priority_score"],
        }

    except sqlite3.OperationalError as e:
        conn.rollback()
        print(f"SQLite error (likely lock contention, retry): {e}", file=sys.stderr)
        return None
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="Claim an optimization target")
    parser.add_argument("--target", default=None, help="Force specific target ID")
    parser.add_argument("--exclude", default="", help="Comma-separated target IDs to skip")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be claimed")
    parser.add_argument("--db", default=str(DB_PATH))
    parser.add_argument("--targets-file", default=str(TARGETS_FILE))
    args = parser.parse_args()

    exclude = {t.strip() for t in args.exclude.split(",") if t.strip()}

    result = claim(
        Path(args.db), Path(args.targets_file),
        force_target=args.target, exclude=exclude,
        dry_run=args.dry_run,
    )

    if result is None:
        print("No targets available to claim", file=sys.stderr)
        sys.exit(2)

    print(json.dumps(result))
    sys.exit(0)


if __name__ == "__main__":
    main()
