#!/usr/bin/env python3
"""
Insert new optimization target proposals into the backlog.

Used by workers (after research) and the researcher agent.

Usage:
    python propose_target.py --from-file new-targets.json --source worker:LR-007
    python propose_target.py --from-file new-targets.json --source researcher --db path/to/perf.db

Input JSON: array of objects with:
    area, title, description, difficulty, impact, confidence, parent_id?, related_targets?
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path

from target_utils import compute_priority, derive_area, TARGET_AREA_MAP

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent.parent
DB_PATH = REPO_ROOT / "tools" / "perf-dashboard" / "db" / "perf.db"


def next_id_for_area(conn: sqlite3.Connection, area: str) -> str:
    """Generate next target ID for an area, e.g. EVM-5."""
    prefix = None
    for k, v in TARGET_AREA_MAP.items():
        if v == area.lower():
            prefix = k
            break
    if not prefix:
        prefix = area.upper()

    row = conn.execute(
        "SELECT id FROM optimization_targets WHERE id LIKE ? "
        "ORDER BY CAST(SUBSTR(id, INSTR(id, '-') + 1) AS INTEGER) DESC LIMIT 1",
        (f"{prefix}-%",),
    ).fetchone()

    if row:
        try:
            num = int(row[0].split("-")[1])
        except (IndexError, ValueError):
            num = 0
        return f"{prefix}-{num + 1}"
    return f"{prefix}-1"


def check_dedup(conn: sqlite3.Connection, area: str, title: str) -> list[str]:
    """Check for similar existing targets in the same area. Returns related IDs."""
    related = []
    words = set(title.lower().split())
    # Simple overlap: check if any existing target title shares 3+ words
    rows = conn.execute(
        "SELECT id, title FROM optimization_targets WHERE area=?",
        (area.lower(),),
    ).fetchall()
    for row in rows:
        existing_words = set(row[1].lower().split())
        overlap = words & existing_words
        if len(overlap) >= 3:
            related.append(row[0])
    return related


def propose(db_path: str, proposals: list[dict], source: str) -> list[dict]:
    """Insert proposals into DB. Returns list of inserted targets with assigned IDs."""
    conn = sqlite3.connect(db_path, timeout=30)
    conn.row_factory = sqlite3.Row
    inserted = []

    try:
        conn.execute("BEGIN IMMEDIATE")

        for p in proposals:
            area = p.get("area", "").lower()
            title = p.get("title", "")
            description = p.get("description", "")
            difficulty = p.get("difficulty", "M").upper()
            impact = p.get("impact", "med").lower()
            confidence = p.get("confidence")
            parent_id = p.get("parent_id")
            related = p.get("related_targets", [])

            if not area or not title:
                print(f"Skipping proposal with missing area/title: {p}", file=sys.stderr)
                continue

            # Dedup check
            similar = check_dedup(conn, area, title)
            if similar:
                related = list(set(related + similar))
                print(f"Warning: similar targets found: {similar} — adding to related",
                      file=sys.stderr)

            target_id = next_id_for_area(conn, area)
            priority = compute_priority(impact, difficulty)

            conn.execute(
                """INSERT INTO optimization_targets
                   (id, area, title, description, difficulty, impact,
                    priority_score, status, source, parent_id, proposed_by,
                    related_targets, confidence)
                   VALUES (?, ?, ?, ?, ?, ?, ?, 'proposed', ?, ?, ?, ?, ?)""",
                (target_id, area, title, description, difficulty, impact,
                 priority, source, parent_id, source,
                 json.dumps(related) if related else None, confidence),
            )

            inserted.append({
                "id": target_id,
                "area": area,
                "title": title,
                "difficulty": difficulty,
                "impact": impact,
                "priority_score": priority,
                "source": source,
                "confidence": confidence,
            })

        conn.commit()
    except sqlite3.OperationalError as e:
        conn.rollback()
        print(f"SQLite error: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        conn.close()

    return inserted


def main():
    parser = argparse.ArgumentParser(description="Propose new optimization targets")
    parser.add_argument("--from-file", required=True, help="JSON file with proposals")
    parser.add_argument("--source", required=True, help="Source identifier (e.g. worker:LR-007)")
    parser.add_argument("--db", default=str(DB_PATH))
    args = parser.parse_args()

    proposals_path = Path(args.from_file)
    if not proposals_path.exists():
        print(f"File not found: {proposals_path}", file=sys.stderr)
        sys.exit(1)

    proposals = json.loads(proposals_path.read_text())
    if not isinstance(proposals, list):
        print("Expected JSON array of proposals", file=sys.stderr)
        sys.exit(1)

    if len(proposals) > 5:
        print(f"Warning: {len(proposals)} proposals (max recommended: 5)", file=sys.stderr)

    inserted = propose(args.db, proposals, args.source)
    print(json.dumps(inserted, indent=2))
    print(f"Inserted {len(inserted)} proposals", file=sys.stderr)


if __name__ == "__main__":
    main()
