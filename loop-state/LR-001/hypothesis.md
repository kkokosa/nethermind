# Hypothesis: EVM-1

## Critical Finding

**The target as described is a no-op.** Removing `.ToArray()` from `PopAddress()` does not
eliminate the allocation — it moves it into the `Address(ReadOnlySpan<byte>)` constructor,
which calls `.ToArray()` at `Address.cs:150`. The net allocation count is identical.

The real optimization requires a different approach entirely.

---

## Candidate 1 (Recommended): Address Interning for Warm Addresses

### Change
Add a per-transaction address cache to `PopAddress()` that reuses `Address` instances for
addresses already seen. Since EIP-2929 (Berlin), most accessed addresses are "warm" — the
same addresses are touched repeatedly within a transaction and across transactions in a block.

**Mechanism**: Before allocating a new `Address`, compute a fast hash of the 20 stack bytes
and look up in a small open-addressed hash table. If found, return the cached `Address`.
If not found, allocate normally and insert into cache.

**Implementation sketch**:
```csharp
// New: AddressCache — small open-addressing table, per VmState or per-transaction
// Key: first 8 bytes of address (fast hash), Value: Address reference
// Size: 64 or 128 entries (covers typical DeFi tx address working set)

public Address? PopAddress()
{
    if (Head-- == 0) return null;
    ReadOnlySpan<byte> bytes = _bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize);
    // Fast path: check cache
    if (_addressCache.TryGet(bytes, out Address cached))
        return cached;
    // Slow path: allocate and cache
    Address addr = new Address(bytes.ToArray());
    _addressCache.Add(bytes, addr);
    return addr;
}
```

### Why faster
- **Warm addresses (common case)**: Zero allocation — reuses existing Address object
- A typical DeFi swap tx calls the same router/pool/token contracts repeatedly (5-15 CALLs to ~3-5 unique addresses)
- After first access, every subsequent PopAddress for the same address avoids:
  - 20-byte `byte[]` allocation (~44 bytes with array overhead)
  - `Address` object allocation (~40 bytes)
  - Total savings: ~84 bytes per repeated address pop
- Cache lookup cost: ~5ns (hash + 1-2 comparisons) vs allocation cost: ~15-30ns + GC pressure

### Expected impact
- **Allocation reduction**: 50-70% fewer Address allocations in typical blocks
  - DeFi blocks: highest savings (same contracts called hundreds of times)
  - Simple transfer blocks: lower savings (each address used once)
- **Throughput improvement**: Estimated 2-5% on CALL-heavy benchmarks due to reduced GC pressure
- **Overall block processing**: <1% (PopAddress is one of many allocation sites)

### Difficulty: M
- Need to design cache data structure (open-addressed hash table for span keys)
- Need to decide cache lifecycle (per-transaction vs per-block vs per-VmState)
- EvmStack is a ref struct — cache reference must be threaded through
- ~100-150 lines of new code

### Risks
- Cache lookup overhead for cold addresses (first access pays ~5ns extra)
- Cache pollution: if cache is too small, thrashing negates benefit
- Thread safety: EvmStack is per-execution-thread, so no contention — but cache must be properly scoped
- Correctness: Address is immutable and equality-by-value, so caching is safe

### Files
- `Nethermind.Evm/EvmStack.cs` — add cache lookup to PopAddress
- `Nethermind.Evm/AddressCache.cs` — new small cache data structure (or inline in EvmStack)
- `Nethermind.Evm/VmState.cs` — potentially hold cache reference per call stack

### Benchmark plan
1. Create `EvmAddressPopBenchmark` with `[MemoryDiagnoser]`:
   - Measure PopAddress/PushAddress cycle (baseline)
   - Measure with repeated addresses (cache hit case)
   - Measure with unique addresses (cache miss case)
2. Run `EvmOpcodesBenchmark` with `[MemoryDiagnoser]` for CALL/BALANCE/STATICCALL
3. Run `BlockProcessingBenchmark` (ContractCall_200, MixedBlock) to measure end-to-end impact

---

## Candidate 2: Span-Based State Lookup Overloads (Bypass Address Allocation Entirely)

### Change
For opcodes that only need a quick state lookup (BALANCE, EXTCODEHASH, EXTCODESIZE),
add span-based overloads to the state APIs that accept `ReadOnlySpan<byte>` instead of
`Address`. This completely avoids Address object creation for read-only operations.

**Key insight**: BALANCE only needs `GetBalance(address)` — if StateProvider could look up
by raw bytes, no Address allocation is needed at all.

### Why faster
- Eliminates both the `byte[]` and `Address` allocations entirely for supported opcodes
- BALANCE, EXTCODEHASH, EXTCODESIZE are high-frequency read-only opcodes
- StateProvider's internal cache (`_intraTxCache`, `_blockChanges`) uses `AddressAsKey`
  which wraps `Address` — but `Dictionary<>.GetAlternateLookup<>()` in .NET 9+ could
  enable span-based lookup without creating the key

### Expected impact
- **Allocation reduction**: 100% for BALANCE, EXTCODEHASH, EXTCODESIZE
- **Throughput improvement**: Estimated 3-8% on these specific opcodes
- However, CALL still needs an Address object (for frame creation, warm set storage)

### Difficulty: L
- Requires adding span-accepting overloads throughout:
  - `IWorldState.GetBalance(ReadOnlySpan<byte>)`
  - `StateProvider.GetThroughCache(ReadOnlySpan<byte>)`
  - `ConsumeAccountAccessGas(... ReadOnlySpan<byte>)`
  - `StackAccessTracker.WarmUp(ReadOnlySpan<byte>)` + `IsCold(ReadOnlySpan<byte>)`
- Requires .NET 9+ `AlternateLookup` for dictionary span lookups
- ~300-500 lines across 5+ files

### Risks
- Large API surface change across module boundaries (Evm → State → Core)
- `StackAccessTracker.WarmUp` needs to store Address for journal restore — can't use span only
- `GetAlternateLookup` may not be available for all collection types used
- Maintaining two code paths (span + Address) increases complexity

### Files
- `Nethermind.Evm/EvmStack.cs` — add `PopAddressBytes()` returning span
- `Nethermind.Evm/GasPolicy/EthereumGasPolicy.cs` — span-based access gas
- `Nethermind.Evm/StackAccessTracker.cs` — span-based IsCold/WarmUp
- `Nethermind.State/StateProvider.cs` — span-based GetThroughCache
- `Nethermind.State/WorldState.cs` — span-based forwarding
- `Nethermind.Evm/Instructions/EvmInstructions.Environment.cs` — use span path for BALANCE etc.

### Benchmark plan
Same as Candidate 1 plus specific opcode benchmarks for BALANCE, EXTCODEHASH, EXTCODESIZE.

---

## Candidate 3: Cosmetic Fix Only (Remove Redundant .ToArray())

### Change
Remove `.ToArray()` from `PopAddress()` and pass the span directly to `Address(ReadOnlySpan<byte>)`.

```csharp
// Before:
new Address(_bytes.Slice(..., AddressSize).ToArray())
// After:
new Address(_bytes.Slice(..., AddressSize))
```

### Why NOT faster
The `Address(ReadOnlySpan<byte>)` constructor calls `.ToArray()` internally at `Address.cs:150`.
This change moves the allocation from caller to constructor — **zero performance impact**.

### Expected impact: 0%
This is purely a code cleanliness change. It makes the code slightly more idiomatic by
letting the constructor handle the copy, but has no measurable effect.

### Difficulty: S
- 2 lines changed in `EvmStack.cs`

### Risks: None
- Functionally identical

### Recommendation
**Do this as part of Candidate 1** (it's a natural intermediate step), but do NOT treat
this as the optimization itself.

---

## Ranking by ROI

| Rank | Candidate | Impact | Difficulty | ROI |
|------|-----------|--------|------------|-----|
| 1 | Address caching for warm addresses | 2-5% on CALL-heavy | M | **Best** |
| 2 | Span-based state lookup overloads | 3-8% on read opcodes | L | Good but high cost |
| 3 | Remove .ToArray() cosmetic fix | 0% | S | None |

**Recommendation**: Proceed with Candidate 1. It provides meaningful allocation reduction
with manageable scope. The cosmetic fix (Candidate 3) should be included as a natural
side-effect. Candidate 2 is valuable but should be a separate target due to its large
blast radius.
