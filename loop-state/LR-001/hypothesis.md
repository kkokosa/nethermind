# Hypothesis: TRIE-5

## Estimated Impact Context

Per dirty node insertion: 8 Interlocked ops × ~10-30ns each = ~80-240ns overhead.
At ~4000 new cache entries per block: **320-960µs per block**.
With block processing at 50-100ms: **~0.5-2% of block time**.

The global counters (4 ops, all 256 shards competing on 4 cache lines) are the
bottleneck. Per-shard counters (4 ops) have lower contention but still cost ~10ns
each for the memory barrier.

---

## Candidate 1 (Recommended): Eliminate per-shard Interlocked, make global counters non-atomic

### Change

**TrieStoreDirtyNodesCache.cs** — `IncrementMemory()` and `DecrementMemory()`:
- Replace all 4 `Interlocked.Increment/Add` with simple `_count++; _totalMemory += memoryUsage;`
- Remove calls to `_trieStore.IncrementMemoryUsedByDirtyCache()` and `_trieStore.DecreaseMemoryUsedByDirtyCache()`

**TrieStore.cs** — `IncrementMemoryUsedByDirtyCache()` and `DecreaseMemoryUsedByDirtyCache()`:
- Remove these methods entirely
- `CaptureCurrentState()` (line 556): compute global counters on-demand by summing per-shard values (like `RecalculateTotalMemoryUsage()` does)
- `MemoryUsedByDirtyCache` / `DirtyMemoryUsedByDirtyCache` properties: compute by summing shards
- Update `Metrics.*` in `CaptureCurrentState()` to keep monitoring working

### Mechanism

**Why faster:**
1. Eliminates all 8 Interlocked operations (full memory barriers) from the hot insertion path
2. Removes cache line bouncing on the 4 global counters shared by all 256 shards
3. Per-shard non-atomic `+=` compiles to a simple load+add+store — ~1ns vs ~10-30ns for Interlocked

**Why safe:**
1. Per-shard counters are fully recomputed from scratch during `PruneCache()` — drift is corrected
2. `SaveOrReplaceInDirtyNodesCache` already doesn't update ANY counters — they're already approximate
3. Non-atomic `long` read/write is atomic on 64-bit .NET (no torn reads), only `++` is non-atomic
4. During pruning (when counters matter), insertions are redirected to `_commitBuffer`, so main shard counters are not being modified
5. Pruning decisions are threshold-based and self-correcting

**Trade-off:**
- `CaptureCurrentState()` becomes O(256) loop over shards instead of reading 2 global values
- Called once per block commit in `Prune()` — 256 cache line reads ≈ ~1-2µs — negligible
- Metrics update frequency decreases from per-insertion to per-prune-check

### Expected Impact: ~1-2% block processing improvement
- Eliminates ~320-960µs per block of memory barrier + cache line bouncing overhead
- Confidence: 0.6 — measurable but at the lower end of what benchmarks can reliably detect

### Difficulty: S
- ~30 lines changed across 2 files
- No API changes (properties remain, just computed differently)
- No interface changes

### Risks
1. **Monitoring lag**: Metrics update less frequently (per prune-check vs per-insertion). Mitigated by updating metrics in `CaptureCurrentState()`.
2. **Counter drift**: Between prune cycles, per-shard counters may be slightly off due to non-atomic `++`. Maximum drift: number of concurrent insertions to the same shard during one `++` cycle — effectively 0-1 per operation. Corrected at prune time.
3. **Test breakage**: `TreeStoreTests.cs:869` checks `ExpectedPerNodeKeyMemorySize` — may need adjustment if it checks counter precision.

### Files
- `src/Nethermind/Nethermind.Trie/Pruning/TrieStoreDirtyNodesCache.cs` (lines 218-242)
- `src/Nethermind/Nethermind.Trie/Pruning/TrieStore.cs` (lines 129-170, 556-559, 985-1006)

### Benchmark Plan
1. **New benchmark**: `DirtyNodesCacheInsertionBenchmark` in `Nethermind.Trie.Benchmark/`
   - Create a DirtyNodesCache with a mock TrieStore
   - Insert N nodes (1000, 10000) via `FindCachedOrUnknown`
   - Measure throughput (ops/sec) and allocation
   - Use `[MemoryDiagnoser]`
   - Compare before/after on same benchmark
2. **Existing benchmark**: Run `PatriciaTreeBenchmarks` (bulk insert + commit scenarios) to verify no regression
3. **Integration**: Run `BlockProcessingBenchmark` with `--memory` to measure end-to-end impact

---

## Candidate 2: Per-shard non-atomic only (conservative)

### Change

**TrieStoreDirtyNodesCache.cs** — `IncrementMemory()` and `DecrementMemory()`:
- Replace per-shard `Interlocked` with non-atomic ops
- **Keep** the call to `_trieStore.IncrementMemoryUsedByDirtyCache()` (global Interlocked unchanged)

### Mechanism

Same safety reasoning as Candidate 1 for per-shard counters. Keeps global counters exactly correct.

### Expected impact: ~0.3-0.5% block processing improvement
- Saves 4 Interlocked ops per insertion (shard-level)
- Global contention (the bigger cost) remains

### Difficulty: S
- ~10 lines changed in 1 file

### Risks
- Even lower risk than Candidate 1: global counters remain perfectly accurate
- Pruning decisions unaffected

### Files
- `src/Nethermind/Nethermind.Trie/Pruning/TrieStoreDirtyNodesCache.cs` (lines 218-242)

### Benchmark Plan
Same as Candidate 1.

---

## Candidate 3: Thread-local batching with periodic flush

### Change

Replace per-insertion atomic updates with `[ThreadStatic]` accumulators that flush to the global counters periodically (e.g., every 64 insertions or on prune check).

### Mechanism

Each thread maintains local `count` and `memoryDelta` fields. When a threshold is reached (or prune is triggered), the thread flushes its locals to the global counters via a single `Interlocked.Add`.

### Expected impact: ~1-2% (same as Candidate 1)
- Reduces Interlocked frequency by ~64x (batch size)
- Slightly more complex than Candidate 1 but keeps metrics more current

### Difficulty: M
- Needs `[ThreadStatic]` fields or `ThreadLocal<T>` with flush logic
- Must handle thread exit (unflushed deltas)
- More complex testing needed

### Risks
- Thread exit without flushing → counter drift until next prune
- More code complexity for marginal benefit over Candidate 1
- `ThreadLocal<T>` finalizer overhead on thread exit

### Files
- `src/Nethermind/Nethermind.Trie/Pruning/TrieStoreDirtyNodesCache.cs`
- `src/Nethermind/Nethermind.Trie/Pruning/TrieStore.cs`

### Benchmark Plan
Same as Candidate 1.

---

## Ranking (by ROI)

| Rank | Candidate | Impact | Difficulty | Risk | Recommendation |
|------|-----------|--------|------------|------|---------------|
| 1 | **C1: Eliminate all Interlocked** | ~1-2% | S | Low | **Recommended** — maximum benefit, minimal complexity |
| 2 | C2: Per-shard non-atomic only | ~0.3-0.5% | S | Very Low | Fallback if C1 is rejected |
| 3 | C3: Thread-local batching | ~1-2% | M | Medium | Over-engineered for this use case |

**Recommendation**: Candidate 1. The counters are provably approximate (SaveOrReplace doesn't update them) and fully reconciled during pruning. Removing all 8 Interlocked ops is safe and maximizes benefit. If the team is uncomfortable with on-demand global computation, Candidate 2 is a safe fallback that still provides some benefit.
