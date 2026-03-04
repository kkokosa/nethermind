-- Schema migration for perf-ai agent system
-- Run after init_db.py if the DB already exists
--
-- SQLite doesn't support ALTER CHECK, so we recreate loop_runs with
-- the expanded status enum. This preserves existing data.

PRAGMA foreign_keys=OFF;

BEGIN TRANSACTION;

-- 1. Rename existing table
ALTER TABLE loop_runs RENAME TO loop_runs_old;

-- 2. Create new table with expanded status + worktree_path
CREATE TABLE loop_runs (
    id                TEXT PRIMARY KEY,
    hypothesis_id     TEXT,
    target_id         TEXT NOT NULL,
    target_area       TEXT NOT NULL,

    -- Expanded status lifecycle
    status            TEXT NOT NULL DEFAULT 'research'
                      CHECK (status IN ('research','implementing','benchmarking',
                                        'pending_decision','iterating',
                                        'done','discarded','error')),

    hypothesis        TEXT NOT NULL,
    approach          TEXT,
    difficulty        TEXT CHECK (difficulty IN ('S','M','L')),
    expected_impact   TEXT CHECK (expected_impact IN ('low','med','high')),

    branch            TEXT,
    base_commit       TEXT,
    head_commit       TEXT,
    files_changed     TEXT,
    lines_changed     INTEGER,

    agent_type        TEXT,
    agent_session_id  TEXT,
    total_tokens      INTEGER DEFAULT 0,
    cost_usd          REAL DEFAULT 0,

    verdict           TEXT CHECK (verdict IN ('improvement','regression','neutral','inconclusive')),
    verdict_notes     TEXT,
    verdict_confidence REAL,

    iterations        INTEGER DEFAULT 0,

    created_at        TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at        TEXT NOT NULL DEFAULT (datetime('now')),

    -- NEW: path to git worktree for this loop run
    worktree_path     TEXT
);

-- 3. Copy data from old table
INSERT INTO loop_runs (
    id, hypothesis_id, target_id, target_area, status,
    hypothesis, approach, difficulty, expected_impact,
    branch, base_commit, head_commit, files_changed, lines_changed,
    agent_type, agent_session_id, total_tokens, cost_usd,
    verdict, verdict_notes, verdict_confidence,
    iterations, created_at, updated_at
)
SELECT
    id, hypothesis_id, target_id, target_area,
    -- Map old statuses to new (pass through valid ones)
    CASE
        WHEN status IN ('research','implementing','benchmarking','done','discarded','error')
        THEN status
        ELSE 'error'
    END,
    hypothesis, approach, difficulty, expected_impact,
    branch, base_commit, head_commit, files_changed, lines_changed,
    agent_type, agent_session_id, total_tokens, cost_usd,
    verdict, verdict_notes, verdict_confidence,
    iterations, created_at, updated_at
FROM loop_runs_old;

-- 4. Drop old table
DROP TABLE loop_runs_old;

-- 5. Recreate views that reference loop_runs (they may break on table swap)
-- The views are defined in schema.sql; re-running init_db.py or schema.sql
-- will recreate them. For safety, drop and recreate v_loop_summary here:

DROP VIEW IF EXISTS v_loop_summary;
CREATE VIEW v_loop_summary AS
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

COMMIT;

PRAGMA foreign_keys=ON;
