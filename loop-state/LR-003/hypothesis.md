# Hypothesis: EVM-3

## Candidate 1 (Recommended): Use ArrayPool for return data copy

### Change
Replace `returnData.ToArray()` with `ArrayPool<byte>.Shared.Rent()` + copy, and return the
rented array to the pool after it's consumed.

**Files to modify:**
- `Instructions/EvmInstructions.Call.cs:362` — RETURN opcode
- `Instructions/EvmInstructions.ControlFlow.cs:189` — REVERT opcode
- `VirtualMachine.cs:338-364` — `HandleRegularReturn` (return rented array after use)
- `VirtualMachine.cs:298-302` — `HandleRevert` (return rented array after use)
- `VirtualMachine.cs:240-248` — `PrepareTopLevelSubstate` (return rented array)

**Approach:**
1. Create a small helper struct `PooledReturnData` that wraps a rented `byte[]` + actual length
2. Store it in `ReturnData` instead of a raw `byte[]`
3. In the dispatch code (VirtualMachine.cs:1306), pattern-match on `PooledReturnData`
4. After `ReturnDataBuffer` is set from the pooled array, return it to the pool
5. At top-level, `.ToArray()` only once for `TransactionSubstate`

### Mechanism
Eliminates heap allocation per RETURN/REVERT by reusing pooled arrays. `ArrayPool<byte>.Shared`
is thread-local for small sizes and lock-free, so rental cost is near-zero. The copy from
EVM memory to rented array still occurs (can't avoid — source memory is returned to pool on
frame dispose), but avoids GC pressure from per-frame `byte[]` allocations.

### Expected impact
- **15-25% reduction in per-call-frame allocations** for return data
- For nested call transactions (DeFi composability): measurable reduction in GC pause time
- Net throughput improvement: **5-10%** on call-heavy blocks (e.g., Uniswap swaps)
- Zero-length returns (STOP, empty RETURN) already avoid allocation — impact is on non-empty returns

### Difficulty: M
- Touches 5 files but changes are mechanical
- Must carefully track pooled array lifetime (rent → use → return)
- Pattern match on new type in hot loop — needs benchmark to confirm no regression

### Risks
1. **Use-after-return bug**: If the pooled array is returned to pool before parent fully
   consumes the data, corruption occurs. Mitigated by explicit lifetime in frame transition.
2. **ArrayPool fragmentation**: For large return data (>1MB), ArrayPool may not reuse well.
   Rare in practice — most return data is 32-256 bytes.
3. **Polymorphic dispatch regression**: Adding `PooledReturnData` as a third pattern-match
   case could slow the hot loop. Must benchmark.

### Benchmark plan
1. Create `NestedCallBenchmark` with contracts returning 32B/256B data at depth 10/50/100
2. Run with [MemoryDiagnoser] before and after
3. Compare: allocated bytes, Gen0 collections, mean time
4. Also run `BlockProcessingBenchmark.ContractCall_200` for regression check

---

## Candidate 2: Defer copy — keep ReadOnlyMemory until frame dispose

### Change
Instead of copying return data immediately in the RETURN/REVERT opcode, store the
`ReadOnlyMemory<byte>` directly and defer the copy until `VmState.Dispose()` is about
to return the memory to the pool.

**Files to modify:**
- `VirtualMachine.cs:111` — add `ReadOnlyMemory<byte> ReturnDataMemory` field
- `Instructions/EvmInstructions.Call.cs:362` — store memory directly
- `Instructions/EvmInstructions.ControlFlow.cs:189` — store memory directly
- `VirtualMachine.cs:1306-1319` — read from `ReturnDataMemory` instead of casting `ReturnData`
- `VmState.cs:248-260` — copy data before pool return if still referenced

### Mechanism
Avoids the copy entirely when the return data is immediately overwritten by the parent
(common in deep call chains where intermediate return data is discarded). Only copies when
the data is actually consumed by RETURNDATACOPY or preserved for tracing.

### Expected impact
- **Best case: eliminates copy entirely** for discarded return data
- **Worst case: same as current** (copy deferred but still happens)
- Estimated **10-20%** improvement on deeply nested call chains

### Difficulty: L
- Requires separating the control-flow signaling from data signaling in `ReturnData`
- The `object ReturnData` polymorphism must be restructured
- Complex lifetime tracking: must know if memory is still valid when parent reads it
- Risk of subtle bugs if frame dispose order changes

### Risks
1. **Lifetime complexity**: The `ReadOnlyMemory<byte>` points into child's pooled memory.
   If child is disposed before parent reads, data is corrupted. Current code avoids this
   because `.ToArray()` copies immediately. Removing the copy requires careful ordering.
2. **ReturnData polymorphism**: Splitting the `object` field into separate typed fields
   changes hot-loop dispatch. Must profile carefully.
3. **Higher blast radius**: Touches frame lifecycle, control flow, and memory management.

### Benchmark plan
Same as Candidate 1, plus:
- Add benchmark with calls that discard return data (CALL without RETURNDATACOPY)
- Measure improvement differential between "consumed" vs "discarded" scenarios

---

## Candidate 3: Avoid allocation for empty/small returns via cached arrays

### Change
Cache commonly-sized return data arrays (0, 32, 64 bytes of zeros) and use them directly
instead of allocating.

**Files to modify:**
- `Instructions/EvmInstructions.Call.cs:362` — check for cached sizes
- `Instructions/EvmInstructions.ControlFlow.cs:189` — check for cached sizes

### Mechanism
Many contract returns are exactly 32 bytes (single uint256/bool) or 64 bytes (two values).
Pre-allocate static arrays for common zero-padded return patterns. Falls back to `.ToArray()`
for non-matching sizes.

### Expected impact
- **5-10%** reduction in return data allocations
- Limited to zero-value returns (common for bool returns, less common for data returns)
- Low ceiling — most return data contains non-zero content

### Difficulty: S
- 2 files, ~10 lines changed
- No API changes, no lifetime management
- Minimal risk

### Risks
1. **Mutation safety**: Cached arrays must not be mutated. `ReturnDataBuffer` is
   `ReadOnlyMemory<byte>` so reads are safe, but if any code path casts to `byte[]`
   and writes, corruption occurs.
2. **Limited coverage**: Only helps when return data matches cached patterns.

### Benchmark plan
- Profile real-world blocks to determine % of returns matching cached sizes
- If >30% match, proceed. Otherwise, skip.

---

## Ranking (by ROI)

| Rank | Candidate | Impact | Difficulty | ROI |
|------|-----------|--------|------------|-----|
| 1 | **ArrayPool rental** | 5-10% on call-heavy blocks | M | **Best** — mechanical change, clear benefit |
| 2 | **Deferred copy** | 10-20% on nested calls | L | High potential but high risk |
| 3 | **Cached small arrays** | 5-10% (limited coverage) | S | Low risk but limited upside |

**Recommendation**: Start with Candidate 1 (ArrayPool). It's the safest path to measurable
improvement. If profiling shows that most return data is discarded by parents, consider
Candidate 2 as a follow-up.
