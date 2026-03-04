# Research Brief: EVM-2

## Target — SSTORE/TSTORE allocate via bytes.ToArray() on every storage write

Every non-zero SSTORE and TSTORE that changes a storage value calls `.ToArray()` on a
`ReadOnlySpan<byte>` (popped from the EVM stack), allocating a 32-byte `byte[]` on the
managed heap. This allocation is pure waste because the span data already exists in the
stack buffer.

## Current Implementation

### SSTORE (persistent storage)

Two variants exist — both have the same allocation pattern:

**Legacy gas metering** — `EvmInstructions.Storage.cs:402`:
```csharp
vm.WorldState.Set(in storageCell, newIsZero ? BytesZero : bytes.ToArray());
```

**Net metered gas** — `EvmInstructions.Storage.cs:564`:
```csharp
vm.WorldState.Set(in storageCell, newIsZero ? BytesZero : bytes.ToArray());
```

Both methods pop a 32-byte word from the EVM stack via `stack.PopWord256()` (returns
`Span<byte>` pointing into the 33KB stack buffer), strip leading zeros via
`.WithoutLeadingZeros()`, then call `.ToArray()` to create the `byte[]` required by
`IWorldState.Set()`.

### TSTORE (transient storage)

**`EvmInstructions.Storage.cs:109`**:
```csharp
vm.WorldState.SetTransientState(in storageCell, !bytes.IsZero() ? bytes.ToArray() : BytesZero32);
```

Same pattern: pop span from stack, `.ToArray()`, pass to interface.

### Why byte[] is required

The `IWorldState.Set(in StorageCell, byte[])` and `SetTransientState(in StorageCell, byte[])`
interfaces accept `byte[]`, not `ReadOnlySpan<byte>`. This forces the caller to allocate.

The value flows through this chain:
1. `IWorldState.Set()` — interface (`IWorldState.cs:51`)
2. `WorldState.Set()` — delegates to `_persistentStorageProvider.Set()` (`WorldState.cs:134`)
3. `PartialStorageProviderBase.Set()` → `PushUpdate()` — stores `byte[]` in `Change` struct (`PartialStorageProviderBase.cs:50,215`)
4. `Change.Value` is a `readonly byte[]` field (`PartialStorageProviderBase.cs:259`)
5. During commit: `SaveChange()` stores value in `StorageChangeTrace` struct
6. Finally: `StorageTree.Set(UInt256, byte[])` receives the value and RLP-encodes it

The `byte[]` is stored in the change log (a `List<Change>`) and must survive until block
commit. This means the allocation cannot be eliminated entirely — the value **must** be
copied from the EVM stack (which is reused per-opcode) to a heap buffer.

However, the current approach allocates a **new array per SSTORE** even when values could
be pooled or reused.

## Call Graph

### Hot callers (block processing path)
- `InstructionSStoreUnmetered<>()` — `EvmInstructions.Storage.cs:340` → `Set()` at line 402
- `InstructionSStoreMetered<>()` — `EvmInstructions.Storage.cs:442` → `Set()` at line 564
- `InstructionTStore<>()` — `EvmInstructions.Storage.cs:85` → `SetTransientState()` at line 109

### Cold callers (test, setup)
- `EvmOpcodesBenchmark.cs` — `InitializeDynamicStorageLocations()` (benchmark setup)
- Various test files (`StorageProviderTests.cs`, `StateReaderTests.cs`, etc.)
- `WitnessGeneratingWorldState.cs:170` — decorator pass-through
- `WorldStateMetricsDecorator.cs:27` — metrics decorator pass-through

### Interface implementations that must change
- `IWorldState.Set()` — `IWorldState.cs:51`
- `IWorldState.SetTransientState()` — `IWorldState.cs:65`
- `WorldState.Set()` — `WorldState.cs:131`
- `WorldState.SetTransientState()` — `WorldState.cs:141`
- `WorldStateMetricsDecorator.Set()` — `WorldStateMetricsDecorator.cs:27`
- `WorldStateMetricsDecorator.SetTransientState()` — `WorldStateMetricsDecorator.cs:31`
- `WitnessGeneratingWorldState.Set()` — `WitnessGeneratingWorldState.cs:167`
- `WitnessGeneratingWorldState.SetTransientState()` — `WitnessGeneratingWorldState.cs:178`
- `PartialStorageProviderBase.Set()` — `PartialStorageProviderBase.cs:50`

## Baseline Benchmark

### Existing coverage
- `EvmOpcodesBenchmark` covers SSTORE execution time (line 96 of OPTIMIZATION-TARGETS.md),
  but **without `[MemoryDiagnoser]`** — allocation count/size is not tracked.
- The benchmark runs 8192 SSTORE operations per invocation with pre-seeded storage.
- Regression threshold for SSTORE is 20% (StateThresholdPercent).

### Missing
- No dedicated allocation-tracking benchmark for SSTORE/TSTORE
- No benchmark isolating the `.ToArray()` cost vs the rest of SSTORE gas metering + state lookup

## Prior Art — Geth and Reth

### Go-Ethereum (Geth)
- SSTORE passes storage values as `common.Hash` — a **fixed 32-byte value type** (not heap-allocated)
- `StateDB.SetState(address, key common.Hash, value common.Hash)` — all by value
- **Zero heap allocations** on the SSTORE hot path for the value itself

### Reth (Rust)
- Uses `U256` value type for storage values — **stack-allocated**
- No heap allocation for the storage value during SSTORE
- Focus is on storage I/O patterns (hot/cold storage) rather than value allocation

### Key insight
Both Geth and Reth use **value types** for storage values, avoiding heap allocation entirely.
Nethermind uses `byte[]` (heap reference type) throughout the storage pipeline, forcing
allocation on every write.

## Blast Radius

### Interface changes required
Changing `IWorldState.Set(in StorageCell, byte[])` to accept `ReadOnlySpan<byte>` is
**not straightforward** because:

1. **Change log storage**: `PartialStorageProviderBase.Change.Value` is `byte[]` — spans
   cannot be stored in structs/classes. The value MUST be materialized to a heap buffer
   at some point before being stored in the change log.

2. **Multiple implementations**: 3 classes implement `IWorldState` (WorldState,
   WitnessGeneratingWorldState, WorldStateMetricsDecorator).

3. **Downstream consumers**: `StorageTree.Set()` also takes `byte[]`, and during commit
   the value from `StorageChangeTrace.After` (a `byte[]`) is passed through.

### Consensus safety
- The optimization only changes **when** the copy happens, not **what** is copied
- The stored value is byte-identical to what `.ToArray()` produces
- No consensus risk as long as the same bytes reach the trie

### What would NOT change
- Public API semantics (same values stored)
- Gas metering (unaffected)
- StorageTree encoding (receives same byte[])
- Commit/flush logic
