#!/usr/bin/env python3
"""
Shared utilities for optimization target management.

- Constants: IMPACT_SCORE, DIFFICULTY_SCORE, TARGET_AREA_MAP
- parse_targets(): parse OPTIMIZATION-TARGETS.md
- compute_priority(): impact * ease score
- update_target_status(): update target status in SQLite
"""

import re
import sqlite3
from pathlib import Path

IMPACT_SCORE = {"high": 3, "med": 2, "low": 1}
DIFFICULTY_SCORE = {"S": 3, "M": 2, "L": 1}

TARGET_AREA_MAP = {
    "EVM": "evm", "TRIE": "trie", "STATE": "state",
    "RLP": "rlp", "DB": "db", "BP": "bp",
}


def compute_priority(impact: str, difficulty: str) -> float:
    """Returns impact_w * ease_w."""
    return IMPACT_SCORE.get(impact.lower(), 1) * DIFFICULTY_SCORE.get(difficulty.upper(), 1)


def derive_area(target_id: str) -> str:
    prefix = target_id.split("-")[0].upper()
    return TARGET_AREA_MAP.get(prefix, prefix.lower())


def parse_targets(filepath: Path) -> list[dict]:
    """Parse OPTIMIZATION-TARGETS.md to extract targets with priority scores and descriptions."""
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

        priority = compute_priority(impact, difficulty)

        targets.append({
            "target_id": target_id,
            "title": title,
            "description": section.strip(),
            "difficulty": difficulty.upper(),
            "impact": impact.lower(),
            "priority_score": priority,
            "area": derive_area(target_id),
        })

    targets.sort(key=lambda t: t["priority_score"], reverse=True)
    return targets


def update_target_status(conn: sqlite3.Connection, target_id: str, new_status: str) -> bool:
    """Update optimization target status. Returns True if a row was updated."""
    try:
        cursor = conn.execute(
            "UPDATE optimization_targets SET status=?, updated_at=datetime('now') WHERE id=?",
            (new_status, target_id),
        )
        return cursor.rowcount > 0
    except sqlite3.OperationalError:
        return False
