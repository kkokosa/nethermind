-- Perf-AI Observability Schema
-- SQLite 3.35+ (for RETURNING and JSON functions)
--
-- Usage: sqlite3 perf.db < schema.sql

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- ─── LOOP RUNS ────────────────────────────────────────────────────────────────
-- One row per optimization attempt (the atomic unit of the AI loop).

CREATE TABLE IF NOT EXISTS loop_runs (
    id                TEXT PRIMARY KEY,  -- UUID, e.g. "LR-001"
    hypothesis_id     TEXT,              -- groups retries of the same idea
    target_id         TEXT NOT NULL,     -- from OPTIMIZATION-TARGETS.md, e.g. "EVM-1"
    target_area       TEXT NOT NULL,     -- module: "evm", "trie", "state", "rlp", "db", "bp"

    -- Status lifecycle: research → implementing → benchmarking → done/discarded
    status            TEXT NOT NULL DEFAULT 'research'
                      CHECK (status IN ('research','implementing','benchmarking',
                                        'iterating','pending_decision',
                                        'done','discarded','error')),

    -- What
    hypothesis        TEXT NOT NULL,     -- free text: what we expect to improve and why
    approach          TEXT,              -- free text: what the agent actually did
    difficulty        TEXT CHECK (difficulty IN ('S','M','L')),
    expected_impact   TEXT CHECK (expected_impact IN ('low','med','high')),

    -- Git
    branch            TEXT,
    worktree_path     TEXT,              -- path to git worktree for this run
    base_commit       TEXT,              -- baseline commit hash
    head_commit       TEXT,              -- candidate commit hash
    files_changed     TEXT,              -- JSON array of file paths
    lines_changed     INTEGER,

    -- Agent metadata
    agent_type        TEXT,              -- "claude-code", "gemini-code", etc.
    agent_session_id  TEXT,
    total_tokens      INTEGER DEFAULT 0,
    cost_usd          REAL DEFAULT 0,
    iterations        INTEGER DEFAULT 0, -- internal agent retries/refinements
    reasoning_log_url TEXT,

    -- Verdict (filled in Phase 6: Decide)
    verdict           TEXT CHECK (verdict IN ('improvement','regression',
                                              'neutral','inconclusive')),
    verdict_confidence REAL,             -- 0.0–1.0
    verdict_notes     TEXT,

    -- Timestamps
    created_at        TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at        TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_loop_runs_target ON loop_runs(target_id);
CREATE INDEX idx_loop_runs_status ON loop_runs(status);
CREATE INDEX idx_loop_runs_verdict ON loop_runs(verdict);
CREATE INDEX idx_loop_runs_created ON loop_runs(created_at);


-- ─── BENCHMARK RESULTS ────────────────────────────────────────────────────────
-- One row per benchmark method per run per side (baseline / candidate).
-- Raw data from BenchmarkDotNet JSON export.

CREATE TABLE IF NOT EXISTS benchmark_results (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    loop_run_id       TEXT NOT NULL REFERENCES loop_runs(id),
    side              TEXT NOT NULL CHECK (side IN ('baseline','candidate')),

    -- Benchmark identity
    benchmark_class   TEXT NOT NULL,     -- e.g. "EvmStackBenchmarks"
    benchmark_method  TEXT NOT NULL,     -- e.g. "Uint256"
    benchmark_params  TEXT,              -- JSON of parameters, if parameterized
    full_name         TEXT NOT NULL,     -- BDN FullName for exact matching

    -- Timing (nanoseconds)
    mean_ns           REAL,
    median_ns         REAL,
    stddev_ns         REAL,
    min_ns            REAL,
    max_ns            REAL,
    p95_ns            REAL,
    iterations        INTEGER,

    -- Memory (from [MemoryDiagnoser])
    allocated_bytes   INTEGER,           -- BytesAllocatedPerOperation
    gen0_collections  REAL,
    gen1_collections  REAL,
    gen2_collections  REAL,

    -- Raw data reference
    bdn_json_path     TEXT,              -- path to BDN JSON export file

    ingested_at       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_bench_results_loop ON benchmark_results(loop_run_id, side);
CREATE INDEX idx_bench_results_method ON benchmark_results(full_name);
CREATE UNIQUE INDEX idx_bench_results_unique
    ON benchmark_results(loop_run_id, side, full_name);


-- ─── COMPARISONS ──────────────────────────────────────────────────────────────
-- Derived: one row per benchmark method per loop run.
-- Computed by compare.py from baseline/candidate pairs.

CREATE TABLE IF NOT EXISTS comparisons (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    loop_run_id       TEXT NOT NULL REFERENCES loop_runs(id),
    full_name         TEXT NOT NULL,     -- benchmark FullName

    -- Deltas
    delta_mean_pct    REAL,              -- (candidate - baseline) / baseline × 100
    delta_alloc_pct   REAL,              -- same for allocated_bytes

    -- Statistical tests
    p_value           REAL,              -- Mann-Whitney U test
    is_significant    INTEGER,           -- 1 if p < 0.05 AND effect > noise floor
    effect_size       REAL,              -- Cohen's d
    ci_lower_pct      REAL,              -- 95% CI lower bound (% change)
    ci_upper_pct      REAL,              -- 95% CI upper bound (% change)

    -- Baseline/candidate summary (for display without joining)
    baseline_mean_ns  REAL,
    candidate_mean_ns REAL,
    baseline_alloc    INTEGER,
    candidate_alloc   INTEGER,

    computed_at       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX idx_comparisons_unique
    ON comparisons(loop_run_id, full_name);


-- ─── NULL RUNS (noise floor calibration) ──────────────────────────────────────
-- Same baseline run against itself, to measure inherent environment variance.

CREATE TABLE IF NOT EXISTS null_runs (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name         TEXT NOT NULL,
    delta_mean_pct    REAL,              -- should be ~0 if environment is stable
    stddev_pct        REAL,              -- the noise floor for this benchmark
    run_date          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_null_runs_date ON null_runs(run_date);


-- ─── PROGRESS SNAPSHOTS ───────────────────────────────────────────────────────
-- Time-series of composite performance indices. One row per snapshot.
-- Recomputed after each merged loop run.

CREATE TABLE IF NOT EXISTS progress_snapshots (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    snapshot_date     TEXT NOT NULL,
    trigger_loop_id   TEXT REFERENCES loop_runs(id), -- which merge triggered this

    -- Composite indices (baseline = 100, lower = faster)
    perf_index        REAL NOT NULL,
    evm_index         REAL,
    trie_index        REAL,
    state_index       REAL,
    rlp_index         REAL,
    db_index          REAL,
    bp_index          REAL,

    -- Noise floor at time of snapshot
    noise_floor_pct   REAL,

    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_progress_date ON progress_snapshots(snapshot_date);


-- ─── BENCHMARK REGISTRY ───────────────────────────────────────────────────────
-- Known benchmarks and their weights for the performance index calculation.

CREATE TABLE IF NOT EXISTS benchmark_registry (
    full_name         TEXT PRIMARY KEY,
    short_name        TEXT,              -- display name for dashboard
    area              TEXT NOT NULL,     -- "evm", "trie", "state", "rlp", "db", "bp"
    weight            REAL DEFAULT 1.0,  -- weight in perf index calculation
    is_key_benchmark  INTEGER DEFAULT 0, -- 1 = shown in dashboard trends
    baseline_mean_ns  REAL,              -- value at fork point (index = 100)
    baseline_alloc    INTEGER
);


-- ─── VIEWS ────────────────────────────────────────────────────────────────────

-- Loop runs with aggregated comparison stats
CREATE VIEW IF NOT EXISTS v_loop_summary AS
SELECT
    lr.*,
    COUNT(c.id) AS compared_benchmarks,
    MIN(c.delta_mean_pct) AS best_delta_pct,
    AVG(c.delta_mean_pct) AS avg_delta_pct,
    SUM(CASE WHEN c.is_significant = 1 AND c.delta_mean_pct < 0 THEN 1 ELSE 0 END) AS significant_improvements,
    SUM(CASE WHEN c.is_significant = 1 AND c.delta_mean_pct > 0 THEN 1 ELSE 0 END) AS significant_regressions
FROM loop_runs lr
LEFT JOIN comparisons c ON lr.id = c.loop_run_id
GROUP BY lr.id;

-- Agent effectiveness
CREATE VIEW IF NOT EXISTS v_agent_stats AS
SELECT
    agent_type,
    COUNT(*) AS total_loops,
    SUM(CASE WHEN verdict = 'improvement' THEN 1 ELSE 0 END) AS improvements,
    SUM(CASE WHEN verdict = 'regression' THEN 1 ELSE 0 END) AS regressions,
    SUM(CASE WHEN verdict = 'neutral' THEN 1 ELSE 0 END) AS neutrals,
    SUM(CASE WHEN status IN ('research','implementing','benchmarking') THEN 1 ELSE 0 END) AS in_progress,
    ROUND(100.0 * SUM(CASE WHEN verdict = 'improvement' THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN verdict IS NOT NULL THEN 1 ELSE 0 END), 0), 1) AS hit_rate_pct,
    ROUND(AVG(cost_usd), 2) AS avg_cost,
    ROUND(SUM(cost_usd), 2) AS total_cost,
    CAST(AVG(total_tokens) AS INTEGER) AS avg_tokens
FROM loop_runs
GROUP BY agent_type;

-- Area effectiveness
CREATE VIEW IF NOT EXISTS v_area_stats AS
SELECT
    target_area,
    COUNT(*) AS attempted,
    SUM(CASE WHEN verdict = 'improvement' THEN 1 ELSE 0 END) AS improved,
    ROUND(100.0 * SUM(CASE WHEN verdict = 'improvement' THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 0) AS hit_rate_pct,
    ROUND(AVG(CASE WHEN verdict IS NOT NULL THEN (
        SELECT AVG(c2.delta_mean_pct) FROM comparisons c2
        WHERE c2.loop_run_id = loop_runs.id AND c2.is_significant = 1
    ) END), 1) AS avg_significant_delta
FROM loop_runs
GROUP BY target_area;

-- Latest noise floor per benchmark
CREATE VIEW IF NOT EXISTS v_noise_floor AS
SELECT
    full_name,
    delta_mean_pct,
    stddev_pct,
    run_date
FROM null_runs nr1
WHERE run_date = (SELECT MAX(run_date) FROM null_runs nr2 WHERE nr2.full_name = nr1.full_name);
