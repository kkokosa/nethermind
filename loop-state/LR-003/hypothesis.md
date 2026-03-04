# Hypothesis: EVM-3

## Candidate 1 (Recommended): Change ReturnData to use ReadOnlyMemory<byte> directly

### Change
Eliminate `.ToArray()` in RETURN and REVERT by passing the `ReadOnlyMemory<byte>`
from `EvmPooledMemory.TryLoad()` directly through the return path.

**Exact modifications:**

1. **`EvmInstructions.Call.cs:362`** — Change from:
   ```csharp
   vm.ReturnData = returnData.ToArray();
   ```
   To:
   ```csharp
   vm.ReturnData = returnData;  // ReadOnlyMemory<byte>, no copy
   ```

2. **`EvmInstructions.ControlFlow.cs:189`** — Same change for REVERT.

3. **`VirtualMachine.cs:111`** — Change `ReturnData` property type from `object`
   to a discriminated union or use a separate field. The current `object` box
   approach supports `byte[]`, `VmState<T>`, and `EofCodeInfo`. We need it to also
   support `ReadOnlyMemory<byte>`.

   Simplest approach: add a `ReadOnlyMemory<byte>? ReturnDataMemory` field
   alongside the existing `ReturnData` object field. RETURN/REVERT set
   `ReturnDataMemory` instead of `ReturnData`.

4. **`VirtualMachine.cs:1306-1319`** — Update the `DataReturn:` label to check
   `ReturnDataMemory` first:
   ```csharp
   if (ReturnDataMemory.HasValue)
   {
       return new CallResult(null, ReturnDataMemory.Value, null, codeInfo.Version);
   }
   ```
   And for Revert:
   ```csharp
   if (ReturnDataMemory.HasValue)
   {
       return new CallResult(null, ReturnDataMemory.Value, null, codeInfo.Version,
           shouldRevert: true, exceptionType);
   }
   ```

5. **`VirtualMachine.cs:1188`** — Clear both fields:
   ```csharp
   ReturnData = null;
   ReturnDataMemory = null;
   ```

### Mechanism
The `ReadOnlyMemory<byte>` from `EvmPooledMemory.TryLoad()` is a slice of an
`ArrayPool<byte>.Shared`-rented buffer. By passing it directly instead of
copying, we eliminate one heap allocation per RETURN/REVERT.

**Why this is safe**: The `EvmPooledMemory` for the callee's frame is NOT
disposed until after the call result has been processed by the parent frame. In
`HandleRegularReturn()` (VirtualMachine.cs:338), the `callResult.Output.Bytes`
is immediately assigned to `ReturnDataBuffer` and the output is sliced for the
parent's memory write. The callee's `EvmPooledMemory` is disposed when its
`VmState` is disposed, which happens AFTER `HandleRegularReturn` completes.

The parent frame's `ReturnDataBuffer` holds a reference to the callee's memory.
This reference is valid until the next CALL/CREATE in the parent frame, which
reassigns `ReturnDataBuffer`. By that point, the callee's `VmState` (and its
memory) has been disposed. **However**, the `ArrayPool` does not zero or
invalidate returned arrays — it just makes them available for reuse. So the
`ReadOnlyMemory<byte>` may point to data that gets overwritten by a subsequent
allocation from the same pool.

**Critical**: This means the parent's RETURNDATACOPY must read the data before
the next CALL allocates memory from the pool. This is guaranteed by the EVM
execution model — RETURNDATACOPY reads happen synchronously before any subsequent
CALL that would allocate new pool memory. But the data MUST be copied if it needs
to persist beyond the current call depth (e.g., for tracers or top-level return).

### Expected impact
- **Allocation reduction**: Eliminates one `byte[]` allocation per RETURN/REVERT
- **Size**: Proportional to return data length (commonly 32-256 bytes, up to 24KB)
- **Frequency**: Per call frame return — tens to hundreds per transaction
- **Estimated improvement**: 5-15% reduction in EVM GC pressure for call-heavy
  transactions. Speed improvement of 2-5% on nested call benchmarks.
- **Note**: Both Geth and Reth allocate here. If we succeed, this is a genuine
  advantage over competitors.

### Difficulty: M
- Touches VirtualMachine.cs (complex file, ~1300 lines)
- Requires careful lifetime analysis of pooled memory
- Type discrimination logic changes
- Need to verify all EOF paths handle the new field

### Risks
1. **Buffer lifetime**: If `ReturnDataBuffer` outlives the pooled memory, we get
   use-after-free (reading stale/overwritten data). Mitigated by EVM execution
   model guarantees, but needs thorough testing.
2. **Top-level return**: `TransactionProcessor` does `.ToArray()` on the final
   output anyway (EVM-4). So the top-level RETURN still allocates. This
   optimization only helps nested calls.
3. **EOF paths**: RETURNCONTRACT and other EOF opcodes have different return data
   patterns. Must not break those paths.
4. **Tracing**: `ReportActionEnd(gas, ReturnDataBuffer)` passes the buffer to
   tracers. If a tracer stores the reference, it could read stale data later.
   Most tracers copy immediately, but custom tracers might not.

### Files
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.Call.cs` (line 362)
- `src/Nethermind/Nethermind.Evm/Instructions/EvmInstructions.ControlFlow.cs` (line 189)
- `src/Nethermind/Nethermind.Evm/VirtualMachine.cs` (lines 111, 1188, 1270, 1294, 1306-1319)

### Benchmark plan
1. Create `NestedCallReturnBenchmark` in `Nethermind.Evm.Benchmark/`:
   - Deploy a chain of contracts: A calls B, B calls C, each returns 32/128/256 bytes
   - Parameterize: call depth (5, 20, 50), return data size (0, 32, 256)
   - Use `[MemoryDiagnoser]` to track allocation delta
2. Run existing `StaticCallBenchmarks` and `BlockProcessingBenchmark` as regression checks
3. Compare allocated bytes before/after optimization

---

## Candidate 2: Pool return data byte arrays via ArrayPool

### Change
Instead of `.ToArray()`, rent from `ArrayPool<byte>.Shared` and copy into it.
Return the rented array when the call frame is popped.

**Modifications:**
1. `EvmInstructions.Call.cs:362` — Use `ArrayPool<byte>.Shared.Rent(length)` +
   `returnData.Span.CopyTo(rented)`, store `(rented, length)` tuple
2. Add cleanup logic in call frame disposal to return the rented array

### Mechanism
Eliminates managed heap allocation by reusing pooled byte arrays. The
`ArrayPool` amortizes allocation cost across many calls.

### Expected impact
- **Allocation reduction**: Same as Candidate 1 for GC pressure
- **Speed**: Slightly worse than Candidate 1 (still does a memcpy)
- **Estimated improvement**: 3-8% on nested call benchmarks

### Difficulty: M
- Similar scope to Candidate 1
- Additional complexity: must track which arrays to return to pool
- Risk of pool exhaustion or memory leaks if return paths are missed

### Risks
1. **Memory leaks**: If any code path forgets to return the rented array
2. **Over-allocation**: `ArrayPool.Rent()` rounds up to power-of-2 sizes
3. **Complexity**: More moving parts than Candidate 1

### Files
Same as Candidate 1, plus `VmState.cs` for cleanup logic.

### Benchmark plan
Same as Candidate 1.

---

## Candidate 3: Change ReturnData from object to struct-based discriminated union

### Change
Replace the `object ReturnData` property with a value-type discriminated union
that avoids boxing and enables `ReadOnlyMemory<byte>` without heap allocation:

```csharp
[StructLayout(LayoutKind.Auto)]
struct ReturnDataUnion
{
    public enum Kind : byte { None, Memory, State, EofCode }
    public Kind Tag;
    public ReadOnlyMemory<byte> MemoryData;
    public VmState<TGasPolicy> StateData;  // reference type, no boxing
    public EofCodeInfo EofData;             // reference type, no boxing
}
```

### Mechanism
Eliminates both the `.ToArray()` allocation AND the `object` boxing overhead
when storing `byte[]` in `ReturnData`. The current design boxes `byte[]` into
`object`, which the JIT can't devirtualize the type check.

### Expected impact
- **Allocation**: Same as Candidate 1, plus eliminates boxing
- **Branch prediction**: `switch(Tag)` is more predictable than `is` type checks
- **Estimated improvement**: 3-10% on nested call benchmarks
- Slightly better than Candidate 1 due to eliminated boxing and better JIT codegen

### Difficulty: L
- Requires generic type parameter propagation for `VmState<TGasPolicy>`
- Larger refactor of all `ReturnData` access sites
- More testing surface

### Risks
1. Same buffer lifetime risks as Candidate 1
2. Larger diff, more review burden
3. The struct may be large (~40 bytes), could affect stack frame size

### Files
Same as Candidate 1, plus all files that read `ReturnData`.

### Benchmark plan
Same as Candidate 1.

---

## Ranking (by ROI)

| Rank | Candidate | Impact | Difficulty | ROI |
|------|-----------|--------|------------|-----|
| 1 | **Candidate 1**: ReadOnlyMemory passthrough | 5-15% GC, 2-5% speed | M | **Best** |
| 2 | **Candidate 2**: ArrayPool rental | 3-8% GC, 1-3% speed | M | Medium |
| 3 | **Candidate 3**: Struct discriminated union | 3-10% GC, 3-5% speed | L | Lower (high effort) |

**Recommendation**: Start with Candidate 1. It's the simplest change, eliminates
the allocation entirely (not just pooling it), and has the best risk/reward ratio.
If buffer lifetime proves too risky, fall back to Candidate 2.
