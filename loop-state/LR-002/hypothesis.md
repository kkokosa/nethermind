# Hypothesis: EVM-2

## Candidate 1 (Recommended): ArrayPool-based byte[] rental for SSTORE/TSTORE values

### Change
Replace `bytes.ToArray()` with renting a `byte[]` from `ArrayPool<byte>.Shared` at the
SSTORE/TSTORE call site, copying the span into it, and returning the rented array during
commit (when the change log is cleared).

**Exact modifications:**

1. **`EvmInstructions.Storage.cs:402,564`** — Replace `bytes.ToArray()` with a helper
   that rents from ArrayPool and copies:
   ```csharp
   // Before:
   vm.WorldState.Set(in storageCell, newIsZero ? BytesZero : bytes.ToArray());
   // After:
   vm.WorldState.Set(in storageCell, newIsZero ? BytesZero : RentAndCopy(bytes));
   ```

2. **`EvmInstructions.Storage.cs:109`** (TSTORE) — Same change for transient storage.

3. **`PartialStorageProviderBase.cs`** — Add return-to-pool logic in `Reset()` and
   `Restore()` for change log entries that hold rented arrays. Add a bool flag or marker
   to `Change` to distinguish pooled vs static arrays (like `BytesZero`).

4. No interface changes needed — `byte[]` stays as the parameter type.

### Mechanism
- **Why faster**: `ArrayPool<byte>.Shared.Rent()` reuses existing arrays from a
  thread-local pool, avoiding GC pressure. The 32-byte arrays requested will typically
  come from the pool's smallest bucket (size 32 or 64 depending on implementation).
  This converts a per-SSTORE GC allocation into a pool rent/return cycle.
- **GC impact**: Reduces Gen0 collections proportional to SSTORE frequency. For a block
  with 1000 SSTORE operations, this eliminates ~1000 × 32-byte allocations = ~32 KB of
  GC pressure per block.

### Expected impact
- **5-15% reduction in SSTORE opcode allocation** (the `.ToArray()` allocation is a small
  but consistent part of per-opcode overhead)
- **Measurable in block processing benchmarks** with SSTORE-heavy blocks (DeFi, DEX trades)
- **Allocation reduction**: ~32 bytes per SSTORE eliminated from Gen0

### Difficulty: M
- Must track which `byte[]` in the change log are rented vs static
- Must ensure rented arrays are returned exactly once (on Reset/Restore)
- Touches `PartialStorageProviderBase` (shared base class for persistent + transient)

### Risks
1. **Double-return bug**: If a rented array is returned to the pool but still referenced
   (e.g., by `StorageChangeTrace` during commit), data corruption could occur. Mitigation:
   only return arrays after commit is fully complete (in `Reset()`).
2. **Array size mismatch**: `ArrayPool` may return arrays larger than requested (e.g., 64
   bytes for a 32-byte request). All consumers must use the value's logical length, not
   `array.Length`. Current code already handles variable-length values via
   `.WithoutLeadingZeros()` so the actual stored length varies.
3. **Complexity**: Adds pool lifecycle management to a critical path. Must be thoroughly
   tested.

### Files
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.Storage.cs`
- `src/Nethermind/Nethermind.State/PartialStorageProviderBase.cs`
- `src/Nethermind/Nethermind.State/PersistentStorageProvider.cs` (return in CommitCore)
- `src/Nethermind/Nethermind.State/TransientStorageProvider.cs` (return in Reset)

### Benchmark plan
1. Add `[MemoryDiagnoser]` to existing `EvmOpcodesBenchmark` SSTORE test
2. Run baseline: `dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ -- --filter "*EvmOpcodesBenchmark*" --memory`
   filtered to SSTORE only
3. Run `BlockProcessingBenchmark.ContractCall_200` and `MixedBlock` with allocation tracking
4. Compare allocated bytes before/after

---

## Candidate 2: Change IWorldState.Set() to accept ReadOnlySpan<byte> + internal copy

### Change
Change `IWorldState.Set(in StorageCell, byte[])` to `IWorldState.Set(in StorageCell, ReadOnlySpan<byte>)`.
Move the `.ToArray()` call inside `PartialStorageProviderBase.PushUpdate()` instead of at
the EVM call site.

**Exact modifications:**

1. **`IWorldState.cs:51`** — Change `void Set(in StorageCell storageCell, byte[] newValue)`
   to `void Set(in StorageCell storageCell, ReadOnlySpan<byte> newValue)`
2. **`IWorldState.cs:65`** — Same for `SetTransientState`
3. **All implementations** (WorldState, WitnessGeneratingWorldState, WorldStateMetricsDecorator)
   — Update signatures
4. **`PartialStorageProviderBase.PushUpdate()`** — Call `.ToArray()` here instead
5. **`EvmInstructions.Storage.cs:402,564,109`** — Remove `.ToArray()`, pass span directly
6. **Test callers** — Pass spans or use implicit conversion

### Mechanism
- **Why better**: Moves allocation responsibility to the storage layer, which can later
  optimize (pool, reuse, etc.) without changing the EVM code. The EVM caller no longer
  needs to know about allocation strategy.
- **Does NOT eliminate the allocation** — just relocates it. The real win is API cleanliness
  that enables future optimizations (Candidate 1 or similar).

### Expected impact
- **0% immediate performance improvement** — the allocation still happens, just in a
  different location
- **Architectural improvement** — enables future span-based optimizations throughout the
  storage pipeline
- **Slight improvement possible** if combined with ArrayPool in `PushUpdate()`

### Difficulty: M
- Touches `IWorldState` interface (public API) + 3 implementations + 2 decorators
- Many test callers need updating (but most can use implicit `byte[]` → `ReadOnlySpan<byte>`)

### Risks
1. **API change**: `IWorldState` is a public interface. Changing it affects all plugins
   and downstream code that implements it.
2. **No measurable perf gain alone** — requires combination with Candidate 1 to show results

### Files
- `src/Nethermind/Nethermind.Evm/State/IWorldState.cs`
- `src/Nethermind/Nethermind.State/WorldState.cs`
- `src/Nethermind/Nethermind.State/WorldStateMetricsDecorator.cs`
- `src/Nethermind/Nethermind.State/PartialStorageProviderBase.cs`
- `src/Nethermind/Nethermind.Consensus/Stateless/WitnessGeneratingWorldState.cs`
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.Storage.cs`
- Multiple test files

### Benchmark plan
Same as Candidate 1 (no measurable change expected unless combined with pooling).

---

## Candidate 3: Fixed-size stackalloc + pinning for short-lived values

### Change
Since storage values after `.WithoutLeadingZeros()` are at most 32 bytes, use a fixed-size
buffer approach. For transient storage specifically (values don't survive past transaction),
explore if values can be stored in a pre-allocated ring buffer instead of individual arrays.

### Mechanism
- **Why faster**: Eliminates per-value allocation entirely for transient storage
- Ring buffer of N × 32-byte slots, advancing pointer on each TSTORE

### Expected impact
- **TSTORE only**: 10-20% allocation reduction for TSTORE-heavy workloads
- **Not applicable to SSTORE**: persistent values must survive until commit

### Difficulty: L
- Requires custom memory management for transient storage
- Ring buffer sizing must account for maximum transient storage per transaction
- Snapshot/restore must work correctly with ring buffer positions

### Risks
1. **Buffer overflow**: If ring buffer is undersized, must fall back to allocation
2. **Snapshot complexity**: Restore must reset ring buffer position correctly
3. **Limited scope**: Only helps TSTORE, not the more common SSTORE

### Files
- `src/Nethermind/Nethermind.State/TransientStorageProvider.cs`
- `src/Nethermind/Nethermind.State/PartialStorageProviderBase.cs`

### Benchmark plan
- Create TSTORE-heavy benchmark (10000 TSTOREs per invocation)
- Measure allocation delta

---

## Ranking by ROI

| Rank | Candidate | Impact | Difficulty | ROI | Notes |
|------|-----------|--------|------------|-----|-------|
| 1 | **Candidate 1: ArrayPool** | 5-15% alloc reduction | M | **Best** | Minimal API change, measurable GC reduction |
| 2 | Candidate 2: Span interface | 0% alone, enables future | M | Medium | Better long-term but no immediate payoff |
| 3 | Candidate 3: Ring buffer | TSTORE only, 10-20% | L | Low | High complexity for narrow benefit |

## Recommendation

**Proceed with Candidate 1 (ArrayPool rental)**. It provides measurable allocation
reduction without changing public interfaces. The implementation is contained within
the EVM instruction handlers and the storage provider base class.

If the team is open to API changes, combine Candidates 1+2: change the interface to
accept `ReadOnlySpan<byte>`, then use ArrayPool internally in `PushUpdate()`. This gives
both the immediate win and the cleaner API.
