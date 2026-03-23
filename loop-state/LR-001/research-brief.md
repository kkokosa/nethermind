# Research Brief: TRIE-5

## Target — Interlocked operations per cached node in DirtyNodesCache

**File**: `src/Nethermind/Nethermind.Trie/Pruning/TrieStoreDirtyNodesCache.cs:218-229`
**Also**: `src/Nethermind/Nethermind.Trie/Pruning/TrieStore.cs:151-170`

Every new node inserted into the dirty cache incurs 4–8 `Interlocked` operations (full memory barriers), spread across two levels of redundant counters.

---

## Current Implementation

### IncrementMemory (TrieStoreDirtyNodesCache.cs:218-229)

Called when a new `Unknown` node is created in the cache via `FindCachedOrUnknown`.

```csharp
public void IncrementMemory(TrieNode node)
{
    long memoryUsage = node.GetMemorySize(false) + KeyMemoryUsage;
    Interlocked.Increment(ref _count);           // shard counter #1
    Interlocked.Add(ref _totalMemory, memoryUsage); // shard counter #2
    if (!node.IsPersisted)
    {
        Interlocked.Increment(ref _dirtyCount);        // shard counter #3
        Interlocked.Add(ref _totalDirtyMemory, memoryUsage); // shard counter #4
    }
    _trieStore.IncrementMemoryUsedByDirtyCache(memoryUsage, node.IsPersisted);
}
```

### IncrementMemoryUsedByDirtyCache (TrieStore.cs:151-160)

Called from above. Updates **global** counters shared across all 256 shards:

```csharp
public void IncrementMemoryUsedByDirtyCache(long nodeMemoryUsage, bool persisted)
{
    Metrics.CachedNodesCount = Interlocked.Increment(ref _totalCachedNodesCount);  // global #1
    Metrics.MemoryUsedByCache = Interlocked.Add(ref _memoryUsedByDirtyCache, nodeMemoryUsage); // global #2
    if (!persisted)
    {
        Metrics.DirtyNodesCount = Interlocked.Increment(ref _dirtyNodesCount);     // global #3
        Metrics.DirtyMemoryUsedByCache = Interlocked.Add(ref _dirtyMemoryUsedByDirtyCache, nodeMemoryUsage); // global #4
    }
}
```

**Total per dirty node**: 8 Interlocked ops (4 shard + 4 global).
**Total per persisted node**: 4 Interlocked ops (2 shard + 2 global).

### DecrementMemory (TrieStoreDirtyNodesCache.cs:231-242)

Mirror of IncrementMemory, called on cache removal via `Remove()`. Same Interlocked pattern.

---

## Call Graph

### Hot callers (block processing path)

```
PatriciaTree.Get/Set (trie traversal)
  └─ TrieNode.ResolveChild()
       └─ ITrieNodeResolver.FindCachedOrUnknown(address, path, keccak)
            └─ TrieStore.FindCachedOrUnknown()  [TrieStore.cs:532]
                 └─ DirtyNodesFindCachedOrUnknown(key)  [TrieStore.cs:296]
                      └─ shard.FindCachedOrUnknown(key)  [DirtyNodesCache.cs:71]
                           └─ GetOrAdd(key, cache)  [DirtyNodesCache.cs:165]
                                └─ ** IncrementMemory(node) **  [only on cache miss]
```

- Called thousands of times per block (every NEW trie node accessed)
- After first access, subsequent lookups are cache hits (no IncrementMemory)

### Cold callers

- `Remove()` via `PruneCache()` — calls `DecrementMemory`, but pruning itself recalculates counters from scratch, making the per-decrement updates redundant
- `Clear()` — uses `Interlocked.Exchange(ref _count, 0)` — infrequent

### NOT calling IncrementMemory (important!)

- `SaveOrReplaceInDirtyNodesCache` (TrieStore.cs:309-327) — uses `AddOrUpdate` directly, **does NOT call IncrementMemory**
- This means committed nodes are added to the dictionary without updating counters
- Counters are already approximate between prune cycles

---

## Key Architectural Facts

### 1. Counter redundancy
Per-shard counters (`_count`, `_totalMemory`, `_dirtyCount`, `_totalDirtyMemory`) and global TrieStore counters (`_totalCachedNodesCount`, `_memoryUsedByDirtyCache`, `_dirtyNodesCount`, `_dirtyMemoryUsedByDirtyCache`) track the same information at different aggregation levels.

### 2. Full recomputation during pruning
- `PruneCache()` (line 277-284): Iterates ALL nodes in the shard dictionary, computes exact counts, and **directly assigns** per-shard counters (no Interlocked).
- `RecalculateTotalMemoryUsage()` (line 985-1006): Sums per-shard counters into global counters via **direct assignment** (no Interlocked).
- Both called after every prune cycle.

### 3. Counters already approximate
`SaveOrReplaceInDirtyNodesCache` adds/updates cache entries without updating any counters. The counters only track insertions via `FindCachedOrUnknown` (cache misses), not commit-path insertions. Drift is corrected at prune time.

### 4. Pruning accuracy requirements
- `ShouldPruneDirtyNode(state)` checks `state.DirtyCacheMemory >= dirtyMemoryLimit` (MemoryLimit.cs:12)
- `ShouldPrunePersistedNode(state)` checks `state.PersistedCacheMemory >= persistedMemoryLimit` (PersistedMemoryLimit.cs:15)
- These are **threshold comparisons** — small inaccuracies (off by a few KB) are harmless
- The prune loop iterates until the condition is no longer met, self-correcting

### 5. Sharding model
- 256 shards (configurable via `DirtyNodeShardBit`, default 8 → 1<<8=256)
- Shard selection: hash-based (TrieStore.cs:265, `GetNodeShardIdx`)
- Each shard has its own `ConcurrentDictionary` with internal concurrency level `min(ProcessorCount*4, 32)`
- Per-shard Interlocked contention is low (distributed by hash)
- **Global counter contention is HIGH** — all 256 shards compete on 4 shared counters

---

## Baseline Benchmark

**None exists** for DirtyNodesCache insertion throughput.

Existing benchmarks that indirectly exercise the path:
- `PatriciaTreeBenchmarks` (`Nethermind.Benchmark/Store/PatriciaTreeBenchmarks.cs`) — uses TrieStore, hits dirty cache, but doesn't isolate insertion overhead
- `TreeStoreBenchmark` (`Nethermind.Trie.Benchmark/TreeCommitterBenchmark.cs`) — commits one node only
- `BlockProcessingBenchmark` — full pipeline, dirty cache overhead buried in noise

**A dedicated benchmark must be created** to isolate the Interlocked overhead.

---

## Prior Art

### Geth (Go-Ethereum)
Geth's pathdb trie cache (`triedb/pathdb/database.go`) tracks memory using a simple `atomic.Int64` for buffer size. It does NOT maintain separate per-shard counters — just one global atomic counter. Their design is simpler: single atomic per operation, not 4-8.

### Reth (Rust Ethereum)
Reth's trie implementation (`crates/trie/`) uses a different architecture — it relies on MDBX's built-in memory management rather than a custom in-memory cache with manual memory tracking. No per-node atomic counters.

### Key takeaway
Both competing implementations use simpler memory tracking. Nethermind's dual-level (per-shard + global) atomics is unique and over-engineered for counters that are recomputed from scratch during every prune cycle.

---

## Blast Radius

### What changes if we modify the counters

1. **No interface changes** — `IncrementMemory`/`DecrementMemory` are `internal`/`private`
2. **No API changes** — public properties `Count`, `TotalMemory`, etc. remain
3. **Pruning decisions** — could see slightly delayed/early trigger (< 1 node's worth)
4. **Metrics reporting** — Prometheus metrics may update less frequently
5. **No consensus impact** — these are monitoring counters, not part of state computation

### Downstream dependencies
- `TrieStore.Prune()` — reads global counters for threshold decisions
- `TrieStore.RecalculateTotalMemoryUsage()` — reads per-shard counters, writes global
- `TrieStore.CaptureCurrentState()` — reads global counters
- `Metrics.*` static fields — read by monitoring/Prometheus
- Test: `TreeStoreTests.cs:869` — checks `ExpectedPerNodeKeyMemorySize`

### Risk assessment: LOW
- Counters are already approximate (SaveOrReplace path doesn't update them)
- Full reconciliation happens every prune cycle
- Pruning is threshold-based and self-correcting
- No consensus-critical code path depends on exact counter values
