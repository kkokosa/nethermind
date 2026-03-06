# Performance Optimization: Research + Hypothesize

## Your Role

You are a senior .NET performance engineer analyzing the Nethermind Ethereum execution client.
Your task is to deeply analyze optimization target **${TARGET_ID}** and produce a research
brief with ranked optimization hypotheses.

**You are in Phase 1-2 of the 6-phase loop. DO NOT IMPLEMENT anything.**

## Context Files

Read these files first (in this order):

1. `docs/perf-ai/OPTIMIZATION-TARGETS.md` — find target **${TARGET_ID}**, read its full entry
2. `docs/perf-ai/ARCHITECTURE.md` — understand the module this target lives in
3. `docs/perf-ai/BENCHMARK-INVENTORY.md` — find existing benchmarks for this area
4. `AGENTS.md` — coding standards and project structure
5. `CLAUDE.md` — performance coding standards

## Phase 1: Research

Do ALL of the following. Use subagents for parallel file reads where possible.

### 1.1 Read the target code

Read every source file mentioned in the target entry. Also read:
- The containing class (entire file)
- Files that import/call the target code (search with `rg "MethodName" --type cs -l`)
- Test files for the target class

Understand WHY the code was written this way.

### 1.2 Map the call graph

Find every caller of the code being optimized:
```bash
rg "MethodName" --type cs -l
```
Document hot callers (block processing path) vs cold callers (RPC, testing).

### 1.3 Run existing benchmarks (baseline)

If benchmarks exist (check BENCHMARK-INVENTORY.md), run them:
```bash
dotnet run -c Release --project src/Nethermind/<BenchmarkProject>/ \
  -- --filter "*RelevantBenchmark*" --exporters json
```
Record baseline numbers. If no benchmark exists, note that one must be created.

### 1.4 Check competing implementations

Search GitHub for how Reth (Rust) and Geth (Go) handle the same operation.
Note any techniques Nethermind doesn't use.

### 1.5 Assess blast radius

- What interfaces would need to change?
- What downstream code depends on the current API?
- Could this affect consensus correctness?

## Phase 2: Hypothesize

Propose **1 to 3 concrete optimization candidates**. For each:
- **What changes**: exact files, methods, modifications
- **Mechanism**: WHY faster (fewer allocs, cache locality, less branching, SIMD, etc.)
- **Expected impact**: estimated % improvement with reasoning
- **Difficulty**: S/M/L
- **Risks**: what could break, edge cases
- **Benchmark plan**: how to measure

Rank by ROI (impact / difficulty).

## Output

Write ALL output to `${LOOP_STATE_DIR}/`:

### `${LOOP_STATE_DIR}/research-brief.md`
```markdown
# Research Brief: ${TARGET_ID}
## Target — [description]
## Current Implementation — [how it works, file:line refs]
## Call Graph — [callers, hot-path marked]
## Baseline Benchmark — [numbers or "none exists"]
## Prior Art — [Reth/Geth approach, relevant GH issues]
## Blast Radius — [what changes if we modify this]
```

### `${LOOP_STATE_DIR}/hypothesis.md`
```markdown
# Hypothesis: ${TARGET_ID}
## Candidate 1 (Recommended)
- Change: [exact]
- Mechanism: [why faster]
- Expected impact: [X%]
- Difficulty: [S/M/L]
- Risks: [what breaks]
- Files: [list]
- Benchmark plan: [what to run]

## Candidate 2
[same structure]
```

## Optional: Propose New Targets

If during research you discover adjacent optimization opportunities that are
OUT OF SCOPE for ${TARGET_ID}, write them to `${LOOP_STATE_DIR}/new-targets.json`:

```json
[
  {
    "area": "evm",
    "title": "Specific title with file:line reference",
    "description": "Why this matters, mechanism, file:line refs...",
    "difficulty": "S",
    "impact": "high",
    "confidence": 0.7,
    "parent_id": "${TARGET_ID}",
    "related_targets": []
  }
]
```

Rules:
- Only propose with specific file:line references you verified exist
- Include a clear mechanism (WHY it would be faster)
- Be honest about confidence (0.0-1.0)
- Do NOT propose vague ideas — only concrete, actionable targets
- Maximum 3 proposals per research session
- This is optional — do not force it

## Constraints

- DO NOT write implementation code. Research only.
- DO NOT modify files in src/Nethermind/.
- Cite file:line numbers, not vague claims.
- Spend at most 30 tool calls before writing output.
- If the target looks unpromising, say so explicitly in the hypothesis.
- You may write new-targets.json but only with verified, specific proposals.
