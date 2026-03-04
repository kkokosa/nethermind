# Research Brief: EVM-3

## Target — RETURN/REVERT allocate via returnData.ToArray()

Every RETURN and REVERT opcode copies return data from pooled EVM memory into a
new heap-allocated `byte[]`. In nested call scenarios (10-100+ calls per tx),
this compounds into significant GC pressure.

## Current Implementation

### Allocation sites

**RETURN** — `EvmInstructions.Call.cs:362`
```csharp
vm.ReturnData = returnData.ToArray();
```
Where `returnData` is `ReadOnlyMemory<byte>` from `EvmPooledMemory.TryLoad()`.

**REVERT** — `EvmInstructions.ControlFlow.cs:189`
```csharp
vm.ReturnData = returnData.ToArray();
```
Same pattern.

### How the data flows

1. RETURN/REVERT pops `(offset, length)` from stack
2. `EvmPooledMemory.TryLoad()` returns a `ReadOnlyMemory<byte>` slice of the
   pooled memory buffer — zero-copy at this point
3. `.ToArray()` allocates a new `byte[]` and copies the data
4. Stored in `vm.ReturnData` (typed `object`, can hold `byte[]`, `VmState<T>`,
   or `EofCodeInfo`)
5. After the opcode loop exits, `RunByteCode()` checks the type:
   - `byte[]` → `new CallResult(null, data, null, version)` (VirtualMachine.cs:1306-1309)
   - `VmState<T>` → `new CallResult(state)` (VirtualMachine.cs:1311-1313)
   - REVERT path: `new CallResult(null, (byte[])ReturnData, ...)` (VirtualMachine.cs:1319)
6. `CallResult.Output` is `(CodeInfo, ReadOnlyMemory<byte>)` — the `byte[]`
   gets implicitly converted to `ReadOnlyMemory<byte>`

### Where the output is consumed

**Nested call return** — `HandleRegularReturn()` (VirtualMachine.cs:338-363):
```csharp
ReturnDataBuffer = callResult.Output.Bytes;  // ReadOnlyMemory<byte> assignment
previousCallOutput = callResult.Output.Bytes.Span.SliceWithZeroPadding(...);
```
The `ReturnDataBuffer` (typed `ReadOnlyMemory<byte>`) is set directly.
RETURNDATASIZE/RETURNDATACOPY read from it.

**Top-level return** — `TransactionProcessor.cs:275-281`:
```csharp
byte[] output = substate.ShouldRevert ? substate.Output.Bytes.ToArray() : [];
tracer.MarkAsSuccess(env.ExecutingAccount, spentGas, substate.Output.Bytes.ToArray(), logs, stateRoot);
```
Another `.ToArray()` at the top level (EVM-4 target, separate from EVM-3).

**Contract deployment** — `TransactionProcessor.cs:802`:
```csharp
byte[] code = substate.Output.Bytes.ToArray();
```
Code is copied for storage (correct — needs to outlive the VM).

## Call Graph

### Hot callers (block processing path)

```
TransactionProcessor.Execute()
  → VirtualMachine.ExecuteTransaction()
    → RunByteCode()
      → InstructionReturn()     ← RETURN opcode, sets vm.ReturnData = byte[]
      → InstructionRevert()     ← REVERT opcode, sets vm.ReturnData = byte[]

      → exits opcode loop
      → DataReturn: checks ReturnData type, wraps in CallResult

    → HandleRegularReturn()     ← nested call: assigns CallResult.Output.Bytes
                                    to ReturnDataBuffer (ReadOnlyMemory<byte>)
    → HandleRevert()            ← nested revert: same pattern
```

Per call frame that returns data, there is exactly **one `.ToArray()` allocation**.
For a transaction with N nested calls each returning data, that's N allocations.

### Cold callers

- `VirtualMachine.Warmup.cs:174` — warmup path, checks `ReturnData is VmState<T>`
- Tracing paths — `ReportActionEnd()` receives `ReturnDataBuffer`
- EOF return paths — use `EofCodeInfo` variant, not `byte[]`

## Baseline Benchmark

**Existing**: `StaticCallBenchmarks.cs` — exercises STATICCALL in a loop but the
called contract (address 4, ecrecover precompile) returns empty data. This does
NOT exercise the return data allocation path.

**No existing benchmark** specifically targets return data allocation in nested calls.
The `EvmOpcodesBenchmark` covers RETURN indirectly but doesn't have `[MemoryDiagnoser]`.

**Benchmark gap**: Need a benchmark with contracts that chain CALLs and return
meaningful data (32-256 bytes) to measure the allocation overhead.

## Prior Art — Geth and Reth

### Geth (Go)
- `opReturn` calls `scope.Memory.GetCopy()` which does `make([]byte, size)` + `copy()`
- **Always allocates** a fresh `[]byte` on RETURN
- `evm.returnData = ret` is a pointer assignment (no second copy)
- Net: 1 alloc + 2 memcpy per call frame return

### Reth/revm (Rust)
- `return_inner` calls `interpreter.memory.slice_len(offset, len).to_vec().into()`
- **Always allocates** a `Vec<u8>`, wrapped in `Bytes` (Arc-like ref-counted handle)
- After initial copy, all subsequent propagation is O(1) via `Bytes` clone/move
- Net: 1 alloc + 2 memcpy per call frame return

### Observation
Both competitors allocate on RETURN. The copy is fundamentally necessary because
the callee's EVM memory may be reused or released after the call returns. However,
revm's `Bytes` approach avoids the second allocation that Nethermind does at the
`TransactionProcessor` level (EVM-4, not EVM-3).

The key insight is: Nethermind's `.ToArray()` copies from ArrayPool-backed memory
to a GC-tracked `byte[]`. If we could instead keep the data as `ReadOnlyMemory<byte>`
backed by a pooled buffer, we'd avoid allocating on the managed heap — but we'd
need to manage buffer lifetime carefully.

## Blast Radius

### What would change

1. **`vm.ReturnData` type** — currently `object`, used as discriminated union for
   `byte[]`, `VmState<T>`, `EofCodeInfo`. Would need to support `ReadOnlyMemory<byte>`
   instead of `byte[]`.

2. **`CallResult.Output.Bytes`** — already `ReadOnlyMemory<byte>`, no change needed.

3. **`ReturnDataBuffer`** — already `ReadOnlyMemory<byte>`, no change needed.

4. **TransactionSubstate.Output.Bytes** — already `ReadOnlyMemory<byte>`.

5. **TransactionProcessor** — already does `.ToArray()` for tracer output (EVM-4).
   Would continue to work since `ReadOnlyMemory<byte>` → `byte[]` via `.ToArray()`
   is already used there.

### Interfaces affected

- `VirtualMachine<T>.ReturnData` property (internal, `object` type) — minor change
- `CallResult` constructor (internal, ref struct) — already takes `ReadOnlyMemory<byte>`

### Consensus risk

**Low**. The optimization only affects memory allocation strategy, not the data
content. The bytes returned are identical. The EVM memory contents at the
(offset, length) are the same regardless of whether they're copied to `byte[]`
or referenced via `ReadOnlyMemory<byte>`.

**Caveat**: Buffer lifetime. If we use a pooled buffer, we must ensure it isn't
returned to the pool while still referenced by `ReturnDataBuffer`. The current
`EvmPooledMemory` returns its backing array to `ArrayPool` on dispose. Since
`ReturnDataBuffer` is reassigned on every call frame boundary, the reference is
short-lived and bounded to the current call depth — but this needs careful
verification.
