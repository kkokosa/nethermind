# Research Brief: EVM-1

## Target -- PopAddress() allocates via ToArray() on every CALL

### Summary

`EvmStack.PopAddress()` creates two heap allocations on every address-consuming EVM opcode:
a `byte[20]` from `.ToArray()` and an `Address` class instance. This affects CALL,
DELEGATECALL, STATICCALL, CALLCODE, BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH,
and SELFDESTRUCT -- thousands of invocations per block.

---

## Current Implementation

**File**: `src/Nethermind/Nethermind.Evm/EvmStack.cs`

Two overloads at lines 467 and 469-478:

```csharp
// Line 467 - nullable return
public Address? PopAddress() => Head-- == 0 ? null
    : new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());

// Lines 469-478 - try pattern
public bool PopAddress(out Address address)
{
    if (Head-- == 0) { address = null; return false; }
    address = new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());
    return true;
}
```

The `Address` class (`src/Nethermind/Nethermind.Core/Address.cs`) is a `sealed class` wrapping `byte[] Bytes`:

- Constructor `Address(byte[])` (line 127): stores the array directly, no copy
- Constructor `Address(ReadOnlySpan<byte>)` (line 141): calls `.ToArray()` internally (line 150)

**Key insight**: Removing `.ToArray()` from PopAddress and using the span constructor
would NOT reduce allocations -- the constructor itself does `.ToArray()`. The `byte[20]`
is the backing store for `Address.Bytes`, so one allocation is inherently required
as long as `Address` remains a class with `byte[]` backing.

---

## Call Graph

All 7 call sites are on the **hot path** (EVM opcode execution during block processing):

| File | Method | Opcode(s) | Line |
|------|--------|-----------|------|
| `Instructions/EvmInstructions.Call.cs` | `InstructionCall` | CALL/DELEGATECALL/STATICCALL/CALLCODE | 109 |
| `Instructions/EvmInstructions.ControlFlow.cs` | `InstructionSelfDestruct` | SELFDESTRUCT | 226 |
| `Instructions/EvmInstructions.Environment.cs` | `InstructionBalance` | BALANCE | 556 |
| `Instructions/EvmInstructions.Environment.cs` | `InstructionExtCodeHash` | EXTCODEHASH | 620 |
| `Instructions/EvmInstructions.Environment.cs` | `InstructionExtCodeHashEof` | EXTCODEHASH (EOF) | 668 |
| `Instructions/EvmInstructions.CodeCopy.cs` | `InstructionExtCodeCopy` | EXTCODECOPY | 147 |
| `Instructions/EvmInstructions.CodeCopy.cs` | `InstructionExtCodeSize` | EXTCODESIZE | 237 |

**No cold-path callers** -- PopAddress is used exclusively in EVM opcode implementations.

### Downstream usage pattern

After PopAddress, the `Address` object is used for:
1. **EIP-2929 warm/cold tracking**: `StackAccessTracker.WarmUp(Address)` stores it in `JournalSet<Address>`
2. **Code lookups**: `CodeInfoRepository.GetCachedCodeInfo(Address, spec)` -- dictionary lookup by AddressAsKey
3. **State queries**: `IWorldState.AccountExists(Address)`, `GetBalance(Address)`, etc.
4. **Call frame storage**: Stored in `ExecutionEnvironment` (pooled) for duration of call frame

The Address is NOT stored long-term -- it lives for the duration of one opcode or call frame.

---

## Baseline Benchmark

**Status**: Could not run benchmarks -- NuGet restore hangs in this environment.

**Existing benchmarks**:
- `EvmStackBenchmarks.cs`: Tests Push/Pop for UInt256, Byte, Zero, One, Swap, Dup. Does NOT test PopAddress.
- `EvmOpcodesBenchmark.cs`: Tests all opcodes including CALL/BALANCE/EXTCODE*. No `[MemoryDiagnoser]`.

**Gap**: No dedicated PopAddress allocation benchmark exists. The EvmOpcodesBenchmark would
show aggregate timing but not isolate PopAddress allocation overhead.

---

## Prior Art -- Competing Implementations

### Reth (revm, Rust)
- `Address` is `struct Address(FixedBytes<20>)` -- 20-byte value type, `Copy` trait
- Stack stores `U256` values (also stack-allocated `[u64; 4]`)
- Popping an address: `U256::into_address()` -> value copy, **zero heap allocations**

### Geth (go-ethereum, Go)
- `common.Address` is `type Address [20]byte` -- fixed-size value type
- Popping: `slot.Bytes20()` returns `[20]byte`, cast to Address, **zero heap allocations**

### Nethermind vs competitors
| Client | Address type | Allocs per pop |
|--------|-------------|---------------|
| revm | struct, Copy | **0** |
| geth | [20]byte | **0** |
| Nethermind | sealed class + byte[] | **2** (byte[20] + Address object) |

Both competitors use value types, avoiding all GC pressure on this hot path.

---

## Blast Radius

### What would change

The `Address` class is used **pervasively** across the entire codebase. Changing it to
a struct would be an L-difficulty, codebase-wide change affecting hundreds of files.

However, **targeted optimizations within PopAddress and its callers** have limited blast radius:

1. **EvmStack.cs** -- PopAddress methods (2 overloads)
2. **7 opcode instruction files** -- callers listed above
3. **Address.cs** -- potentially add a constructor or factory method
4. **IWorldState / ICodeInfoRepository** -- only if we change lookup signatures

### Consensus safety

- Address equality uses `Vector128 + uint` comparison (`Address.Equals`, line 166-173)
- As long as the 20 bytes are identical, consensus is preserved
- No behavioral change if we just change how the `byte[20]` is obtained

### Interface changes

- If using `ReadOnlySpan<byte>` deferred materialization: would require new overloads on
  `IWorldState`, `ICodeInfoRepository`, `StackAccessTracker` -- **M difficulty**
- If staying with `Address` class but reducing allocations: no interface changes -- **S difficulty**

---

## Additional Notes

- `AddressStructRef` (ref struct with `ReadOnlySpan<byte>`) exists at `Address.cs:299`
  but is NOT used in any EVM hot paths
- `ExecutionEnvironment` is pooled (`ConcurrentQueue<ExecutionEnvironment>`) but the
  Address objects stored within are not reused
- No address interning, caching, or pooling exists in the codebase
