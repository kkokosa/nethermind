# Research Brief: EVM-1 — PopAddress() allocates via ToArray() on every CALL

## Target

**EVM-1**: `EvmStack.PopAddress()` calls `.ToArray()` to create a `byte[20]` on every
address-consuming opcode (CALL, STATICCALL, DELEGATECALL, CALLCODE, BALANCE,
EXTCODESIZE, EXTCODECOPY, EXTCODEHASH, SELFDESTRUCT).

**Claimed fix**: "remove `.ToArray()`, pass span directly" — but this is **misleading**.

## Critical Finding: The Naive Fix Is a No-Op

The optimization target description says `Address` already has a `ReadOnlySpan<byte>`
constructor (`Address.cs:141`), so `.ToArray()` is pure waste.

**This is wrong.** The `Address(ReadOnlySpan<byte>)` constructor at line 141 does:

```csharp
// Address.cs:150
Bytes = bytes.ToArray();  // ALWAYS allocates byte[20]
```

And the current code path through `Address(byte[])` at line 127 does:

```csharp
Bytes = bytes;  // stores array directly — no copy
```

So the current `PopAddress()` code allocates **one** `byte[20]` via `.ToArray()` and
passes it to `Address(byte[])` which stores it directly. Switching to pass the span
to `Address(ReadOnlySpan<byte>)` would still allocate **one** `byte[20]` — just inside
the constructor instead. **Zero net allocation difference.**

The `byte[20]` allocation is structurally mandatory because `Address` is a `sealed class`
with `public byte[] Bytes { get; }` — it must own heap-allocated bytes.

## Current Implementation

### EvmStack.cs:467-479

```csharp
public Address? PopAddress()
    => Head-- == 0
        ? null
        : new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());

public bool PopAddress(out Address address)  // DEAD CODE — zero callers
{
    if (Head-- == 0) { address = null; return false; }
    address = new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());
    return true;
}
```

### Address.cs — Internal Storage

```csharp
public sealed class Address : IEquatable<Address>, IComparable<Address>
{
    public byte[] Bytes { get; }  // always a byte[20] on the heap

    public Address(byte[] bytes) { Bytes = bytes; }              // no copy
    public Address(ReadOnlySpan<byte> bytes) { Bytes = bytes.ToArray(); } // copies
}
```

### AddressStructRef — Exists But Unusable Here

`Address.cs:299` defines `ref struct AddressStructRef` wrapping `ReadOnlySpan<byte>` —
zero allocation. But it cannot be stored on the heap, so it cannot be used in any
caller that passes the address to `IWorldState`, `ICodeInfoRepository`, `ITxTracer`,
or stores it in `ExecutionEnvironment`.

## Call Graph

All 7 call sites use the `Address? PopAddress()` overload:

| File:Line | Opcode | Address Lifetime | Hot? |
|-----------|--------|-----------------|------|
| `EvmInstructions.Call.cs:109` | CALL/STATICCALL/DELEGATECALL | **Stored** in `ExecutionEnvironment` (heap) | YES — most frequent |
| `EvmInstructions.CodeCopy.cs:147` | EXTCODECOPY | Transient — passed to `GetCachedCodeInfo`, `ConsumeAccountAccessGas` | Moderate |
| `EvmInstructions.CodeCopy.cs:237` | EXTCODESIZE | Transient — passed to `IsContract`, `GetCachedCodeInfo` | Moderate |
| `EvmInstructions.ControlFlow.cs:226` | SELFDESTRUCT | Transient — passed to `AddToBalance`, `CreateAccount` | Low |
| `EvmInstructions.Environment.cs:556` | BALANCE | Transient — passed to `GetBalance` | Moderate |
| `EvmInstructions.Environment.cs:620` | EXTCODEHASH | Transient — passed to `IsDeadAccount`, `GetCodeHash` | Moderate |
| `EvmInstructions.Environment.cs:668` | EXTCODEHASH (EOF) | Transient — passed to `IsDeadAccount`, `GetCode`, `GetCodeHash` | Low |

**Hot path**: CALL variants dominate. A DeFi block can have 1000+ CALL opcodes.

**None convertible to AddressStructRef** without changing downstream interfaces:
`IWorldState`, `IReadOnlyStateProvider`, `ICodeInfoRepository`, `ITxTracer`,
`StackAccessTracker`, all gas policy methods — all accept `Address` (a class).

The CALL path is additionally blocked because `codeSource`/`target` are stored into
the pooled heap-allocated `ExecutionEnvironment` object.

## Baseline Benchmark

**No dedicated PopAddress benchmark exists.** The existing `EvmStackBenchmarks.cs` covers
push/pop for UInt256, byte, zero, one, swap, dup — but not PopAddress. It also lacks
`[MemoryDiagnoser]`.

`EvmOpcodesBenchmark.cs` covers CALL opcodes indirectly but without allocation tracking.

## Prior Art — Reth and Geth

### Reth (Rust)
- Stack stores `U256` values (256-bit fixed-size structs on the stack)
- Address is `B160` / `Address` — a fixed-size `[u8; 20]` value type, stack-allocated
- No heap allocation for address operations at all
- Conversion from U256 → Address is a truncation + copy of 20 bytes, all on the stack

### Geth (Go)
- Stack stores `uint256.Int` from `holiman/uint256` (256-bit struct)
- Address is `common.Address` — a fixed-size `[20]byte` value type
- Conversion: `common.Address(addr.Bytes20())` — copies 20 bytes into fixed array
- Stack reuses `[]uint256.Int` via `sync.Pool`
- No heap allocation for address extraction

**Key insight**: Both competing clients use **fixed-size value types** for addresses.
Nethermind uses a `sealed class` with a `byte[]` field — fundamentally requires heap
allocation. This is a deeper architectural difference.

## Blast Radius

| Change | Impact |
|--------|--------|
| Remove `.ToArray()` from PopAddress only | Zero — Address(span) copies internally |
| Add address caching to PopAddress | Low blast radius — contained in EvmStack.cs |
| Change Address to value type | **MASSIVE** — Address is used in 1000+ files |
| Add span overloads to IWorldState etc. | Large — public interface changes |

## EIP-2929 Warm Set — Missed Reuse Opportunity

`StackAccessTracker.AccessedAddresses` (`JournalSet<Address>`) already holds a
deduplicated set of Address objects per transaction. When BALANCE pops address X,
the warm set likely already contains an Address object for X. But PopAddress allocates
a new one regardless.

## KeccakCache Pattern — Proven Model

`Nethermind.Core/Crypto/KeccakCache.cs` implements a 128k-entry, lock-free (seqlock)
cache for Keccak-256 results. It already has a special fast path for 20-byte inputs
(address-sized). This pattern could be adapted for an AddressCache.
