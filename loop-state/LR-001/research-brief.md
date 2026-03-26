# Research Brief: TRIE-5

## Target — Interlocked operations per cached node in DirtyNodesCache

**File**: `src/Nethermind/Nethermind.Trie/Pruning/TrieStoreDirtyNodesCache.cs:218-228`

Every node insertion into the dirty node cache incurs **up to 8 Interlocked (full memory barrier) operations**: 4 at the shard level and 4 at the TrieStore level. These counters track node count and memory usage for pruning decisions and metrics.

## Current Implementation

### `IncrementMemory` in `TrieStoreDirtyNodesCache` (lines 218-229)

```csharp
public void IncrementMemory(TrieNode node)
{
    long memoryUsage = node.GetMemorySize(false) + KeyMemoryUsage;
    Interlocked.Increment(ref _count);            // barrier #1
    Interlocked.Add(ref _totalMemory, memoryUsage); // barrier #2
    if (!node.IsPersisted)
    {
        Interlocked.Increment(ref _dirtyCount);          // barrier #3
        Interlocked.Add(ref _totalDirtyMemory, memoryUsage); // barrier #4
    }
    _trieStore.IncrementMemoryUsedByDirtyCache(memoryUsage, node.IsPersisted);
}
```

### `IncrementMemoryUsedByDirtyCache` in `TrieStore` (lines 151-160)

```csharp
public void IncrementMemoryUsedByDirtyCache(long nodeMemoryUsage, bool persisted)
{
    Metrics.CachedNodesCount = Interlocked.Increment(ref _totalCachedNodesCount);  // barrier #5
    Metrics.MemoryUsedByCache = Interlocked.Add(ref _memoryUsedByDirtyCache, nodeMemoryUsage); // barrier #6
    if (!persisted)
    {
        Metrics.DirtyNodesCount = Interlocked.Increment(ref _dirtyNodesCount);     // barrier #7
        Metrics.DirtyMemoryUsedByCache = Interlocked.Add(ref _dirtyMemoryUsedByDirtyCache, nodeMemoryUsage); // barrier #8
    }
}
```

**Per dirty node insertion**: 8 Interlocked operations (4 shard + 4 global)
**Per persisted node insertion**: 4 Interlocked operations (2 shard + 2 global)

### Symmetric `DecrementMemory` at lines 231-242

Same structure — 8 Interlocked operations for dirty node removal.

### Sharding architecture

- 256 shards (configurable via `DirtyNodeShardBit`, default 8 → 2^8 = 256)
- Shard index: `hash.GetHashCode() % 256` (or path-based when tracking past keys)
- Each shard has its own `ConcurrentDictionary` + 4 counter fields
- TrieStore maintains 4 additional global counter fields

## Call Graph

### Hot callers (IncrementMemory)

1. **`FindCachedOrUnknown` → `GetOrAdd` factory** (TrieStoreDirtyNodesCache:165-177)
   - Called during trie **node resolution** (read path)
   - Only triggers when a cache miss adds a new Unknown node
   - Hot: thousands of new node resolutions per block

2. **`SaveOrReplaceInDirtyNodesCache`** (TrieStore:309-329, line 325)
   - Called during trie **commit** (write path)
   - Called for every committed trie node that's new to the cache
   - Hot: proportional to dirty nodes per block (hundreds to thousands)

### Hot callers (DecrementMemory)

3. **`Remove`** (TrieStoreDirtyNodesCache:244-259)
   - Called during `PruneCache` node removal
   - Called during `Delete` (old hash removal)
   - Frequency: proportional to nodes pruned

### Counter consumers (where shard-level counters are READ)

| Consumer | File:Line | Frequency | Purpose |
|----------|-----------|-----------|---------|
| `NodesCount()` | TrieStore.cs:267-274 | Rare (metrics) | Sums `_count` across 256 shards |
| `DirtyNodesCount()` | TrieStore.cs:277-284 | Rare (metrics) | Sums `_dirtyCount` across 256 shards |
| `RecalculateTotalMemoryUsage()` | TrieStore.cs:985-1006 | After pruning | Reads all 4 counters, resets globals |
| `PruneCache()` | DirtyNodesCache.cs:266-285 | During pruning | **Recomputes from scratch**, overwrites counters |

### Counter consumers (where TrieStore-level counters are READ)

| Consumer | Property | Frequency | Purpose |
|----------|----------|-----------|---------|
| `CaptureCurrentState()` | `MemoryUsedByDirtyCache`, `DirtyMemoryUsedByDirtyCache` | Per block (pruning check) | **Drives pruning decisions** |
| `Prune()` | via CaptureCurrentState | Per block | ShouldPruneDirtyNode / ShouldPrunePersistedNode |
| Logging | various | Per commit/prune | Debug/info messages |

### Key insight: shard-level counters are redundant

The shard-level `_count`, `_totalMemory`, `_dirtyCount`, `_totalDirtyMemory` are:
1. Maintained atomically per insertion (**expensive**: 4 Interlocked ops)
2. Read only by `NodesCount()`/`DirtyNodesCount()` (summing 256 shards — **rare**)
3. Read by `RecalculateTotalMemoryUsage()` (which runs **after pruning** to recalibrate)
4. **Completely recomputed from scratch** in `PruneCacheUnlocked()` (lines 287-355) — the Interlocked-maintained values are overwritten

The TrieStore-level global counters (`_memoryUsedByDirtyCache`, etc.) are the ones that actually drive pruning decisions.

## Baseline Benchmark

**None exists.** The BENCHMARK-INVENTORY notes:
- `TrieCacheInsertionBenchmark` is listed as P1 recommendation (for TRIE-5)
- `PatriciaTreeBenchmarks` covers bulk trie ops but not cache insertion throughput
- No benchmark isolates the Interlocked overhead

Closest existing benchmarks:
- `PatriciaTreeBenchmarks` in `Nethermind.Benchmark/Store/` — 25+ methods covering insert/commit/hash/read
- `TreeStoreBenchmark` in `Nethermind.Trie.Benchmark/` — single node commit through TrieStore

A dedicated benchmark must be created to measure cache insertion throughput.

## Prior Art

### TrieNodeCache (flat state cache) — same repo, different approach

`Nethermind.State.Flat/TrieNodeCache.cs` uses a **per-shard non-atomic array** with `Interlocked.Add` only on the per-shard memory counter (1 op), and **no global running total**. Memory is summed on-demand:

```csharp
long currentTotalMemory = 0;
for (int i = 0; i < ShardCount; i++) currentTotalMemory += _shardMemoryUsages[i];
```

This is the pattern to follow: **per-shard accumulators, sum only when needed**.

### Reth / Geth

No direct comparisons found in the codebase. Both Reth and Geth use different trie caching architectures:
- Geth uses a "triedb/pathdb" with journal-based dirty tracking (no per-node atomic counters)
- Reth uses reth-trie with parallel state root computation (no shared mutable counters during hashing)

Neither appears to use per-node Interlocked operations for memory tracking.

## Blast Radius

### What would change

1. **`TrieStoreDirtyNodesCache`**: Remove/modify `_count`, `_dirtyCount`, `_totalMemory`, `_totalDirtyMemory` fields and `IncrementMemory`/`DecrementMemory` methods
2. **`TrieStore`**: Modify `IncrementMemoryUsedByDirtyCache`/`DecreaseMemoryUsedByDirtyCache` to use non-atomic or batched updates
3. **Metrics updates**: Decouple per-node metric writes from insertion path

### What stays the same

- `ConcurrentDictionary` operations (sharded, unchanged)
- Pruning logic (recomputes from scratch)
- Public API (`FindCachedOrUnknown`, `SaveOrReplaceInDirtyNodesCache`)
- Node resolution and commit paths (callers unchanged)

### Consensus safety

**No consensus risk.** These counters are purely for:
1. Memory management (pruning decisions) — approximate values are sufficient
2. Metrics/monitoring — eventual consistency is fine
3. Logging — informational only

The trie data itself (nodes, hashes, paths) is unaffected. Pruning timing may shift by a few nodes, which is harmless — pruning is already non-deterministic (depends on timing, GC, etc.).

### Downstream dependents

- `TrieStore.Prune()` — reads global counters for pruning decisions (tolerant of staleness)
- `TrieStore.RecalculateTotalMemoryUsage()` — recalibrates from shard data (would use ConcurrentDictionary.Count if shard counters removed)
- Metrics consumers (Prometheus/Grafana) — scrape every 10-15s, tolerant of staleness
