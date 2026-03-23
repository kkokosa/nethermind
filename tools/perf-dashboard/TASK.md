# Task: Implement Perf-AI Observability System

## Context

Read these files before starting (in this order):
1. `docs/perf-ai/AI-LOOP-DESIGN.md` - the optimization loop this system tracks
2. `docs/perf-ai/OPTIMIZATION-TARGETS.md` - the 17 targets being optimized
3. `docs/perf-ai/BENCHMARK-INVENTORY.md` - existing BDN benchmarks
4. `tools/perf-dashboard/OBSERVABILITY-SPEC.md` - full system specification
5. `tools/perf-dashboard/schema.sql` - SQLite data model
6. `tools/perf-dashboard/mockup/dashboard-mockup.jsx` - visual reference

## What to build

A data pipeline + React dashboard for tracking AI-driven performance loop runs.

## Implementation steps

Complete each step fully before moving to the next. After each step, verify it
works by running the provided test command.

### Step 1: SQLite schema

Create the database from the provided schema.

```bash
mkdir -p tools/perf-dashboard/db
sqlite3 tools/perf-dashboard/db/perf.db < tools/perf-dashboard/schema.sql
```

Verify: `sqlite3 tools/perf-dashboard/db/perf.db ".tables"`
Expected: benchmark_registry benchmark_results comparisons loop_runs null_runs progress_snapshots

Add `tools/perf-dashboard/db/perf.db` to `.gitignore`.

### Step 2: register_loop.py

Create `tools/perf-dashboard/scripts/register_loop.py`.

Requirements:
- CLI args: --target-id, --hypothesis, --branch, --agent, --difficulty, --expected-impact
- Generates sequential ID: LR-001, LR-002, etc. (query max existing)
- Derives target_area from target_id prefix (EVM to evm, TRIE to trie, etc.)
- Inserts into loop_runs table
- Prints the generated ID to stdout
- Uses only stdlib (sqlite3, argparse)

Test:
```bash
python tools/perf-dashboard/scripts/register_loop.py \
  --target-id EVM-1 \
  --hypothesis "Remove .ToArray() from PopAddress" \
  --branch perf/evm-1/remove-popaddress-toarray \
  --agent claude-code --difficulty S --expected-impact high
```

### Step 3: ingest.py

Create `tools/perf-dashboard/scripts/ingest.py`.

Requirements:
- CLI args: --loop-run, --side (baseline|candidate), --bdn-json (glob pattern)
- Parses BenchmarkDotNet JSON export format (see OBSERVABILITY-SPEC.md)
- Extracts: FullName, Statistics (Mean/Median/StdDev/Min/Max/P95/N), Memory
- Handles missing Memory section gracefully (NULL fields)
- Handles parameterized benchmarks (params in FullName)
- Inserts into benchmark_results with ON CONFLICT upsert
- Prints summary: "Ingested N benchmarks for LR-001 (baseline)"
- Dependencies: stdlib only

### Step 4: compare.py

Create `tools/perf-dashboard/scripts/compare.py`.

Requirements:
- CLI args: --loop-run
- For each benchmark with both baseline AND candidate results:
  - delta_mean_pct = (candidate - baseline) / baseline * 100
  - delta_alloc_pct similarly
  - Mann-Whitney U test if scipy available, heuristic fallback otherwise
  - Cohen's d effect size
- Insert into comparisons table
- Print markdown comparison table to stdout
- Print recommendation: MERGE (5%+ improvement, no regressions), ITERATE, DISCARD
- Dependencies: scipy optional (graceful fallback)

### Step 5: verdict.py

Create `tools/perf-dashboard/scripts/verdict.py`.

Requirements:
- CLI args: --loop-run, --verdict, --notes (optional)
- Updates loop_runs: verdict, verdict_notes, status, updated_at
- verdict=improvement sets status=done; otherwise status=discarded
- Computes verdict_confidence from comparisons data
- Prints confirmation

### Step 6: export_dashboard_data.py

Create `tools/perf-dashboard/scripts/export_dashboard_data.py`.

Requirements:
- CLI args: --output-dir (default: tools/perf-dashboard/dashboard/src/data/)
- Queries SQLite views and tables
- Exports 4 JSON files: loops.json, progress.json, benchmarks.json, agents.json
- See OBSERVABILITY-SPEC.md for exact JSON shapes

### Step 7: Dashboard scaffold

Create Vite + React project in `tools/perf-dashboard/dashboard/`.

```bash
cd tools/perf-dashboard/dashboard
npm create vite@latest . -- --template react
npm install recharts
```

Requirements:
- Copy mockup visual design exactly (colors, fonts, layout, spacing)
- Replace hardcoded data with JSON imports from src/data/
- Single App.jsx initially
- Add Google Fonts link for JetBrains Mono in index.html

### Step 8: Component extraction

Split App.jsx into: LoopRegistry, ProgressChart, BenchmarkTrends,
AgentEffectiveness, AreaHitRate, FailureAnalysis, TargetCoverage, ActivityLog.
Each receives data via props.

### Step 9: null_run.py and Step 10: Tests

See OBSERVABILITY-SPEC.md for details.

## Constraints

- Python scripts: stdlib + scipy only. No pandas, no sqlalchemy.
- Dashboard: React + Recharts + Vite only.
- All paths relative to repo root.
- Scripts invoked from repo root: `python tools/perf-dashboard/scripts/X.py`
- DB path defaults to tools/perf-dashboard/db/perf.db, overridable via --db

## Definition of done

- sqlite3 schema creates all tables and views
- Full CLI workflow: register, ingest, compare, verdict, export
- Dashboard loads from JSON and renders all 8 sections
- Visual matches mockup (dark theme, mono font, same layout)
- Filters and row selection work
- npm run dev starts without errors
