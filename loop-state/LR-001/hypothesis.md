# Hypothesis: EVM-1 — PopAddress() Allocation Elimination

## Status of the Original Target Description

The original EVM-1 description ("remove `.ToArray()`, pass span directly") is **incorrect**.
Removing `.ToArray()` from `PopAddress()` results in zero allocation savings because
`Address(ReadOnlySpan<byte>)` calls `bytes.ToArray()` internally. The allocation is
structurally mandatory given that `Address` is a class with `byte[] Bytes`.

The real optimization requires a different approach. Three candidates follow.

---

## Candidate 1: Address Interning Cache in PopAddress (Recommended)

### Change
Add a small, thread-local or seqlock-based address cache to `PopAddress()` that
returns a cached `Address` object when the same 20-byte sequence is seen again.

**Files to modify:**
- `src/Nethermind/Nethermind.Evm/EvmStack.cs` — add cache lookup in PopAddress
- New file or inline: `AddressCache` (modeled on `KeccakCache.cs` pattern)

**Implementation sketch:**
```csharp
public Address? PopAddress()
{
    if (Head-- == 0) return null;
    ReadOnlySpan<byte> bytes = _bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize);
    return AddressCache.GetOrCreate(bytes);
}
```

Where `AddressCache.GetOrCreate` does:
1. Hash the 20 bytes (use FastHash — already exists in codebase)
2. Probe a fixed-size array (e.g., 4096 entries)
3. If match: return cached `Address` (zero allocation)
4. If miss: `new Address(bytes)` (one allocation), store in cache, return

### Mechanism
Addresses are highly repetitive within a block. The same contract address (WETH, USDC,
Uniswap router) appears in hundreds of CALL opcodes. A small cache (4K–16K entries)
would achieve >90% hit rate on real-world DeFi blocks, eliminating most `byte[20]` +
`Address` object allocations.

This follows the proven `KeccakCache` pattern already in the codebase (`KeccakCache.cs`
uses a 128K-entry seqlock array for Keccak hash results and already has a 20-byte
fast path).

### Expected Impact
- **Hit rate estimate**: 80–95% on mainnet blocks (DeFi blocks call the same contracts repeatedly)
- **Per-hit savings**: 20 bytes (`byte[20]`) + ~40 bytes (Address object + header) = ~60 bytes
- **Frequency**: Thousands per block
- **Estimated allocation reduction**: 50–100 KB per block from this path alone
- **Speed improvement**: 5–15% for PopAddress-heavy paths (cache lookup is ~5ns vs ~20ns for alloc + GC pressure)
- **GC impact**: Significant reduction in Gen0 collections during block processing

### Difficulty: S–M
- S if using a simple `Dictionary<AddressAsKey, Address>` per-block
- M if building a proper lock-free seqlock cache like KeccakCache

### Risks
1. **Cache coherence**: Cache entries must not be mutated after creation. `Address` is
   immutable (sealed class, readonly `Bytes` property set only in constructor), so this
   is safe.
2. **Memory overhead**: 4096 entries × 8 bytes (reference) = 32 KB — negligible.
3. **Cache pollution**: Pathological contracts could thrash the cache. Mitigation: direct-mapped
   cache with simple eviction (just overwrite) — no complex eviction policy needed.
4. **Thread safety**: If using a per-`EvmStack` cache (stack is per-call-frame), no
   threading concern. If using a shared cache, need seqlock or CAS.
5. **Correctness**: No consensus impact — `Address` is immutable and equality is by bytes.
   Returning a cached instance vs a fresh one is semantically identical.

### Benchmark Plan
1. Add `PopAddress()` benchmark to `EvmStackBenchmarks.cs` with `[MemoryDiagnoser]`
2. Run baseline (current code)
3. Implement cache
4. Run with cache — compare allocation count and throughput
5. Also run `EvmOpcodesBenchmark` with `--memory` flag for CALL/BALANCE/EXTCODESIZE
6. Run `BlockProcessingBenchmark.Transfers_200` and `ContractCall_200` for end-to-end

---

## Candidate 2: Reuse Warm-Set Address Objects

### Change
When `PopAddress()` produces an address that is already in the EIP-2929 warm set
(`StackAccessTracker.AccessedAddresses`), return the existing `Address` object from
the warm set instead of allocating a new one.

**Files to modify:**
- `src/Nethermind/Nethermind.Evm/EvmStack.cs` — add warm-set lookup
- Possibly `StackAccessTracker.cs` — add `TryGet(ReadOnlySpan<byte>, out Address)` method

**Implementation sketch:**
```csharp
public Address? PopAddress(in StackAccessTracker tracker)
{
    if (Head-- == 0) return null;
    ReadOnlySpan<byte> bytes = _bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize);
    if (tracker.TryGetWarm(bytes, out Address cached))
        return cached;
    return new Address(bytes);
}
```

### Mechanism
The warm set already contains Address objects for addresses accessed earlier in the
transaction. Since EIP-2929 charges extra gas for cold access, most addresses in
real transactions are accessed multiple times (first cold, then warm). The second+
access can reuse the warm-set object.

### Expected Impact
- **Hit rate**: 60–80% (first access per address is always a miss)
- **Allocation savings**: Lower than Candidate 1 (only within single tx, not across txs)
- **Speed**: Slightly slower than a direct-mapped cache due to HashSet lookup

### Difficulty: M
- Need to add span-based lookup to `JournalSet<Address>` (currently keyed by `Address`)
- Need to thread the `StackAccessTracker` through to `PopAddress()` call sites (or access it via the VM)
- PopAddress signature change affects all 7 callers

### Risks
1. **Signature change**: `PopAddress()` currently takes no parameters. Adding a tracker
   parameter changes all call sites.
2. **Warm set scoping**: The warm set is per-transaction. Does not help across transactions.
3. **JournalSet doesn't support span lookup**: `HashSet<Address>` is keyed by `Address`
   objects. You'd need to add a `TryGetValue` overload that accepts `ReadOnlySpan<byte>`
   as an alternate key, which isn't trivial.

### Benchmark Plan
Same as Candidate 1, plus compare hit rates between per-tx warm-set vs per-block cache.

---

## Candidate 3: Remove Dead Code (bool PopAddress overload)

### Change
Delete the `bool PopAddress(out Address address)` overload at `EvmStack.cs:469-479`.
It has zero callers anywhere in the codebase.

**Files to modify:**
- `src/Nethermind/Nethermind.Evm/EvmStack.cs` — delete lines 469-479

### Mechanism
Dead code removal. Reduces cognitive load and IL size (minor JIT benefit from smaller
method table).

### Expected Impact
- **Performance**: Negligible (dead code doesn't execute)
- **Maintenance**: Small positive (less code to maintain)

### Difficulty: S
Trivial deletion.

### Risks
None — code is unreachable.

### Benchmark Plan
Not needed — no runtime behavior change.

---

## Ranking by ROI

| Rank | Candidate | Impact | Difficulty | ROI |
|------|-----------|--------|------------|-----|
| 1 | **Address Interning Cache** | High (50-100KB/block alloc reduction, GC pressure) | S–M | **Best** |
| 2 | Warm-Set Reuse | Medium (per-tx only) | M | Moderate |
| 3 | Dead Code Removal | Negligible | S | Low (but free) |

## Recommendation

**Implement Candidate 1 (Address Interning Cache)** as the primary optimization.
Bundle Candidate 3 (dead code removal) as a cleanup in the same PR.

Skip Candidate 2 — it provides less benefit than Candidate 1 and requires more
invasive changes (PopAddress signature change, JournalSet modifications).

The cache should be designed as a simple, direct-mapped array (like KeccakCache)
rather than a Dictionary, to minimize lookup overhead on the hot path. A per-block
or thread-static cache is preferred over a global shared cache to avoid contention.
