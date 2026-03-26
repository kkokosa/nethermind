# Hypothesis: TRIE-5

## Candidate 1 (Recommended): Eliminate shard-level counters entirely

### Change

Remove the 4 shard-level fields (`_count`, `_dirtyCount`, `_totalMemory`, `_totalDirtyMemory`) from `TrieStoreDirtyNodesCache`. Keep only the TrieStore-level global counters.

**Files to modify:**
- `src/Nethermind/Nethermind.Trie/Pruning/TrieStoreDirtyNodesCache.cs`
  - Remove fields: `_count`, `_dirtyCount`, `_totalMemory`, `_totalDirtyMemory` (lines 23-26)
  - Remove properties: `Count`, `DirtyCount`, `TotalMemory`, `TotalDirtyMemory` (lines 32-35)
  - Simplify `IncrementMemory()` (line 218): remove 4 Interlocked ops, keep only `_trieStore.IncrementMemoryUsedByDirtyCache()` call
  - Simplify `DecrementMemory()` (line 231): same
  - Update `PruneCache()` (line 266): remove direct counter assignments (lines 281-284), call `_trieStore.RecalculateTotalMemoryUsage()` after pruning instead
  - `PruneCacheUnlocked()`: remove `totalNode/dirtyNode` tracking, keep `totalMemory/dirtyMemory` as local return values for `RecalculateTotalMemoryUsage`

- `src/Nethermind/Nethermind.Trie/Pruning/TrieStore.cs`
  - `NodesCount()` (line 267): return `_totalCachedNodesCount` directly instead of summing shards
  - `DirtyNodesCount()` (line 277): return `_dirtyNodesCount` directly instead of summing shards
  - `RecalculateTotalMemoryUsage()` (line 985): derive counts from global counters or iterate ConcurrentDictionary

### Mechanism

Each shard-level Interlocked operation is a **full memory barrier** (`lock xadd` on x86). A dirty node insertion currently executes 4 of these at the shard level — they exist solely to maintain shard-local counters that are:
1. Only read for summing across 256 shards (rare)
2. Recomputed from scratch during pruning anyway

Eliminating them removes **4 memory barriers per node insertion/removal**. The TrieStore-level global counters (4 remaining Interlocked ops) are sufficient for all consumers.

### Expected impact

**~5-10% improvement in cache insertion throughput** (estimated):
- Removes 4 of 8 Interlocked operations per dirty node (50% reduction in atomic ops)
- Each `lock xadd` costs ~15-30ns on modern x86 under low contention, ~50-200ns under contention
- At 4 ops × thousands of nodes per block, savings of 60-120μs per block in the best case
- Real impact depends on contention level (256 shards reduce contention significantly)
- The remaining 4 TrieStore-level operations still have cross-shard contention

Confidence: **0.6** — The sharding already reduces contention substantially, so the marginal improvement from removing shard-level ops may be modest. The true bottleneck may be the TrieStore-level globals.

### Difficulty: S

Isolated change, no API impact, no consensus risk. Straightforward removal of redundant bookkeeping.

### Risks

1. **Stale `NodesCount()`/`DirtyNodesCount()`**: These would return the global running totals instead of summing shards. Values could drift slightly from reality between `RecalculateTotalMemoryUsage()` calls. Risk: **low** — only used for metrics/logging.
2. **Pruning accuracy**: `PruneCache()` currently writes recomputed values back to shard counters. Without shard counters, `RecalculateTotalMemoryUsage()` would need to rewrite global counters from the `PruneCacheUnlocked()` results. Risk: **none** if implemented correctly.

### Benchmark plan

Create `TrieCacheInsertionBenchmark` in `Nethermind.Trie.Benchmark/`:
- Pre-build a set of N TrieNodes (1000, 10000)
- Measure throughput of `SaveOrReplaceInDirtyNodesCache` in a loop
- Use `[MemoryDiagnoser]` to confirm no allocation regression
- Run single-threaded and multi-threaded (4, 8 threads) variants to measure contention impact
- Compare baseline (current) vs optimized (shard counters removed)

---

## Candidate 2: Replace TrieStore-level Interlocked with per-shard accumulators

### Change

Instead of maintaining 4 global atomic counters that all shards contend on, store per-shard non-atomic accumulators and sum them on demand (following the `TrieNodeCache` pattern).

**Files to modify:**
- `src/Nethermind/Nethermind.Trie/Pruning/TrieStoreDirtyNodesCache.cs`
  - Convert `_count`, `_totalMemory`, etc. from Interlocked to plain `long` (no atomic ops)
  - Remove call to `_trieStore.IncrementMemoryUsedByDirtyCache()`

- `src/Nethermind/Nethermind.Trie/Pruning/TrieStore.cs`
  - Remove `IncrementMemoryUsedByDirtyCache` / `DecreaseMemoryUsedByDirtyCache` methods
  - `MemoryUsedByDirtyCache` getter: sum `_dirtyNodes[i].TotalMemory` across 256 shards
  - `CaptureCurrentState()`: compute totals by summing shards on demand
  - Update `Metrics.*` writes to happen only in `CaptureCurrentState()` or on a timer

### Mechanism

Eliminates **all 8 Interlocked operations** per node. Per-shard counters use plain additions (safe because ConcurrentDictionary factory delegates are serialized per-bucket, and cross-shard contention is impossible by definition).

The summing overhead (256 additions) is paid only when `CaptureCurrentState()` is called — once per block for pruning checks.

### Expected impact

**~10-20% improvement in cache insertion throughput** (estimated):
- Removes all 8 memory barriers per node insertion
- The summing cost (256 long additions = ~100ns) is negligible at per-block frequency
- Best-case savings: 8 × 20ns × 5000 nodes = 800μs per block

Confidence: **0.4** — Higher theoretical impact but riskier. The ConcurrentDictionary's internal locks may still serialize writes within a shard bucket, making the Interlocked overhead less significant than expected.

### Difficulty: M

Requires careful analysis of thread safety for shard-level writes. The `ConcurrentDictionary.GetOrAdd` with factory can execute the factory concurrently for different keys in the same bucket — so plain `+=` on shard counters could race. Would need `Volatile.Write` or accept minor inaccuracy.

### Risks

1. **Race conditions on shard counters**: Two concurrent insertions in the same shard could race on `_totalMemory += ...`. With 256 shards this is rare but possible during parallel storage commits. Lost increments would cause pruning to underestimate memory usage, potentially delaying pruning.
2. **Stale pruning decisions**: `CaptureCurrentState()` would see values from the last sum, which could be stale by up to one block's worth of insertions. This is probably acceptable.
3. **Metric staleness**: Prometheus metrics would only update at pruning-check frequency rather than per-node.

### Benchmark plan

Same as Candidate 1, plus:
- Add a contention benchmark: N threads inserting into overlapping shards
- Measure pruning trigger latency (time from exceeding threshold to pruning start)

---

## Candidate 3: Decouple Metrics writes from hot path

### Change

Move `Metrics.CachedNodesCount`, `Metrics.MemoryUsedByCache`, etc. writes out of the per-node insertion path. Update them only during `CaptureCurrentState()` or on a periodic timer.

**Files to modify:**
- `src/Nethermind/Nethermind.Trie/Pruning/TrieStore.cs`
  - `IncrementMemoryUsedByDirtyCache()` (line 151): Remove `Metrics.*` assignment from each Interlocked call
  - `CaptureCurrentState()` (line 556): Add `Metrics.*` updates here
  - `RecalculateTotalMemoryUsage()` (line 985): Already updates Metrics, keep as-is

### Mechanism

Each `Metrics.CachedNodesCount = Interlocked.Increment(...)` does two things: (a) atomic increment, (b) write to a static field. The static field write causes a **cache-line bounce** across all cores that read that field (monitoring threads).

By removing the Metrics write from the hot path, the Interlocked instruction's result is discarded immediately, avoiding the additional cache-line traffic.

### Expected impact

**~2-5% improvement** (estimated). The Interlocked operation itself is the dominant cost; the Metrics write is a secondary cache-line effect.

Confidence: **0.7** — Small but very safe change. Can be combined with Candidate 1 or 2.

### Difficulty: S

Trivial code change. Metric staleness is the only consideration.

### Risks

1. **Metric staleness**: Metrics would update per-block instead of per-node. Prometheus typically scrapes every 10-15s, so this is invisible to monitoring.

### Benchmark plan

Part of the same `TrieCacheInsertionBenchmark`. Measure as a standalone delta or combined with Candidate 1.

---

## Recommendation

**Implement Candidate 1 + Candidate 3 together** (combined difficulty: S):

1. Remove shard-level counters (Candidate 1): -4 Interlocked ops per node
2. Decouple Metrics writes (Candidate 3): reduce cache-line traffic

This yields 50% reduction in atomic operations with minimal risk. Candidate 2 offers more but with higher complexity and race condition risks.

**Expected combined impact: ~5-15% improvement in trie cache insertion throughput**, depending on contention levels. At block processing scale, this could translate to ~0.5-2% reduction in overall commit time for state-heavy blocks.
