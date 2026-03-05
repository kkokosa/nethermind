# Hypothesis: EVM-1

## Critical Correction

The optimization target description is misleading. It claims removing `.ToArray()` from
PopAddress eliminates a 20-byte heap allocation because "Address already has a
ReadOnlySpan<byte> constructor." However, that span constructor (Address.cs:141-151)
**also calls `.ToArray()` internally**. Removing `.ToArray()` from PopAddress saves
zero allocations — it moves the same allocation into the Address constructor.

The real optimization opportunity is not about `.ToArray()` placement — it's about
avoiding the Address object allocation entirely for short-lived uses, or caching
addresses that appear repeatedly.

---

## Candidate 1 (Recommended): Address Lookup Cache in PopAddress

### Change
Add a small, transaction-scoped `Address` cache to avoid redundant allocations for
repeatedly-accessed addresses. In typical DeFi transactions, the same contract addresses
(DEX routers, token contracts, WETH) appear in multiple CALL/BALANCE/EXTCODEHASH
operations within a single transaction.

**Mechanism**:
- Add a small fixed-size cache (8-16 entries) to the EVM execution context
- Before allocating a new Address in PopAddress, check if the 20-byte span matches
  a cached entry (Vector128 + uint comparison, same as Address.Equals)
- On hit: return cached Address (zero allocation)
- On miss: create new Address, add to cache (evict oldest/LRU)

**Files to modify**:
- `src/Nethermind/Nethermind.Evm/EvmStack.cs:467,477` — add cache lookup before `new Address(...)`
- `src/Nethermind/Nethermind.Evm/VmState.cs` or `VirtualMachine.cs` — host the cache, reset per-tx
- New: small `AddressCache` struct (inline array of 8-16 Address refs)

### Mechanism — Why faster
- Eliminates ~50-80% of Address allocations in typical DeFi transactions where the same
  5-10 addresses appear repeatedly across CALL/BALANCE/EXTCODEHASH opcodes
- Cache lookup is cheap: 20-byte comparison using Vector128+uint (same as Address.Equals)
- Small fixed-size cache has predictable performance, no GC pressure from cache itself

### Expected impact
- **10-30% reduction in Address allocations** from PopAddress (depends on workload)
- **~1-3% improvement on CALL-heavy benchmarks** (StaticCallBenchmarks, ContractCall_200)
- Higher impact on DeFi-heavy blocks, lower on simple transfer blocks

### Difficulty: S-M
- Cache implementation is straightforward (~50 lines)
- Thread safety is automatic (EVM execution is single-threaded per transaction)
- Needs careful cache sizing to avoid slowing down on cache-miss-heavy workloads

### Risks
- Cache miss penalty (comparison + failed lookup) adds ~2-5ns per miss
- If address distribution is highly uniform (many unique addresses), cache provides no benefit
- Address objects in cache must not be mutated (Address.Bytes is mutable byte[] — but
  no code mutates it in practice)
- Must reset cache between transactions

### Benchmark plan
1. Create `EvmAddressPopBenchmark` with `[MemoryDiagnoser]`:
   - Scenario A: CALL to same address 1000 times (cache hit rate ~100%)
   - Scenario B: CALL to 100 unique addresses (cache hit rate ~0%)
   - Scenario C: Mixed DeFi pattern (10 addresses, 100 calls) (cache hit rate ~90%)
2. Add `[MemoryDiagnoser]` to existing `EvmOpcodesBenchmark` for CALL/BALANCE/EXTCODEHASH
3. Run `StaticCallBenchmarks` and `BlockProcessingBenchmark.ContractCall_200` before/after

---

## Candidate 2: Span-Based State Lookups (Avoid Address for Read-Only Opcodes)

### Change
For opcodes that only read state (BALANCE, EXTCODESIZE, EXTCODEHASH), the popped address
is consumed immediately and discarded. Instead of creating an Address object, pass the
raw 20-byte span directly to the state lookup methods.

**Mechanism**:
- Add `PopAddressBytes()` method to EvmStack that returns `ReadOnlySpan<byte>` (no allocation)
- Add overloads to `IWorldState`: `GetBalance(ReadOnlySpan<byte>)`, `GetCodeHash(ReadOnlySpan<byte>)`
- These overloads compute `KeccakCache.Compute(span)` directly for trie lookup
- For gas tracking (AccessTracker), still need Address — defer allocation to AccessTracker
  only when the address is cold (first access)

**Files to modify**:
- `src/Nethermind/Nethermind.Evm/EvmStack.cs` — add `PopAddressBytes()` returning `ReadOnlySpan<byte>`
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.Environment.cs` — BALANCE, EXTCODEHASH
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.CodeCopy.cs` — EXTCODESIZE, EXTCODECOPY
- `src/Nethermind/Nethermind.State/IWorldState.cs` — add span-accepting overloads
- `src/Nethermind/Nethermind.State/WorldState.cs` — implement span overloads
- `src/Nethermind/Nethermind.Evm/StackAccessTracker.cs` — defer Address creation for cold checks

### Mechanism — Why faster
- Eliminates Address allocation entirely for warm-address read-only opcodes
- BALANCE/EXTCODEHASH on warm addresses skip both Address allocation and KeccakCache
  (address path already computed)
- Span from EVM stack is valid for the duration of the instruction execution

### Expected impact
- **Eliminates 100% of Address allocations for warm read-only opcodes**
- **~5-10% reduction** in total PopAddress allocations (read-only opcodes are common
  but CALL dominates in heavy blocks)
- Higher impact in contracts that do many BALANCE/EXTCODEHASH checks (e.g., lending protocols)

### Difficulty: M
- Requires API changes to IWorldState (adding overloads, not changing existing)
- AccessTracker needs conditional Address creation (only for cold addresses)
- ref struct lifetime must be carefully managed

### Risks
- API surface increase in IWorldState
- Span lifetime: must ensure EVM stack bytes are not overwritten during state lookup
  (they shouldn't be — stack is not modified during instruction execution)
- AccessTracker warm/cold check currently takes Address — needs span-based overload
- Tracing: some tracers record Address objects — need to handle tracing path

### Benchmark plan
1. Measure BALANCE/EXTCODEHASH opcode times in `EvmOpcodesBenchmark` with `[MemoryDiagnoser]`
2. Create warm-address-heavy benchmark (many BALANCE checks on same 5 addresses)
3. Compare allocation counts before/after

---

## Candidate 3 (Exploratory): Convert Address to Fixed-Size Struct

### Change
Convert `Address` from `sealed class` to `readonly struct` with inline 20-byte storage,
matching Geth's `[20]byte` and Reth's `FixedBytes<20>`.

### Mechanism — Why faster
- Eliminates all heap allocations for Address
- Value semantics enable stack allocation and embedding in other structs
- Matches Go/Rust performance characteristics

### Expected impact
- **100% elimination of Address heap allocations** across entire codebase
- **Potentially 5-15% improvement** on address-heavy workloads

### Difficulty: L (very large)
- Address is used in **hundreds of files** across the entire codebase
- Nullable semantics change (`Address?` becomes different — nullable value type)
- Collections behavior changes (no more reference equality fast path)
- `Address.Bytes` returns `byte[]` — would need to change to `ReadOnlySpan<byte>`
- Every `== null` check becomes `== default` check
- Risk of boxing in generic collections
- Multi-week effort with high regression risk

### Risks
- Breaking change to public API
- Subtle behavior changes with nullable value types
- Performance could worsen in some paths due to 20-byte copies vs 8-byte pointer copies
- Not recommended as a single PR — would need staged migration

### Benchmark plan
- Not practical to benchmark without full implementation
- Prototype with a single opcode to estimate impact

---

## Ranking by ROI (impact / difficulty)

| Rank | Candidate | Impact | Difficulty | ROI | Recommendation |
|------|-----------|--------|------------|-----|----------------|
| 1 | **Address Cache** | 10-30% alloc reduction | S-M | High | **Implement first** |
| 2 | **Span-Based Lookups** | 5-10% alloc reduction | M | Medium | Implement if cache shows promise |
| 3 | **Address Struct** | 100% alloc elimination | L | Low (risk-adjusted) | Long-term architectural goal |

## Decision

**Recommend Candidate 1 (Address Cache)** as the first implementation. It's low-risk,
isolated to the EVM module, and targets the most common pattern (repeated addresses
in DeFi transactions). If benchmarks show significant improvement, proceed with
Candidate 2 for additional gains on read-only opcodes.

**Note**: The original target description's suggested fix (remove `.ToArray()`) would
produce zero measurable improvement. The research shows this is a deeper architectural
issue where the best short-term win comes from caching, not from moving the allocation
to a different call site.
