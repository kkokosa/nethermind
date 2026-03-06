-- Migration 001: Add optimization_targets table for dynamic backlog
-- Idempotent via IF NOT EXISTS

CREATE TABLE IF NOT EXISTS optimization_targets (
    id              TEXT PRIMARY KEY,
    area            TEXT NOT NULL,
    title           TEXT NOT NULL,
    description     TEXT,
    difficulty      TEXT CHECK (difficulty IN ('S','M','L')),
    impact          TEXT CHECK (impact IN ('low','med','high')),
    priority_score  REAL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'proposed'
                    CHECK (status IN ('proposed','ready','active',
                                      'completed','exhausted','rejected')),
    source          TEXT NOT NULL DEFAULT 'seed',
    parent_id       TEXT REFERENCES optimization_targets(id),
    proposed_by     TEXT,
    related_targets TEXT,
    confidence      REAL,
    reject_reason   TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_targets_status ON optimization_targets(status);
CREATE INDEX IF NOT EXISTS idx_targets_area ON optimization_targets(area);
CREATE INDEX IF NOT EXISTS idx_targets_priority ON optimization_targets(priority_score DESC);
