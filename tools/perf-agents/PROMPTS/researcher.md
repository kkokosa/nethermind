# Backlog Researcher: Discover New Optimization Targets

You are analyzing the Nethermind Ethereum execution client for new performance
optimization opportunities that are not yet in the backlog.

## Current Backlog
${BACKLOG_SUMMARY}

## Instructions

1. Read `docs/perf-ai/OPTIMIZATION-TARGETS.md` (existing targets)
2. Read `docs/perf-ai/ARCHITECTURE.md` (module overview)
3. Identify areas with LOW coverage or where all targets are completed/exhausted
4. Deep-dive those modules, searching for:
   - `.ToArray()`, `new byte[]`, `new List<` (allocations on hot paths)
   - `.Where(`, `.Select(`, `.OrderBy(` (LINQ in hot paths)
   - `Interlocked.`, `lock (`, `Monitor.` (contention points)
   - Repeated computations, missing caches
   - Large struct copies, boxing
5. Write `${RESEARCH_OUTPUT_DIR}/new-targets.json` with 1-5 proposals

## Output Format

Write `${RESEARCH_OUTPUT_DIR}/new-targets.json`:

```json
[
  {
    "area": "evm",
    "title": "Specific title with file:line reference",
    "description": "Why this matters, mechanism, file:line refs...",
    "difficulty": "S",
    "impact": "high",
    "confidence": 0.7,
    "parent_id": null,
    "related_targets": []
  }
]
```

## Constraints

- Only propose with verified file:line references (you must READ the file first)
- Do not re-propose existing targets (check backlog summary above)
- Minimum confidence 0.5
- Maximum 30 tool calls
- Focus on HOT PATHS: block processing, EVM execution, trie operations, RLP encoding
- Include a clear mechanism: WHY the proposed change would be faster
- Be specific: name the exact method, class, and line numbers
