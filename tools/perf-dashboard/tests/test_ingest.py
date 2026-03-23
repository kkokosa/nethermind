"""Tests for ingest.py — BDN JSON parsing and database insertion."""

import json
import os
import sqlite3
import sys
import tempfile
import unittest

# Add scripts to path
SCRIPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
sys.path.insert(0, SCRIPT_DIR)

from ingest import parse_full_name, ingest_file

SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schema.sql")
FIXTURES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def create_test_db():
    """Create an in-memory SQLite DB with the schema."""
    conn = sqlite3.connect(":memory:")
    with open(SCHEMA_PATH, "r") as f:
        conn.executescript(f.read())
    return conn


def seed_loop_run(conn, loop_id="LR-001"):
    """Insert a minimal loop_run for FK references."""
    conn.execute(
        "INSERT INTO loop_runs (id, target_id, target_area, hypothesis) VALUES (?, ?, ?, ?)",
        (loop_id, "EVM-1", "evm", "test hypothesis"),
    )
    conn.commit()


class TestParseFullName(unittest.TestCase):
    def test_simple_name(self):
        cls, method, params = parse_full_name("Nethermind.Evm.Benchmark.EvmStackBenchmarks.Uint256")
        self.assertEqual(cls, "EvmStackBenchmarks")
        self.assertEqual(method, "Uint256")
        self.assertIsNone(params)

    def test_parameterized_name(self):
        cls, method, params = parse_full_name("Nethermind.Evm.Benchmark.EvmStackBenchmarks.Pop(count: 10)")
        self.assertEqual(cls, "EvmStackBenchmarks")
        self.assertEqual(method, "Pop")
        self.assertIsNotNone(params)
        parsed = json.loads(params)
        self.assertEqual(parsed["count"], "10")

    def test_multi_param(self):
        cls, method, params = parse_full_name("Ns.Class.Method(a: 1, b: 2)")
        self.assertEqual(cls, "Class")
        self.assertEqual(method, "Method")
        parsed = json.loads(params)
        self.assertEqual(parsed["a"], "1")
        self.assertEqual(parsed["b"], "2")

    def test_short_name(self):
        cls, method, params = parse_full_name("SimpleMethod")
        self.assertEqual(method, "SimpleMethod")
        self.assertIsNone(params)


class TestIngestFile(unittest.TestCase):
    def setUp(self):
        self.conn = create_test_db()
        seed_loop_run(self.conn)

    def tearDown(self):
        self.conn.close()

    def test_ingest_baseline(self):
        path = os.path.join(FIXTURES_DIR, "sample_bdn_baseline.json")
        count = ingest_file(self.conn, "LR-001", "baseline", path)
        self.conn.commit()
        self.assertEqual(count, 3)

        rows = self.conn.execute("SELECT COUNT(*) FROM benchmark_results WHERE side = 'baseline'").fetchone()
        self.assertEqual(rows[0], 3)

    def test_ingest_candidate(self):
        path = os.path.join(FIXTURES_DIR, "sample_bdn_output.json")
        count = ingest_file(self.conn, "LR-001", "candidate", path)
        self.conn.commit()
        self.assertEqual(count, 3)

    def test_missing_memory(self):
        """Benchmarks without Memory section should have NULL alloc fields."""
        path = os.path.join(FIXTURES_DIR, "sample_bdn_baseline.json")
        ingest_file(self.conn, "LR-001", "baseline", path)
        self.conn.commit()

        # The parameterized Pop benchmark has no Memory section
        row = self.conn.execute(
            "SELECT allocated_bytes FROM benchmark_results WHERE full_name LIKE '%Pop(count%'",
        ).fetchone()
        self.assertIsNone(row[0])

    def test_upsert(self):
        """Ingesting the same file twice should update, not duplicate."""
        path = os.path.join(FIXTURES_DIR, "sample_bdn_baseline.json")
        ingest_file(self.conn, "LR-001", "baseline", path)
        self.conn.commit()
        ingest_file(self.conn, "LR-001", "baseline", path)
        self.conn.commit()

        rows = self.conn.execute("SELECT COUNT(*) FROM benchmark_results WHERE side = 'baseline'").fetchone()
        self.assertEqual(rows[0], 3)

    def test_parameterized_benchmark(self):
        """Parameterized benchmarks should store params as JSON."""
        path = os.path.join(FIXTURES_DIR, "sample_bdn_baseline.json")
        ingest_file(self.conn, "LR-001", "baseline", path)
        self.conn.commit()

        row = self.conn.execute(
            "SELECT benchmark_params FROM benchmark_results WHERE full_name LIKE '%Pop(count%'",
        ).fetchone()
        self.assertIsNotNone(row[0])
        parsed = json.loads(row[0])
        self.assertEqual(parsed["count"], "10")

    def test_statistics_values(self):
        """Check that statistics are correctly extracted."""
        path = os.path.join(FIXTURES_DIR, "sample_bdn_baseline.json")
        ingest_file(self.conn, "LR-001", "baseline", path)
        self.conn.commit()

        row = self.conn.execute(
            "SELECT mean_ns, median_ns, stddev_ns, min_ns, max_ns, p95_ns, iterations "
            "FROM benchmark_results WHERE full_name LIKE '%Uint256'"
        ).fetchone()
        self.assertAlmostEqual(row[0], 245.3)
        self.assertAlmostEqual(row[1], 243.1)
        self.assertAlmostEqual(row[2], 4.2)
        self.assertAlmostEqual(row[3], 238.0)
        self.assertAlmostEqual(row[4], 260.1)
        self.assertAlmostEqual(row[5], 252.0)
        self.assertEqual(row[6], 100)


if __name__ == "__main__":
    unittest.main()
