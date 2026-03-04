@./AGENTS.md

# Performance Fork Context

This is a fork of [NethermindEth/nethermind](https://github.com/NethermindEth/nethermind) dedicated to AI-assisted performance optimization.
Every change must be benchmarked and measured. No speculative optimizations.

## Key Modules (by performance priority)

1. **Nethermind.Evm** — EVM execution, opcode dispatch, stack/memory ops
2. **Nethermind.Trie** — Patricia trie, state storage, proof generation
3. **Nethermind.State** — World state, storage trees, caching
4. **Nethermind.Db.Rocks** — RocksDB wrapper, read/write patterns
5. **Nethermind.Serialization.Rlp** — RLP encode/decode (hot path)
6. **Nethermind.JsonRpc** — JSON-RPC serialization and dispatch
7. **Nethermind.Network** — P2P protocol, message handling
8. **Nethermind.Consensus** — Block processing pipeline

## Knowledge Files

Project knowledge files are in [docs/perf-ai/](./docs/perf-ai/). Read them for context on architecture, optimization targets, benchmarks, and the AI development loop.

## Performance Coding Standards

These extend the upstream coding guidelines in AGENTS.md:

- All perf changes MUST have a BenchmarkDotNet benchmark
- Use `[MemoryDiagnoser]` on all benchmarks
- Prefer `Span<T>` and `stackalloc` over heap allocations in hot paths
- Use `[MethodImpl(MethodImplOptions.AggressiveInlining)]` judiciously
- Profile before optimizing — use dotnet-counters, PerfView, or dotTrace
- Keep changes minimal and isolated — one optimization per PR
- Compare with baseline: always run benchmarks on both master and feature branch
- Run specific benchmark: `dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ -- --filter "*EvmStack*"`

## AI Development Loop

1. **RESEARCH** — Analyze module, profile hotspots, read related issues/PRs
2. **HYPOTHESIZE** — Propose optimization with expected impact estimate
3. **IMPLEMENT** — Write the change + benchmark on a feature branch
4. **BENCHMARK** — Run BenchmarkDotNet, compare to baseline
5. **MEASURE** — Document results with exact numbers
6. **DECIDE** — If >5% improvement with no regressions, PR. Otherwise iterate or discard.

## Performance Investigation Commands

```bash
# Profile with dotnet-counters
dotnet-counters monitor --process-id <PID> --counters System.Runtime

# Run specific benchmark
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ -- --filter "*EvmStack*"

# Memory analysis
dotnet-gcdump collect --process-id <PID>
```

## What NOT to Do

- Don't change public APIs without discussion
- Don't optimize code that isn't on a hot path (measure first)
- Don't introduce unsafe code without benchmarked justification
- Don't skip tests — correctness > performance
- Don't merge upstream changes into perf branches without rebasing cleanly

## Agent System

Autonomous optimization agents in `tools/perf-agents/` (runs in WSL2 + zellij):
- `start.sh --workers N` -- launch zellij session with server + N worker tabs
- `stop.sh` -- kill zellij session + cleanup
- `attach.sh` -- reattach to running session
- `orchestrate.py --status` -- check system state
- Dashboard: http://localhost:4040 (when running)

Each worker runs as a zellij tab: claims a target -> renames tab to W:<TARGET> ->
creates git worktree -> researches -> implements -> benchmarks ->
waits for human approval via dashboard.

Key files:
- `AGENT-SYSTEM.md` -- full architecture
- `claim_target.py` -- atomic target claim from SQLite
- `worker.sh` -- per-target loop (wraps Claude Code)
- `decision-server.py` -- dashboard HTTP server + decision API
- `PROMPTS/` -- Claude Code prompt templates
