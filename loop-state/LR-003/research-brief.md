# Research Brief: EVM-3

## Target — RETURN/REVERT allocate via returnData.ToArray()

Every contract call frame that executes RETURN or REVERT copies return data from pooled
EVM memory into a freshly heap-allocated `byte[]`. In nested call scenarios (10-100+
calls per transaction), this creates significant GC pressure proportional to return data
size times call depth.

## Current Implementation

### Allocation sites

**RETURN opcode** — `Instructions/EvmInstructions.Call.cs:362`
```csharp
vm.ReturnData = returnData.ToArray();
```

**REVERT opcode** — `Instructions/EvmInstructions.ControlFlow.cs:189`
```csharp
vm.ReturnData = returnData.ToArray();
```

Both follow the same pattern:
1. Pop `position` and `length` from EVM stack
2. `vm.VmState.Memory.TryLoad(position, length, out ReadOnlyMemory<byte> returnData)` — returns a slice of the pooled backing array (`EvmPooledMemory.cs:209`)
3. `.ToArray()` copies data to a new heap `byte[]`
4. Stored in `vm.ReturnData` (type: `object`, `VirtualMachine.cs:111`)

### Why .ToArray() exists

The `ReadOnlyMemory<byte>` from `TryLoad` points into `EvmPooledMemory._memory`, which is
an `ArrayPool<byte>.Shared` rental. When the child frame completes, `VmState.Dispose()`
(VmState.cs:253) calls `_memory.Dispose()` which returns the array to the pool. The data
must be copied out before this happens.

### Data flow after allocation

1. `RunByteCode` returns `CallResult(null, data, null, version)` — `CallResult.cs:47-55`
   - `Output.Bytes` holds the `byte[]` as `ReadOnlyMemory<byte>`
2. For nested frames: `HandleRegularReturn` (`VirtualMachine.cs:342`) copies `callResult.Output.Bytes` into `ReturnDataBuffer`
3. `ReturnDataBuffer` is consumed by RETURNDATASIZE, RETURNDATACOPY, RETURNDATALOAD opcodes
4. For top-level: `PrepareTopLevelSubstate` extracts output for `TransactionSubstate`

### The ReturnData polymorphism problem

`ReturnData` is typed as `object` to carry multiple types:
- `null` — no return (continue execution)
- `byte[]` — frame completed with output data
- `VmState<TGasPolicy>` — new call frame to execute
- `EofCodeInfo` — EOF container return

This polymorphic control-flow mechanism makes it non-trivial to change `ReturnData` to
`ReadOnlyMemory<byte>`, since it carries non-byte-array types too.

## Call Graph

### Hot callers (block processing path)

```
TransactionProcessor.Execute()
  -> VirtualMachine.ExecuteTransaction()
    -> RunByteCode() [opcode dispatch loop]
      -> InstructionReturn()     [EvmInstructions.Call.cs:362]  ** ALLOCATION **
      -> InstructionRevert()     [EvmInstructions.ControlFlow.cs:189]  ** ALLOCATION **
    -> DataReturn label [VirtualMachine.cs:1306] — casts ReturnData to byte[]
    -> Revert label [VirtualMachine.cs:1319] — casts ReturnData to byte[]
    -> HandleRegularReturn() [VirtualMachine.cs:338-364] — sets ReturnDataBuffer
    -> HandleRevert() — sets ReturnDataBuffer
```

### Cold callers (RPC, testing)

- `SimulateTxTracer.cs:86,114` — RPC simulate results (cold)
- `Contract.ConstantContract.cs` — consensus AuRa validator calls (infrequent)
- Test files: `ReturnDataTests.cs`, `EthSimulateTestsSimplePrecompiles.cs`

### ReturnDataBuffer consumers (hot, read-only)

- `InstructionReturnDataSize` (EvmInstructions.Eof.cs:79) — RETURNDATASIZE opcode
- `InstructionReturnDataCopy` (EvmInstructions.Eof.cs:114) — RETURNDATACOPY opcode
- `InstructionReturnDataLoad` (EvmInstructions.Eof.cs:831) — RETURNDATALOAD opcode
- `_txTracer.ReportActionEnd()` — tracing (VirtualMachine.cs:360)

## Baseline Benchmark

**No dedicated benchmark exists.** The existing benchmarks that partially cover this:

| Benchmark | File | Coverage | Gap |
|-----------|------|----------|-----|
| `StaticCallBenchmarks` | `Evm.Benchmark/StaticCallBenchmarks.cs` | Has [MemoryDiagnoser], exercises STATICCALL | Calls empty address — no return data produced |
| `BlockProcessingBenchmark` | `Evm.Benchmark/BlockProcessingBenchmark.cs` | Has [MemoryDiagnoser], full pipeline | Contract uses STOP — no return data |
| `EvmOpcodesBenchmark` | `Evm.Benchmark/EvmOpcodesBenchmark.cs` | Per-opcode timing | No [MemoryDiagnoser] |

**Conclusion**: A new `NestedCallBenchmark` is needed with contracts that return meaningful
data at varying call depths and data sizes.

## Prior Art

### Reth (Rust)
Reth uses `Bytes` (a reference-counted immutable bytes type from the `bytes` crate) for
return data. When a frame returns, the return data is stored as `Bytes` which can be
cheaply cloned (just increments a refcount). No copying needed.

### Geth (Go)
Geth copies return data to a `[]byte` slice similar to Nethermind. Go's GC handles short-lived
allocations more efficiently via its generational-like nursery. Geth's approach is functionally
identical to Nethermind's `.ToArray()`.

### Key insight
Reth's approach (reference counting) avoids the copy entirely. In .NET, the closest analog
would be `ArrayPool` rentals with a reference-counted wrapper, or simply renting from
ArrayPool and tracking lifetime explicitly.

## Blast Radius

### Interfaces affected

1. **`VirtualMachine.ReturnData`** (object property, VirtualMachine.cs:111)
   - Currently `object` — used for control flow signaling
   - Changing type requires touching the polymorphic dispatch at lines 1306-1319

2. **`CallResult.Output`** (ref struct, CallResult.cs:67)
   - Already `ReadOnlyMemory<byte>` — no change needed for pooled arrays

3. **`ReturnDataBuffer`** (ReadOnlyMemory<byte>, VirtualMachine.cs:110)
   - Already `ReadOnlyMemory<byte>` — compatible with pooled arrays

### Downstream dependents

- RETURNDATASIZE/RETURNDATACOPY/RETURNDATALOAD opcodes: read-only access to `ReturnDataBuffer`, unaffected
- Tracers (`ReportActionEnd`): receive `ReadOnlyMemory<byte>`, unaffected
- `TransactionSubstate`: receives output bytes at top-level, may need attention

### Consensus risk

**Low** — the optimization changes *when* memory is returned to pool, not *what* data is returned.
The byte content remains identical. Risk is limited to use-after-return bugs if pooled array
lifetime is mismanaged.

### Key constraint

The pooled memory (`EvmPooledMemory._memory`) is returned to `ArrayPool` when the child
`VmState` is disposed (line 253). Any optimization must ensure the return data remains
valid until it's consumed by the parent frame (specifically until `HandleRegularReturn`
copies it to parent memory at `VirtualMachine.cs:347`).
