# AI Performance Improvement Loop

Every optimization follows this cycle. No shortcuts. No speculative changes.

---

## Overview

```
  RESEARCH ──→ HYPOTHESIZE ──→ IMPLEMENT ──→ BENCHMARK ──→ MEASURE ──→ DECIDE
     ↑                                                          │
     └──────────────── iterate or discard ──────────────────────┘
```

Each cycle targets a single optimization. The cycle produces either a merged PR
with documented improvement or a documented rejection with learnings.

---

## Phase 1: RESEARCH

**Actor**: Claude Project (web research) + Claude Code (code analysis)

**Goal**: Understand the target deeply before proposing any changes.

### Activities

1. **Identify target** — pick from [OPTIMIZATION-TARGETS.md](./OPTIMIZATION-TARGETS.md),
   prioritized by impact/difficulty ratio
2. **Read the code** — understand the current implementation, its callers,
   and why it was written this way
3. **Profile or analyze** — run existing benchmarks from
   [BENCHMARK-INVENTORY.md](./BENCHMARK-INVENTORY.md) to establish a baseline;
   if no benchmark exists, note that one must be created in Phase 3
4. **Check prior art** — search Nethermind GitHub issues/PRs for past attempts;
   check how Reth, Geth, or Erigon handle the same problem
5. **Assess blast radius** — identify all callers and downstream effects of
   changing the target code

### Output

Research brief containing:
- Target ID from OPTIMIZATION-TARGETS.md (e.g., EVM-1, TRIE-2)
- Current code behavior and why it's slow
- Prior art findings (what others tried, what worked/didn't)
- Caller analysis (what breaks if the API changes)
- Existing benchmark baseline numbers (if available)

### Checklist

- [ ] Read all source files involved
- [ ] Run existing benchmark (if any) and record baseline
- [ ] Search GitHub issues/PRs for prior discussion
- [ ] Check at least one competing implementation (Reth preferred)
- [ ] List all callers of the target code

---

## Phase 2: HYPOTHESIZE

**Actor**: Claude Project (strategy) + Human (validation)

**Goal**: Propose concrete changes with expected outcomes before writing code.

### Activities

1. **Propose 1–3 candidates** — each with a specific code change, not vague
   "improve performance" hand-waving
2. **Explain the mechanism** — why this change makes things faster (fewer allocs,
   better cache locality, less branching, etc.)
3. **Estimate impact** — expected % improvement, based on research findings
4. **Rank by ROI** — impact divided by implementation effort
5. **Identify risks** — correctness concerns, API breakage, edge cases

### Output

Hypothesis document containing:
- Candidate changes ranked by ROI
- For each: what changes, mechanism of improvement, expected impact, risks
- Recommended candidate to implement first
- Human approval to proceed

### Decision gate

Human approves one candidate before proceeding. If none are promising,
return to Phase 1 with a different target.

---

## Phase 3: IMPLEMENT

**Actor**: Claude Code

**Goal**: Minimal, isolated change with benchmark coverage.

### Activities

1. **Create feature branch**: `perf/<target-id>/<short-description>`
   (e.g., `perf/evm-1/remove-popaddress-toarray`)
2. **Implement the change** — touch only what's necessary, follow upstream
   coding guidelines from AGENTS.md
3. **Add or update benchmark** — every perf change MUST have a BenchmarkDotNet
   benchmark with `[MemoryDiagnoser]`; see BENCHMARK-INVENTORY.md for where
   to put it and what's already covered
4. **Run existing tests** — `dotnet test` on affected projects to verify
   correctness
5. **Format code** — `dotnet format whitespace src/Nethermind/ --folder`

### Branch naming

```
perf/<target-id>/<description>
```

Examples:
- `perf/evm-1/remove-popaddress-toarray`
- `perf/trie-1/inline-node-span`
- `perf/state-1/replace-linq-storage-flush`

### Benchmark requirements

- Must use `[MemoryDiagnoser]` to track allocations
- Must measure the specific hot path being optimized
- Must be runnable independently:
  ```bash
  dotnet run -c Release --project <benchmark-project> -- --filter "*BenchmarkClassName*"
  ```
- If modifying an existing benchmark, preserve the old method as baseline

### Output

Branch with:
- Implementation (minimal diff)
- Benchmark (new or updated)
- All existing tests passing

### Checklist

- [ ] Feature branch created from master
- [ ] Change is minimal and isolated (one optimization per branch)
- [ ] Benchmark exists with `[MemoryDiagnoser]`
- [ ] `dotnet test` passes on affected project(s)
- [ ] `dotnet format whitespace` applied
- [ ] No unrelated changes in the diff

---

## Phase 4: BENCHMARK

**Actor**: Claude Code / CI

**Goal**: Collect reliable numbers on both baseline and optimized code.

### Activities

1. **Run on master** (baseline):
   ```bash
   git stash && git checkout master
   dotnet run -c Release --project <benchmark-project> -- --filter "*BenchmarkName*" --exporters json
   ```
2. **Run on feature branch**:
   ```bash
   git checkout perf/<target-id>/<description>
   dotnet run -c Release --project <benchmark-project> -- --filter "*BenchmarkName*" --exporters json
   ```
3. **Ensure consistency**:
   - Same machine, same OS, same power profile
   - Close background applications
   - Minimum 3 BenchmarkDotNet launches (default is fine)
   - Report mean, median, and standard deviation

### Output

Raw BenchmarkDotNet results (JSON + markdown summary) for:
- Baseline (master)
- Optimized (feature branch)

Both should include: throughput (ops/s), mean time, allocated bytes, GC collections.

### Checklist

- [ ] Baseline run on master completed
- [ ] Feature branch run completed
- [ ] Same hardware and environment for both
- [ ] Results exported as JSON for archival

---

## Phase 5: MEASURE

**Actor**: Claude Code + Claude Project (analysis)

**Goal**: Compare results rigorously and flag any issues.

### Activities

1. **Compare primary metric** — throughput or mean time for the target benchmark
2. **Compare allocations** — bytes allocated, GC Gen0/Gen1/Gen2 collections
3. **Check adjacent benchmarks** — run the full benchmark class (not just the
   target method) to detect regressions in related paths
4. **Compute improvement** — `(baseline - optimized) / baseline × 100%`
5. **Assess confidence** — check standard deviation; if overlap between baseline
   and optimized ranges, the result is inconclusive

### Output

Measurement report containing:
- Primary metric comparison (table with baseline vs optimized)
- Allocation comparison
- Adjacent benchmark regression check (pass/fail)
- Computed % improvement with confidence assessment
- Recommendation: merge, iterate, or discard

### Example format

```
## Measurement Report: EVM-1 PopAddress ToArray Removal

| Metric              | Baseline (master) | Optimized (perf/evm-1) | Change  |
|---------------------|-------------------|------------------------|---------|
| Mean time           | 245.3 ns          | 198.7 ns               | -19.0%  |
| Allocated bytes     | 72 B              | 0 B                    | -100%   |
| GC Gen0             | 0.0012            | 0.0000                 | -100%   |

Adjacent benchmarks: No regressions detected.
Confidence: High (StdDev < 2% of mean for both runs).
Recommendation: Merge.
```

---

## Phase 6: DECIDE

**Actor**: Human

**Goal**: Final judgment on whether to merge, iterate, or discard.

### Decision criteria

| Outcome | Criteria | Action |
|---------|----------|--------|
| **Merge** | >= 5% improvement AND no regressions | PR to master |
| **Iterate** | Promising but < 5% or needs refinement | Back to Phase 2 |
| **Discard** | Regression, marginal, or wrong hypothesis | Document and close |

### On merge

1. Create PR following upstream [pull_request_template.md](../../.github/pull_request_template.md)
2. PR description includes measurement report from Phase 5
3. Link to the tracking issue
4. Squash-merge to keep history clean

### On discard

Document in the tracking issue:
- What was tried
- Why it didn't work
- What was learned
- Whether a different approach might work

Discarded attempts are valuable — they prevent repeating failed experiments.

---

## Tracking

Each optimization cycle is tracked as a GitHub Issue.

### Issue template

```
Title: perf(<target-id>): <short description>

## Target
<target-id> from OPTIMIZATION-TARGETS.md

## Research
<link to research brief or inline summary>

## Hypothesis
<what we expect to improve and why>

## Results
<measurement report after benchmarking>

## Decision
<merge / iterate / discard + reasoning>
```

### Labels

| Label | Phase |
|-------|-------|
| `perf-ai/research` | Phase 1: investigating |
| `perf-ai/implementing` | Phase 3: code written, benchmarking |
| `perf-ai/benchmarking` | Phase 4–5: collecting and analyzing results |
| `perf-ai/done` | Phase 6: merged |
| `perf-ai/rejected` | Phase 6: discarded with documented learnings |

### Branch lifecycle

```
master
  └─ perf/<target-id>/<description>     ← created in Phase 3
       ├─ benchmark results collected    ← Phase 4
       ├─ measurement report written     ← Phase 5
       └─ PR merged or branch deleted    ← Phase 6
```

---

## Quick Reference

### Commands

```bash
# Run a specific benchmark
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ \
  -- --filter "*EvmStackBenchmarks*"

# Run with memory tracking
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ \
  -- --filter "*EvmStackBenchmarks*" --memory

# Run tests for affected project
dotnet test src/Nethermind/Nethermind.Evm.Test/ -c Release

# Format code
dotnet format whitespace src/Nethermind/ --folder

# Export results
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ \
  -- --filter "*BlockProcessingBenchmark*" --exporters json csv markdown
```

### Files

| File | Purpose |
|------|---------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Module map, pipeline flows, data structures |
| [OPTIMIZATION-TARGETS.md](./OPTIMIZATION-TARGETS.md) | Prioritized optimization candidates |
| [BENCHMARK-INVENTORY.md](./BENCHMARK-INVENTORY.md) | All existing benchmarks + coverage gaps |
| This file | The optimization workflow |
