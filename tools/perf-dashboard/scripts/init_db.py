#!/usr/bin/env python3
"""Initialize the perf-ai SQLite database from schema.sql."""

import argparse
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCHEMA = os.path.join(SCRIPT_DIR, "..", "schema.sql")
DEFAULT_DB = os.path.join(SCRIPT_DIR, "..", "db", "perf.db")


def main():
    parser = argparse.ArgumentParser(description="Create perf-ai SQLite database from schema.sql")
    parser.add_argument("--schema", default=DEFAULT_SCHEMA, help="Path to schema.sql")
    parser.add_argument("--db", default=DEFAULT_DB, help="Path to SQLite database file")
    args = parser.parse_args()

    schema_path = os.path.abspath(args.schema)
    db_path = os.path.abspath(args.db)

    if not os.path.exists(schema_path):
        print(f"Error: schema file not found: {schema_path}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(db_path), exist_ok=True)

    with open(schema_path, "r", encoding="utf-8") as f:
        schema_sql = f.read()

    is_new = not os.path.exists(db_path) or os.path.getsize(db_path) == 0
    conn = sqlite3.connect(db_path)
    try:
        if is_new:
            conn.executescript(schema_sql)
        else:
            # Existing DB: run schema statement-by-statement, skip failures
            # (e.g. CREATE INDEX without IF NOT EXISTS on already-existing indexes)
            for statement in schema_sql.split(";"):
                statement = statement.strip()
                if not statement or statement.startswith("--"):
                    continue
                try:
                    conn.execute(statement)
                except sqlite3.OperationalError:
                    pass  # index/table already exists
            conn.commit()

        # Run migration files (idempotent, sorted order)
        migrations_dir = os.path.join(os.path.dirname(schema_path), "migrations")
        if os.path.isdir(migrations_dir):
            for mig in sorted(os.listdir(migrations_dir)):
                if mig.endswith(".sql"):
                    with open(os.path.join(migrations_dir, mig)) as mf:
                        for statement in mf.read().split(";"):
                            statement = statement.strip()
                            if not statement or statement.startswith("--"):
                                continue
                            try:
                                conn.execute(statement)
                            except sqlite3.OperationalError:
                                pass  # column/table already exists

        conn.commit()
        tables = [row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()]
        print(f"Database {'created' if is_new else 'updated'}: {db_path}")
        print(f"Tables: {', '.join(tables)}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
