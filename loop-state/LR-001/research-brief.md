# Research Brief: EVM-1

## Target — PopAddress() allocates via ToArray() on every CALL

**File**: `src/Nethermind/Nethermind.Evm/EvmStack.cs:467,477`

The EVM stack's `PopAddress()` method creates a new `Address` object on every call,
which involves a 20-byte heap allocation from `.ToArray()`.

## Current Implementation — How it works

### PopAddress (two overloads)

```csharp
// EvmStack.cs:467 — nullable return overload
public Address? PopAddress()
    => Head-- == 0 ? null : new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());

// EvmStack.cs:469-479 — bool return overload
public bool PopAddress(out Address address)
{
    if (Head-- == 0) { address = null; return false; }
    address = new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());
    return true;
}
```

### Address constructors (Address.cs)

```csharp
// Address.cs:127-139 — byte[] constructor (stores directly, no copy)
public Address(byte[] bytes) { Bytes = bytes; }

// Address.cs:141-151 — ReadOnlySpan<byte> constructor (ALSO calls .ToArray()!)
public Address(ReadOnlySpan<byte> bytes) { Bytes = bytes.ToArray(); }
```

**Critical finding**: The optimization target description claims "Address already has a
ReadOnlySpan<byte> constructor, so .ToArray() is pure waste." This is **misleading**.
Both paths produce exactly one 20-byte allocation:

- Current: `Span.ToArray()` → `Address(byte[])` → stores array directly = 1 allocation
- Span path: `Span` → `Address(ReadOnlySpan<byte>)` → internal `.ToArray()` = 1 allocation

Removing `.ToArray()` from PopAddress and passing the span would produce identical
allocation behavior. The `.ToArray()` is not "pure waste" — it's just done in a
different place.

### Why Address requires byte[] (the real constraint)

`Address` is a **sealed class** with `public byte[] Bytes { get; }` (Address.cs:36).
It must own a `byte[]` because:

1. Address objects are stored long-term in `ExecutionEnvironment`, `StackAccessTracker`,
   `JournalSet<Address>`, state caches, etc.
2. The EVM stack's `_bytes` span is reused across operations — the address data would
   be overwritten on the next stack push.
3. Multiple consumers (state lookups, gas tracking, tracing) may reference the same
   Address concurrently.

## Call Graph — Callers, hot-path marked

### Hot-path callers (block processing)

| Opcode | File:Line | Frequency |
|--------|-----------|-----------|
| **CALL/DELEGATECALL/STATICCALL/CALLCODE** | `EvmInstructions.Call.cs:109` | Every external call — most frequent |
| **BALANCE** | `EvmInstructions.Environment.cs:556` | Per BALANCE opcode |
| **EXTCODEHASH** | `EvmInstructions.Environment.cs:620,668` | Per EXTCODEHASH opcode |
| **EXTCODESIZE** | `EvmInstructions.CodeCopy.cs:237` | Per EXTCODESIZE opcode |
| **EXTCODECOPY** | `EvmInstructions.CodeCopy.cs:147` | Per EXTCODECOPY opcode |
| **SELFDESTRUCT** | `EvmInstructions.ControlFlow.cs:226` | Per SELFDESTRUCT opcode |

### Address object lifetime analysis

| Usage pattern | Opcodes | Lifetime |
|---------------|---------|----------|
| Consumed immediately, discarded | BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH | ~microseconds |
| Stored in ExecutionEnvironment (pooled) | CALL, DELEGATECALL, STATICCALL, CALLCODE | Duration of call frame |
| Stored in AccessTracker journal set | All above (for warm/cold tracking) | Transaction lifetime |
| Passed to SELFDESTRUCT journal | SELFDESTRUCT | Transaction lifetime |

**Key insight**: Most Address objects from PopAddress are short-lived — consumed within
a single instruction execution. However, CALL-family opcodes store the Address in
`ExecutionEnvironment` for the call frame duration, and all opcodes may add the
address to `AccessTracker.AccessedAddresses` (a `JournalSet<Address>` using
value-based equality).

## Baseline Benchmark — None exists for PopAddress specifically

- `EvmStackBenchmarks.cs` covers Push/Pop for UInt256, Byte, PushZero, PushOne, Swap, Dup
  but **not** PopAddress
- `EvmOpcodesBenchmark.cs` covers all opcodes including CALL/BALANCE indirectly but
  **without [MemoryDiagnoser]**, so allocations are not tracked
- No isolated PopAddress allocation benchmark exists

## Prior Art — Geth/Reth approach

### Geth (Go)
- `common.Address` is `type Address [20]byte` — a **value type** (fixed-size array)
- Popping from stack: `addr := common.Address(stack.pop().Bytes20())` — zero heap allocation
- Go's value semantics mean Address is stack-allocated and copied by value

### Reth/revm (Rust)
- `Address` is `FixedBytes<20>` from alloy-primitives — a **value type**
- Stack pop returns value directly — zero heap allocation
- Rust's ownership model ensures no GC pressure

### Nethermind (C#)
- `Address` is a **sealed class** (reference type) — always heap-allocated
- Every PopAddress creates a new object + 20-byte array
- Object header overhead: ~16 bytes per Address object + 16 bytes array overhead + 20 bytes data = ~52 bytes per pop

**The fundamental gap**: Nethermind uses a reference type where competing implementations
use value types. The `.ToArray()` removal is cosmetic — the real issue is that `Address`
is a class, not a struct.

## Blast Radius — What changes if we modify this

### Approach 1: Just remove .ToArray() (cosmetic)
- **Changes**: EvmStack.cs only (2 lines)
- **Blast radius**: Zero — functionally identical
- **Impact**: Zero — allocation count unchanged

### Approach 2: Address caching/interning in PopAddress
- **Changes**: EvmStack.cs, possibly new AddressCache class
- **Blast radius**: Low — internal to EVM
- **Risks**: Cache invalidation, memory growth, thread safety
- **Impact**: Moderate — reduces allocations for repeated addresses (common in DeFi)

### Approach 3: Convert Address to a value type (struct)
- **Changes**: Address.cs + **hundreds of files** across the entire codebase
- **Blast radius**: Extreme — Address is used everywhere (state, trie, network, RPC, etc.)
- **Risks**: Breaking change, nullable semantics change (`Address?` → `Address` with default),
  equality semantics, boxing in collections, copy semantics
- **Impact**: High — eliminates all Address heap allocations
- **Difficulty**: L — multi-week effort, high risk of regressions

### Approach 4: Use AddressStructRef in hot paths
- **Changes**: Opcode instruction files, state lookup methods
- **Blast radius**: Medium — requires state APIs to accept `ReadOnlySpan<byte>` or `AddressStructRef`
- **Risks**: ref struct lifetime constraints, can't store in fields/collections
- **Impact**: High for short-lived patterns (BALANCE, EXTCODESIZE), none for CALL
- **Difficulty**: M-L — requires API changes through state layer

### Consensus correctness
- None of these approaches affect consensus — Address is a data carrier, not logic.
- The EVM pops the same 20 bytes regardless of how they're wrapped.
