# Hypothesis: EVM-1

## Candidate 1 (Recommended): Address interning via AccessedAddresses warm set

- **Change**: In `PopAddress()`, after constructing the span of 20 bytes from the stack, look up the address in the `AccessedAddresses` warm set (already maintained by `StackAccessTracker` for EIP-2929). If found, return the existing `Address` object. Only allocate a new `Address` if the address is cold (first access).
- **Mechanism**: Most address-consuming opcodes in real blocks hit *already-warm* addresses. DeFi contracts repeatedly call the same addresses (WETH, Uniswap router, token contracts). By reusing the `Address` object from the warm set, we eliminate the 20-byte array + Address object allocation on ~80%+ of PopAddress calls. The warm set lookup is already O(1) via HashSet.
- **Expected impact**: 10-25% reduction in PopAddress allocations (conservative). On CALL-heavy blocks, most addresses will be warm after the first access. BALANCE checks especially hit the same addresses repeatedly.
- **Difficulty**: M -- requires threading the `StackAccessTracker` or its address set into `PopAddress()`, which means changing the method signature or adding the tracker reference to `EvmStack`.
- **Risks**:
  - The cache lookup adds overhead (~5-10ns hash + comparison) even on cold path. Net benefit depends on warm hit rate.
  - `EvmStack` is a `ref struct` -- adding a reference to `StackAccessTracker` is possible but changes the struct layout.
  - PopAddress is called from 7 sites; all would need to pass the tracker or have it available on `EvmStack`.
  - The `JournalSet<Address>` uses `Address.EqualityComparer` which does SIMD byte comparison -- fast, but we need a lookup-by-bytes method (currently it accepts `Address`, creating a chicken-and-egg problem: we'd need to construct a temporary Address to look up in the set).
- **Files**: `EvmStack.cs`, `StackAccessTracker.cs`, possibly `JournalSet.cs`
- **Benchmark plan**: Create `EvmAddressPopBenchmark` with `[MemoryDiagnoser]`. Test scenarios: (a) cold addresses (all unique), (b) warm addresses (repeated calls to same 5 addresses), (c) mixed. Compare allocated bytes.

## Candidate 2: Trivial .ToArray() removal (cosmetic, for code clarity)

- **Change**: Remove `.ToArray()` from `PopAddress()` and use `new Address(span)` instead of `new Address(span.ToArray())`. The span constructor already exists at Address.cs:141.
- **Mechanism**: No performance benefit -- the span constructor does `Bytes = bytes.ToArray()` internally. This is purely cosmetic cleanup that removes the redundant double-intent of the code.
- **Expected impact**: 0% -- same allocation, just one fewer copy in the code path. The JIT likely already optimizes this, but at worst this avoids an extra intermediate array.
- **Difficulty**: S -- one-line change in each PopAddress overload.
- **Risks**: None. Functionally identical.
- **Files**: `EvmStack.cs`
- **Benchmark plan**: Run existing opcode benchmarks with `[MemoryDiagnoser]` to confirm zero allocation delta.

## Candidate 3: Make Address a value type (AddressValue struct)

- **Change**: Introduce `AddressValue` as a 20-byte inline struct (similar to `ValueHash256` for `Hash256`). Use it in EVM-internal paths where the address is transient. Keep `Address` class for long-lived storage.
- **Mechanism**: Stack-allocated 20-byte struct eliminates all heap allocation for the 6 transient PopAddress call sites. This is what Reth and Geth do natively (their Address types are value types).
- **Expected impact**: 50-80% reduction in PopAddress allocations (6 of 7 call sites become zero-alloc). ~120 bytes saved per transient address opcode. On blocks with 1000+ address opcodes, this saves ~120KB of GC pressure per block.
- **Difficulty**: L -- requires:
  1. New `AddressValue` readonly struct with 20-byte inline storage
  2. Two PopAddress variants: one returning `Address` (for CALL), one returning `AddressValue` (for transient uses)
  3. `IWorldState` methods (GetBalance, GetCodeHash, etc.) need overloads accepting `AddressValue`
  4. All `IWorldState` implementations need corresponding changes
  5. `StackAccessTracker.IsCold()` and `WarmUp()` need `AddressValue` overloads
- **Risks**:
  - Very wide blast radius across State module
  - Must maintain correctness of all state lookups with new type
  - AddressValue-to-Address conversion still needs allocation when storing long-term
  - Substantial API surface change
- **Files**: `Address.cs` (new struct), `EvmStack.cs`, `IWorldState.cs`, `WorldState.cs`, `StateProvider.cs`, `StackAccessTracker.cs`, `EthereumGasPolicy.cs`, all opcode instruction files
- **Benchmark plan**: Full block processing benchmark (BlockProcessingBenchmark.Transfers_200, ContractCall_200) with `[MemoryDiagnoser]` before/after.

## Ranking (by ROI)

| Rank | Candidate | Impact | Difficulty | Net ROI |
|------|-----------|--------|------------|---------|
| 1 | Address interning via warm set | 10-25% alloc reduction | M | **Best** -- moderate change, meaningful savings on warm-heavy workloads |
| 2 | AddressValue struct | 50-80% alloc reduction | L | High impact but very wide blast radius |
| 3 | Trivial .ToArray() removal | 0% | S | Cosmetic only -- not worth a PR on its own |

## Honest Assessment

The original target description ("S difficulty, just remove .ToArray()") is **misleading**. The `.ToArray()` in PopAddress is not the real problem -- `Address` being a reference type with a `byte[]` field is. Simply removing `.ToArray()` moves the allocation into the Address constructor with zero net benefit.

Meaningful optimization requires either:
- **Interning** (Candidate 1): moderate change, moderate benefit
- **Value type** (Candidate 3): large change, large benefit but very wide blast radius

If the warm hit rate in real blocks is >70% (likely for DeFi blocks), Candidate 1 provides the best ROI. Candidate 3 is the architecturally correct solution (matching Reth/Geth) but is a multi-PR endeavor.

**Recommendation**: Proceed with Candidate 1 (interning), but first create the benchmark to measure the warm address hit rate on realistic workloads. If the hit rate is low (<50%), Candidate 1 may not be worth it, and we should escalate to Candidate 3 as a larger project.
