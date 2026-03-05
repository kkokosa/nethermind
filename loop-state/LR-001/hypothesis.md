# Hypothesis: EVM-1

## Revised Assessment

The original target description ("remove `.ToArray()`, pass span directly") is **misleading**.
The `Address(ReadOnlySpan<byte>)` constructor at `Address.cs:141` internally calls `.ToArray()`
at line 150. Removing `.ToArray()` from PopAddress just moves it into the Address constructor --
**zero net allocation reduction**.

The real problem is that `Address` is a `sealed class` wrapping `byte[]`. Every PopAddress
creates 2 heap objects (byte[20] + Address). Competing clients (Reth, Geth) use value types
with zero allocations.

Three candidates are proposed below, from smallest to largest change.

---

## Candidate 1 (Recommended): Deferred Address materialization

### Change
Modify `PopAddress()` to return the raw 20 bytes as a ref/span, and only create
an `Address` object at the last moment when the downstream API requires it.

**Concrete changes:**
1. Add `PopAddressBytes(out ReadOnlySpan<byte> bytes)` to `EvmStack.cs` that returns
   the span directly (no allocation)
2. In each of the 7 opcode callers, use the span for EIP-2929 warm/cold checks first.
   If the address is already warm (common case for repeated calls to same contract),
   we can check warmth via the span hash without materializing an Address
3. Materialize `Address` only when needed for state lookups (cold path)

### Mechanism
- **Hot case (warm address)**: The address was already accessed in this transaction.
  `StackAccessTracker.IsCold(Address?)` currently requires an Address object. Adding a
  span-based `IsCold(ReadOnlySpan<byte>)` overload would avoid allocation on the common
  "already warm" path.
- **Cold case**: Must create Address for state lookups. One allocation still occurs but
  only on first access per address per transaction.

### Expected impact
- **10-30% reduction in PopAddress allocations** in typical blocks (most CALLs are to
  already-warm addresses, especially in DeFi contracts with repeated interactions)
- Per-opcode: eliminates 2 allocations on warm hits (majority of CALL/BALANCE/etc.)
- Per-block with 1000 address ops, ~70% warm rate: ~700 fewer Address allocations

### Difficulty: M
- Requires new span-based overloads on `StackAccessTracker`
- Requires modifying 7 opcode instruction files
- `JournalSet<Address>` needs span-based `Contains()` method

### Risks
- `JournalSet<Address>` uses `Address.Equals()` and `GetHashCode()` -- need to replicate
  hash computation for spans (Address uses `SpanExtensions.FastHash()` which already
  works on spans -- `Address.cs:218`)
- Must ensure span doesn't outlive the stack buffer (ref struct lifetime rules handle this)
- More complex code in opcode implementations

### Files
- `src/Nethermind/Nethermind.Evm/EvmStack.cs`
- `src/Nethermind/Nethermind.Evm/StackAccessTracker.cs`
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.Call.cs`
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.Environment.cs`
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.CodeCopy.cs`
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.ControlFlow.cs`

### Benchmark plan
1. Create `EvmAddressPopBenchmark` with `[MemoryDiagnoser]`:
   - Baseline: current PopAddress with Address materialization
   - Optimized: PopAddressBytes span path + conditional materialization
2. Run `EvmOpcodesBenchmark` with `--memory` for CALL, BALANCE, EXTCODESIZE opcodes
3. Run `BlockProcessingBenchmark.ContractCall_200` for end-to-end impact

---

## Candidate 2: Address object pooling via ThreadStatic

### Change
Pool `Address` objects per-thread to avoid repeated allocation.

**Concrete changes:**
1. Add `[ThreadStatic] static Address? t_pooledAddress` to EvmStack
2. In `PopAddress()`: reuse pooled Address when available, copy bytes into its
   existing `Bytes` array instead of allocating new
3. Caller must not hold references beyond the opcode scope (already true for most paths)

### Mechanism
- Eliminates both allocations (byte[20] + Address) by reusing a single Address per thread
- `Address.Bytes` is a `byte[]` field -- copy 20 bytes into existing array via span copy
- After opcode completes, address can be returned to pool

### Expected impact
- **~95% reduction in PopAddress allocations** (one initial allocation per thread, then reuse)
- Estimated 5-15% improvement in opcode throughput for address-consuming opcodes

### Difficulty: M
- `Address` is immutable by convention (sealed class, Bytes set in constructor only).
  Would need internal mutation path or a mutable `PooledAddress` subclass -- but Address
  is sealed, so would need a different approach
- **Blocker**: `Address.Bytes` has no setter. The field is `public byte[] Bytes { get; }`
  set only in the constructor. Would need to add an internal `SetBytes()` method or use
  `Unsafe.AsRef` to mutate the backing field
- Risk of use-after-return bugs if callers hold references

### Risks
- **High risk of aliasing bugs**: If a caller stores the pooled Address (e.g., in
  JournalSet for EIP-2929), it would be overwritten on next PopAddress
- The CALL opcode stores codeSource in ExecutionEnvironment for the call frame duration --
  this would alias with the next PopAddress in the child frame
- **Not viable without significant refactoring to ensure no long-lived references**

### Files
- `src/Nethermind/Nethermind.Evm/EvmStack.cs`
- `src/Nethermind/Nethermind.Core/Address.cs` (add internal mutability)

### Benchmark plan
- Same as Candidate 1, but measure allocation count specifically

---

## Candidate 3: Introduce ValueAddress struct (long-term)

### Change
Create a 20-byte value type `ValueAddress` (similar to how `ValueHash256` wraps 32 bytes)
and use it throughout the EVM hot path.

**Concrete changes:**
1. Add `ValueAddress` as a `readonly struct` with inline 20-byte storage
   (using `[InlineArray(20)]` or `fixed byte[20]`)
2. Add `PopValueAddress()` to EvmStack returning ValueAddress (zero allocation)
3. Add `ValueAddress`-accepting overloads to IWorldState, ICodeInfoRepository,
   StackAccessTracker
4. Convert `Address ↔ ValueAddress` only at module boundaries

### Mechanism
- Value type lives on the stack -- zero GC pressure
- Same approach as Reth (`Address([u8; 20])`) and Geth (`[20]byte`)
- `ValueHash256` already proves this pattern works in the codebase

### Expected impact
- **100% elimination of PopAddress allocations** -- matches Reth/Geth behavior
- Estimated 10-20% improvement in address-consuming opcode throughput
- Reduced GC pressure across the entire EVM execution path

### Difficulty: L
- New type + overloads across EVM, State, and Trie module boundaries
- Must maintain `Address` class for backward compatibility at API boundaries
- Extensive test surface to validate

### Risks
- Large blast radius across module boundaries
- Must ensure SIMD equality (Vector128 + uint) works with inline array layout
- Hash computation must be identical for consensus safety

### Files
- `src/Nethermind/Nethermind.Core/Address.cs` (add ValueAddress)
- `src/Nethermind/Nethermind.Evm/EvmStack.cs`
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.*.cs` (all 4 files)
- `src/Nethermind/Nethermind.Evm/StackAccessTracker.cs`
- `src/Nethermind/Nethermind.State/IWorldState.cs` (new overloads)
- `src/Nethermind/Nethermind.Evm/CodeInfoRepository.cs`

### Benchmark plan
- Same as Candidate 1, plus full `BlockProcessingBenchmark` suite

---

## Ranking by ROI

| Rank | Candidate | Impact | Difficulty | ROI |
|------|-----------|--------|------------|-----|
| 1 | Deferred materialization | 10-30% alloc reduction | M | Best -- incremental, safe |
| 2 | ValueAddress struct | 100% alloc elimination | L | High impact but large effort |
| 3 | Address pooling | ~95% alloc reduction | M | Blocked by aliasing risks |

### Recommendation

Start with **Candidate 1** (deferred materialization). It provides meaningful allocation
reduction on the most common path (warm addresses) with manageable blast radius. If
benchmarks show significant gains, follow up with Candidate 3 as a longer-term effort.

Candidate 2 is **not recommended** due to aliasing risks -- the CALL opcode stores the
Address in ExecutionEnvironment for the call frame, which would conflict with pooled reuse.
