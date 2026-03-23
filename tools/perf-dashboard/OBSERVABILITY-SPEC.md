# Perf-AI Observability System

## Purpose

A self-contained observability dashboard and data pipeline for tracking the
AI-driven performance improvement loop. Every optimization loop run produces
benchmark data; this system ingests, compares, stores, and visualizes it.

## Architecture Overview

```
BenchmarkDotNet JSON ──→ ingest.py ──→ SQLite DB ──→ React Dashboard
                              ↑                           ↑
                         compare.py                  Serves via
                      (statistical tests)         GitHub Pages or
                                                  local dev server
```

All components live in `tools/perf-dashboard/` inside the fork repo.

## Directory Structure

```
tools/perf-dashboard/
├── README.md                    # Quick-start for running locally
├── schema.sql                   # SQLite schema (source of truth)
├── db/
│   └── perf.db                  # SQLite database (gitignored)
├── scripts/
│   ├── ingest.py                # BDN JSON → SQLite ingestion
│   ├── compare.py               # Statistical comparison (Mann-Whitney U)
│   ├── register_loop.py         # Create a new loop run entry
│   ├── verdict.py               # Record verdict for a loop run
│   ├── null_run.py              # Ingest noise-floor calibration run
│   └── export_dashboard_data.py # SQLite → JSON for dashboard consumption
├── dashboard/
│   ├── package.json
│   ├── index.html
│   └── src/
│       ├── App.jsx              # Main dashboard (based on mockup)
│       ├── data/                # JSON data files exported from SQLite
│       │   ├── loops.json
│       │   ├── progress.json
│       │   ├── benchmarks.json
│       │   └── agents.json
│       └── components/          # Extracted from monolithic mockup
│           ├── LoopRegistry.jsx
│           ├── ProgressChart.jsx
│           ├── BenchmarkTrends.jsx
│           ├── AgentEffectiveness.jsx
│           ├── AreaHitRate.jsx
│           ├── FailureAnalysis.jsx
│           ├── TargetCoverage.jsx
│           └── ActivityLog.jsx
├── mockup/
│   └── dashboard-mockup.jsx     # Original mockup (reference only, do not modify)
└── tests/
    ├── test_ingest.py
    ├── test_compare.py
    └── fixtures/
        ├── sample_bdn_output.json
        └── sample_bdn_baseline.json
```

## Data Model

See `schema.sql` for the complete DDL. Key entities:

### loop_runs
The atomic unit — one hypothesis, one attempt. Fields:
- Identity: `id` (UUID), `hypothesis_id`, `target_id` (from OPTIMIZATION-TARGETS.md)
- Status: `status` (running/passed/failed/inconclusive/error)
- Verdict: `verdict` (improvement/regression/neutral/inconclusive), `verdict_confidence`
- Git: `branch`, `base_commit`, `head_commit`
- Agent: `agent_type`, `total_tokens`, `cost_usd`, `iterations`
- Metadata: `hypothesis` (text), `approach` (text), `difficulty`, `expected_impact`

### benchmark_results
One row per benchmark method per run per side (baseline/candidate). Contains all
BenchmarkDotNet standard outputs: mean_ns, median_ns, stddev_ns, allocated_bytes,
gen0/gen1/gen2 collections, plus a link to the raw BDN JSON export.

### comparisons
Derived from benchmark_results pairs. One row per benchmark method per run:
- `delta_mean_pct`, `delta_alloc_pct`
- `p_value` (Mann-Whitney U test)
- `is_significant` (p < 0.05)
- `effect_size` (Cohen's d)
- `ci_lower_pct`, `ci_upper_pct` (95% confidence interval)

### null_runs
Noise floor calibration: same baseline run against itself. Used to establish
the minimum detectable effect size for the current CI environment.

### progress_snapshots
Time-series of the composite performance index and per-area indices, computed
after each merged loop run. One row per snapshot date.

## Statistical Methodology

### Comparison (compare.py)

For each benchmark method with baseline and candidate results:

1. **Mann-Whitney U test** (scipy.stats.mannwhitneyu) — non-parametric, works
   with BDN's typically non-normal distributions
2. **Effect size** — Cohen's d = (mean_baseline - mean_candidate) / pooled_stddev
3. **95% confidence interval** on the percentage difference using bootstrap
   (1000 resamples) or analytical approximation
4. **Significance threshold** — p < 0.05, but also require effect size > noise floor

### Performance Index

Weighted geometric mean of key benchmark results, normalized to baseline=100.
Lower is better (like a time index).

Weight categories:
- Block processing benchmarks: weight 3 (closest to real-world impact)
- EVM opcode benchmarks: weight 2 (hot inner loop)
- Trie/state benchmarks: weight 2 (commit path)
- RLP/serialization: weight 1
- Other: weight 1

Formula:
```
index = 100 × exp(Σ(wᵢ × ln(current_i / baseline_i)) / Σ(wᵢ))
```

## CLI Interface

All scripts are invoked from repo root. Python 3.10+, dependencies: scipy, numpy.

### Register a new loop run
```bash
python tools/perf-dashboard/scripts/register_loop.py \
  --target-id EVM-1 \
  --hypothesis "Remove .ToArray() from PopAddress" \
  --branch perf/evm-1/remove-popaddress-toarray \
  --agent claude-code \
  --difficulty S \
  --expected-impact high
# Output: LR-001 (the loop run ID)
```

### Ingest BDN results
```bash
# Ingest baseline results
python tools/perf-dashboard/scripts/ingest.py \
  --loop-run LR-001 \
  --side baseline \
  --bdn-json path/to/BenchmarkDotNet.Artifacts/results/*.json

# Ingest candidate results
python tools/perf-dashboard/scripts/ingest.py \
  --loop-run LR-001 \
  --side candidate \
  --bdn-json path/to/BenchmarkDotNet.Artifacts/results/*.json
```

### Run comparison
```bash
python tools/perf-dashboard/scripts/compare.py --loop-run LR-001
# Output: comparison table + recommendation (merge/iterate/discard)
```

### Record verdict
```bash
python tools/perf-dashboard/scripts/verdict.py \
  --loop-run LR-001 \
  --verdict improvement \
  --notes "19% faster, zero allocs, no regressions"
```

### Export dashboard data
```bash
python tools/perf-dashboard/scripts/export_dashboard_data.py \
  --output-dir tools/perf-dashboard/dashboard/src/data/
# Generates: loops.json, progress.json, benchmarks.json, agents.json
```

### Noise floor calibration
```bash
python tools/perf-dashboard/scripts/null_run.py \
  --bdn-json path/to/null-run-results/*.json
```

## Dashboard

React app (Vite) reading from static JSON files in `src/data/`. No backend server
needed — the export script regenerates the JSON files, then the dashboard reads them.

### Reference mockup
`mockup/dashboard-mockup.jsx` contains the complete single-file mockup with hardcoded
data. Use this as the visual specification. The production dashboard should:

1. Split into components (see directory structure above)
2. Read from JSON files instead of hardcoded data
3. Keep the same visual design, layout, and color scheme
4. Keep all interactive features (filters, row selection, detail panel)

### Tech stack
- Vite + React 18
- Recharts (already used in mockup)
- Tailwind CSS (utility classes only) OR inline styles matching mockup
- No other dependencies needed

### Running locally
```bash
cd tools/perf-dashboard/dashboard
npm install
npm run dev
# Opens at http://localhost:5173
```

## Integration with AI Loop

The observability system integrates with the workflow in AI-LOOP-DESIGN.md:

| Loop Phase | Observability Action |
|------------|---------------------|
| Phase 1: Research | `register_loop.py` — create the loop run entry |
| Phase 3: Implement | Update branch/commit info |
| Phase 4: Benchmark | `ingest.py` — baseline then candidate results |
| Phase 5: Measure | `compare.py` — statistical comparison |
| Phase 6: Decide | `verdict.py` — record outcome, `export_dashboard_data.py` |

## Implementation Priority

Build in this order. Each step is independently useful.

1. **schema.sql** — DDL for all tables. Can be tested with `sqlite3 perf.db < schema.sql`.
2. **register_loop.py** — Generates UUID, inserts loop_runs row.
3. **ingest.py** — Parses BDN JSON format, inserts benchmark_results rows.
4. **compare.py** — Reads baseline/candidate pairs, computes stats, inserts comparisons.
5. **verdict.py** — Updates loop_runs with verdict and notes.
6. **export_dashboard_data.py** — Queries SQLite, writes JSON files.
7. **Dashboard scaffold** — Vite + React app, reading from JSON, monolithic first.
8. **Dashboard components** — Split monolithic app into components from mockup.
9. **null_run.py** — Noise floor calibration pipeline.
10. **Tests** — For ingest, compare, and export scripts.

## BenchmarkDotNet JSON Format Reference

BDN exports to `BenchmarkDotNet.Artifacts/results/`. The JSON structure:

```json
{
  "Title": "EvmStackBenchmarks",
  "Benchmarks": [
    {
      "FullName": "Nethermind.Evm.Benchmark.EvmStackBenchmarks.Uint256",
      "Statistics": {
        "Mean": 245.3,
        "Median": 243.1,
        "StandardDeviation": 4.2,
        "Min": 238.0,
        "Max": 260.1,
        "Percentiles": { "P95": 252.0 },
        "N": 100
      },
      "Memory": {
        "BytesAllocatedPerOperation": 72,
        "Gen0Collections": 0.0012,
        "Gen1Collections": 0,
        "Gen2Collections": 0
      }
    }
  ]
}
```

The `ingest.py` script must handle:
- Multiple benchmark files per invocation (glob pattern)
- Missing Memory section (when [MemoryDiagnoser] not present)
- Parameterized benchmarks (parameters appear in FullName)
