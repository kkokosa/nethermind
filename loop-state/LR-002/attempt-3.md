# Attempt 3: EVM-2

## What was tried
Reverted the StorageValuePool approach from attempts 1-2 (which added complexity
for only 7B/op saving). Kept the `ReadOnlySpan<byte>` overloads on `IWorldState`
as a clean API, but simplified them to call `.ToArray()` internally without any
pooling. This tests whether moving the allocation site from the EVM to the storage
provider has any timing impact.

Changes:
- Deleted `StorageValuePool.cs` (custom thread-local pool)
- Removed `SetPooled()`, `_pooledValues`, `ReturnPooledValues()` from
  `PartialStorageProviderBase`
- Simplified `WorldState.Set(ReadOnlySpan<byte>)` to call `.ToArray()` + delegate
- Removed pooling infrastructure from `PersistentStorageProvider.Reset()` and
  `TransientStorageProvider.Reset()`

## Results
| Benchmark | Baseline | Candidate | Delta |
|-----------|----------|-----------|-------|
| SSTORE | 4483ns / 379B | 4314ns / 379B | -3.8% time (noise), 0% alloc |
| TSTORE | 489ns / 57B | 392ns / 57B | -19.8% time (noise), 0% alloc |

Allocation is identical because the `.ToArray()` still happens — just in a
different location (inside the storage provider instead of at the EVM call site).

## What worked / didn't
- **Didn't work**: The fundamental premise of the hypothesis was wrong.
  `bytes.ToArray()` in SSTORE/TSTORE contributes only 5-8% of total allocation
  (20-32B out of 379B). Whether pooled, moved, or left in place, the impact
  is negligible.
- **Worked**: The span overloads are architecturally cleaner (the storage
  provider owns allocation responsibility). But this is a code quality
  improvement, not a performance improvement.

## Analysis across all 3 attempts
All three attempts targeted the same `.ToArray()` allocation:
- Attempt 1: Custom pool → 7B/op saved (2%)
- Attempt 2: Refined pool → 7B/op saved (2%)
- Attempt 3: No pool, just API cleanup → 0B saved

The optimization target is too small to move the needle. The real allocation
hotspots in SSTORE are:
1. `LoadFromTree()` → trie read allocates byte[] (~60-80B)
2. Dictionary operations on `_intraBlockCache` and `_originalValues`
3. `StackList<int>.Rent()` on cache miss
4. `Change` struct storage in `List<Change>`

## Suggestion for next attempt
**Do not retry this target.** The `.ToArray()` allocation in SSTORE/TSTORE
is not a meaningful optimization opportunity. If EVM storage performance is
still a priority, consider:

1. **Value-type storage representation**: Replace `byte[]` with a fixed-size
   value type (like Geth's `common.Hash`) throughout the change tracking
   pipeline. This would eliminate ALL heap allocations for storage values,
   not just the EVM-side copy. However, this is a large refactor touching
   `Change`, `StorageChangeTrace`, `_originalValues`, and the trie interface.

2. **Reduce dictionary lookups**: Each SSTORE does 3-4 dictionary lookups
   on `_intraBlockCache` (hash + compare per lookup). A single-entry cache
   for the last-accessed StorageCell could eliminate 1-2 lookups per SSTORE.

3. **Target different EVM operations**: Focus on opcodes with higher
   per-operation overhead or higher frequency in real workloads.
