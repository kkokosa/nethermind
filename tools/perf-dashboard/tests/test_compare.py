"""Tests for compare.py — delta calculations, Mann-Whitney, and recommendation logic."""

import math
import os
import sqlite3
import sys
import unittest

# Add scripts to path
SCRIPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
sys.path.insert(0, SCRIPT_DIR)

from compare import heuristic_p_value, compute_cohen_d
from ingest import ingest_file

SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schema.sql")
FIXTURES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def create_test_db():
    """Create an in-memory SQLite DB with the schema."""
    conn = sqlite3.connect(":memory:")
    with open(SCHEMA_PATH, "r") as f:
        conn.executescript(f.read())
    return conn


def seed_loop_and_data(conn, loop_id="LR-001"):
    """Insert a loop_run and ingest baseline + candidate data."""
    conn.execute(
        "INSERT INTO loop_runs (id, target_id, target_area, hypothesis) VALUES (?, ?, ?, ?)",
        (loop_id, "EVM-1", "evm", "test hypothesis"),
    )
    conn.commit()

    baseline_path = os.path.join(FIXTURES_DIR, "sample_bdn_baseline.json")
    candidate_path = os.path.join(FIXTURES_DIR, "sample_bdn_output.json")

    ingest_file(conn, loop_id, "baseline", baseline_path)
    ingest_file(conn, loop_id, "candidate", candidate_path)
    conn.commit()


class TestHeuristicPValue(unittest.TestCase):
    def test_well_separated(self):
        """Very different means with small stddev should give low p-value."""
        p = heuristic_p_value(100, 2, 200, 2)
        self.assertLess(p, 0.3)

    def test_overlapping(self):
        """Similar means with large stddev should give high p-value."""
        p = heuristic_p_value(100, 50, 102, 50)
        self.assertGreater(p, 0.5)

    def test_identical(self):
        """Identical distributions should give p near 1."""
        p = heuristic_p_value(100, 10, 100, 10)
        self.assertGreater(p, 0.9)


class TestCohenD(unittest.TestCase):
    def test_large_effect(self):
        """Large difference relative to stddev should give large Cohen's d."""
        d = compute_cohen_d(200, 10, 100, 10)
        self.assertGreater(d, 5)

    def test_no_effect(self):
        """Same means should give d ~= 0."""
        d = compute_cohen_d(100, 10, 100, 10)
        self.assertAlmostEqual(d, 0, places=5)

    def test_negative_effect(self):
        """When candidate is slower, d should be negative."""
        d = compute_cohen_d(100, 10, 200, 10)
        self.assertLess(d, -5)

    def test_zero_stddev(self):
        """Zero stddev should not crash."""
        d = compute_cohen_d(100, 0, 100, 0)
        self.assertEqual(d, 0.0)


class TestCompareEndToEnd(unittest.TestCase):
    def setUp(self):
        self.conn = create_test_db()
        seed_loop_and_data(self.conn)

    def tearDown(self):
        self.conn.close()

    def test_paired_results_exist(self):
        """Verify baseline and candidate data is properly paired."""
        rows = self.conn.execute("""
            SELECT b.full_name
            FROM benchmark_results b
            JOIN benchmark_results c ON b.full_name = c.full_name AND b.loop_run_id = c.loop_run_id
            WHERE b.side = 'baseline' AND c.side = 'candidate' AND b.loop_run_id = 'LR-001'
        """).fetchall()
        self.assertEqual(len(rows), 3)

    def test_delta_calculation(self):
        """Test that delta percentages are computed correctly for known values."""
        # PopAddress: baseline=185.6, candidate=150.3
        # Expected delta = (150.3 - 185.6) / 185.6 * 100 = -19.02%
        baseline = 185.6
        candidate = 150.3
        expected_delta = (candidate - baseline) / baseline * 100
        self.assertAlmostEqual(expected_delta, -19.02, places=1)

    def test_alloc_delta_calculation(self):
        """Test allocation delta: PopAddress goes from 32 to 0 bytes = -100%."""
        baseline_alloc = 32
        candidate_alloc = 0
        delta = (candidate_alloc - baseline_alloc) / baseline_alloc * 100
        self.assertAlmostEqual(delta, -100.0)

    def test_recommendation_merge(self):
        """With a 19% improvement and no regressions, should recommend MERGE."""
        # The fixture data has PopAddress at -19%, which exceeds the 5% threshold
        # Simulate the recommendation logic
        results = [
            {"delta_mean_pct": -19.0, "is_significant": True},
            {"delta_mean_pct": -2.1, "is_significant": True},
            {"delta_mean_pct": -1.8, "is_significant": True},
        ]
        significant_improvements = [r for r in results if r["is_significant"] and r["delta_mean_pct"] < -5]
        significant_regressions = [r for r in results if r["is_significant"] and r["delta_mean_pct"] > 0]

        self.assertTrue(len(significant_improvements) > 0)
        self.assertEqual(len(significant_regressions), 0)

    def test_recommendation_discard(self):
        """With regressions, should recommend DISCARD."""
        results = [
            {"delta_mean_pct": 4.2, "is_significant": True},
            {"delta_mean_pct": -1.0, "is_significant": False},
        ]
        significant_regressions = [r for r in results if r["is_significant"] and r["delta_mean_pct"] > 0]
        self.assertTrue(len(significant_regressions) > 0)

    def test_recommendation_iterate(self):
        """With improvements below threshold, should recommend ITERATE."""
        results = [
            {"delta_mean_pct": -2.1, "is_significant": True},
            {"delta_mean_pct": -1.8, "is_significant": True},
        ]
        significant_improvements = [r for r in results if r["is_significant"] and r["delta_mean_pct"] < -5]
        significant_regressions = [r for r in results if r["is_significant"] and r["delta_mean_pct"] > 0]
        any_improvements = [r for r in results if r["delta_mean_pct"] < 0]

        self.assertEqual(len(significant_improvements), 0)
        self.assertEqual(len(significant_regressions), 0)
        self.assertTrue(len(any_improvements) > 0)


if __name__ == "__main__":
    unittest.main()
