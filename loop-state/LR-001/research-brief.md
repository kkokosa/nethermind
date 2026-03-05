# Research Brief: EVM-1

## Target -- PopAddress() allocates via ToArray() on every CALL

**Summary**: `EvmStack.PopAddress()` calls `.ToArray()` on a `Span<byte>` slice, allocating a 20-byte `byte[]` on the heap for every address-consuming opcode (CALL, DELEGATECALL, STATICCALL, CALLCODE, BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH, SELFDESTRUCT).

## Current Implementation

### PopAddress() -- EvmStack.cs:467,477

Two overloads, both allocate:

```csharp
// EvmStack.cs:467
public Address? PopAddress() => Head-- == 0 ? null
    : new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());

// EvmStack.cs:469-478
public bool PopAddress(out Address address) {
    if (Head-- == 0) { address = null; return false; }
    address = new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());
    return true;
}
```

### Address constructor -- Address.cs:127-139, 141-151

**Critical finding**: Even the `ReadOnlySpan<byte>` constructor allocates:

```csharp
// Address.cs:127 -- byte[] constructor (stores directly)
public Address(byte[] bytes) { ...; Bytes = bytes; }

// Address.cs:141 -- ReadOnlySpan<byte> constructor (ALSO allocates)
public Address(ReadOnlySpan<byte> bytes) { ...; Bytes = bytes.ToArray(); }
```

`Address` is a **sealed class** with `byte[] Bytes` property. Every `Address` instance requires a heap-allocated 20-byte array. This is fundamental -- removing `.ToArray()` from `PopAddress()` just moves the allocation into the constructor.

### Allocation cost per call

Each `PopAddress()` allocates:
1. **20-byte `byte[]`** (actual: 24 bytes with array header + 8 bytes object overhead on 64-bit = ~48 bytes GC pressure)
2. **Address object** (~72 bytes including vtable pointer, sync block, byte[] reference)
3. **Total**: ~120 bytes of GC pressure per address-consuming opcode

## Call Graph

### Hot callers (per-opcode, thousands per block):

| File | Line | Opcode | Pattern |
|------|------|--------|---------|
| `EvmInstructions.Call.cs` | 109 | CALL/DELEGATECALL/STATICCALL/CALLCODE | **Stored** in `ExecutionEnvironment` (long-lived) |
| `EvmInstructions.Environment.cs` | 556 | BALANCE | Transient -- `GetBalance(address)` then discarded |
| `EvmInstructions.Environment.cs` | 620 | EXTCODEHASH | Transient -- `GetCodeHash(address)` then discarded |
| `EvmInstructions.Environment.cs` | 668 | EXTCODEHASH (EOF) | Transient -- `GetCode(address)` then discarded |
| `EvmInstructions.CodeCopy.cs` | 147 | EXTCODECOPY | Transient -- code lookup then discarded |
| `EvmInstructions.CodeCopy.cs` | 237 | EXTCODESIZE | Transient -- size lookup then discarded |
| `EvmInstructions.ControlFlow.cs` | 226 | SELFDESTRUCT | Transient -- balance transfer then discarded |

### Key insight: 6 of 7 call sites are transient

Only the CALL family (EvmInstructions.Call.cs:109) stores the Address long-term in `ExecutionEnvironment`. The other 6 sites use it for immediate lookups via `IWorldState` and discard it.

### Cold callers (none)

`PopAddress()` is only called from EVM opcode implementations.

## Baseline Benchmark

**No dedicated PopAddress benchmark exists.**

- `EvmStackBenchmarks.cs` covers Push/Pop for UInt256, Byte, Zero, One, Swap, Dup -- but NOT Address.
- `EvmOpcodesBenchmark.cs` indirectly covers it via opcode dispatch, but doesn't isolate allocation cost.
- Neither benchmark uses `[MemoryDiagnoser]`.

A new benchmark must be created to measure the allocation before/after.

## Prior Art -- Reth/Geth

### Reth (Rust, via revm)

- `Address` = `FixedBytes<20>` = `[u8; 20]` -- a **value type** (stack-allocated, Copy trait)
- Pop from stack: `U256` popped by value, then `to.into_address()` extracts low 20 bytes
- **Zero heap allocation** per address pop

### Geth (Go, go-ethereum)

- `common.Address` = `[20]byte` -- a **value type** (fixed-size array, stack-allocated)
- Pop from stack: `uint256.Int` popped by value, then `common.Address(addr.Bytes20())` extracts bytes
- **Zero heap allocation** per address pop

### Structural difference

Both Reth and Geth use value-type addresses. Nethermind's `Address` is a sealed class (reference type) with a `byte[]` field, which **fundamentally requires heap allocation**. This is a deeper architectural issue than just removing `.ToArray()`.

## Blast Radius

### What changes if we modify PopAddress

**Minimal change** (remove `.ToArray()` in PopAddress, pass span to Address constructor):
- Zero benefit -- Address.cs:150 does `bytes.ToArray()` internally
- No API change needed

**Medium change** (address caching/interning for warm addresses):
- Contained within `EvmStack.cs` + possibly `StackAccessTracker`
- No interface changes
- Risk: cache lookup overhead may exceed allocation savings

**Large change** (value-type address for transient uses):
- Would require `IWorldState` methods to accept `AddressStructRef` or `ReadOnlySpan<byte>`
- `AddressStructRef` already exists (Address.cs:299) but is a `ref struct` -- cannot cross interface boundaries
- Blast radius: all `IWorldState` implementations, all state providers
- **Too large for this target**

### Consensus risk

- Low. Address is just a 20-byte identifier. Changing how it's allocated doesn't affect semantics.
- Must ensure `Address.Equals()` still works correctly (it compares bytes, so this is safe).
