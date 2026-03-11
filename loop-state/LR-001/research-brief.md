# Research Brief: EVM-1

## Target — PopAddress() allocates via ToArray() on every CALL

**Optimization target**: `EvmStack.PopAddress()` at `EvmStack.cs:467,477` creates a 20-byte
heap allocation on every address-consuming opcode (CALL, DELEGATECALL, STATICCALL, CALLCODE,
BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH, SELFDESTRUCT).

```csharp
// EvmStack.cs:467
public Address? PopAddress() => Head-- == 0 ? null :
    new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());

// EvmStack.cs:469-478
public bool PopAddress(out Address address) {
    if (Head-- == 0) { address = null; return false; }
    address = new Address(_bytes.Slice(Head * WordSize + WordSize - AddressSize, AddressSize).ToArray());
    return true;
}
```

## Current Implementation — How It Works

### PopAddress flow

1. Decrement `Head` (stack pointer) — `EvmStack.cs:467`
2. Slice 20 bytes from the 32-byte stack word (right-aligned) — `EvmStack.cs:467`
3. Call `.ToArray()` on the span → **allocates 20-byte `byte[]` on heap**
4. Pass `byte[]` to `Address(byte[])` constructor → **allocates Address object (~40 bytes)**
5. Total per call: ~80 bytes heap (20B array + object overhead + Address object)

### Address class internals

`Address` is a **sealed class** (`Address.cs:23`) with `public byte[] Bytes { get; }` (`Address.cs:36`).
It **must own a byte array** — the class stores `byte[]` directly, not a span.

**Critical finding**: The `Address(ReadOnlySpan<byte>)` constructor at `Address.cs:141-151` also
calls `.ToArray()` internally:
```csharp
// Address.cs:141-151
public Address(ReadOnlySpan<byte> bytes) {
    if (bytes.Length != Size) throw ...;
    Bytes = bytes.ToArray();  // line 150 — STILL ALLOCATES
}
```

**Therefore, removing `.ToArray()` from PopAddress and passing a span saves ZERO allocations.**
The target description's claim that "Address already has a ReadOnlySpan<byte> constructor, so
.ToArray() is pure waste" is **incorrect** — the constructor calls `.ToArray()` internally.

## Call Graph — Callers of PopAddress

### Hot-path callers (block processing — per opcode)

| Opcode | File:Line | Caller method |
|--------|-----------|---------------|
| CALL | `EvmInstructions.Call.cs:109` | `InstructionCall<>()` |
| DELEGATECALL | Same via `TOpCall` generic | `InstructionCall<>()` |
| STATICCALL | Same via `TOpCall` generic | `InstructionCall<>()` |
| CALLCODE | Same via `TOpCall` generic | `InstructionCall<>()` |
| BALANCE | `EvmInstructions.Environment.cs:556` | `InstructionBalance<>()` |
| EXTCODEHASH | `EvmInstructions.Environment.cs:620` | `InstructionExtCodeHash<>()` |
| EXTCODEHASH (EOF) | `EvmInstructions.Environment.cs:668` | `InstructionExtCodeHashEof<>()` |
| EXTCODECOPY | `EvmInstructions.CodeCopy.cs:147` | `InstructionExtCodeCopy<>()` |
| EXTCODESIZE | `EvmInstructions.CodeCopy.cs:237` | `InstructionExtCodeSize<>()` |
| SELFDESTRUCT | `EvmInstructions.ControlFlow.cs:226` | `InstructionSelfDestruct<>()` |

### What callers do with the Address

Every caller:
1. Creates `Address` via `PopAddress()`
2. Passes it to `ConsumeAccountAccessGas(... address)` which calls `accessTracker.WarmUp(address)`
3. Passes it to state methods: `GetBalance(address)`, `GetCodeHash(address)`, `IsDeadAccount(address)`, etc.
4. In CALL: also passes to `TryGetDelegation(codeSource, ...)`, frame creation

All downstream APIs accept `Address` (a sealed class), not spans. The `Address` object is stored
in the `JournalSet<Address>` (warm set) via `StackAccessTracker.WarmUp()` at
`StackAccessTracker.cs:34-35`.

### Cold callers

None — `PopAddress()` is only called from EVM opcode handlers.

## Baseline Benchmark — None Exists

The `EvmStackBenchmarks.cs` covers `PushUInt256`/`PopUInt256`, `PushByte`/`PopByte`, `PushZero`,
`PushOne`, `Swap`, `Dup` — but **not** `PopAddress`. No `[MemoryDiagnoser]` attribute.

The `EvmOpcodesBenchmark` exercises CALL/BALANCE/etc. opcodes end-to-end, which indirectly
includes PopAddress, but does **not** have `[MemoryDiagnoser]` and cannot isolate PopAddress cost.

**A new dedicated benchmark is needed** to measure PopAddress allocation overhead.

## Prior Art — Reth/Geth Approach

### Reth (Rust)
Rust's `Address` is `[u8; 20]` — a fixed-size value type on the stack. No heap allocation for
address operations. The EVM stack pops addresses by copying 20 bytes to a stack-local array.
Zero allocations.

### Geth (Go)
Go's `common.Address` is `[20]byte` — a value type. Popping from the EVM stack copies into a
stack-local `Address`. GC pressure is minimal since Go uses escape analysis; if the address
doesn't escape the function, it stays on the stack.

### Key insight
Both Reth and Geth avoid allocations because their `Address` types are value types (fixed-size
arrays). Nethermind's `Address` is a sealed class holding `byte[]`, which requires heap allocation.
The `AddressStructRef` ref struct exists but can't be used across async boundaries or stored
in collections.

## Blast Radius — What Changes If We Modify This

### If changing PopAddress only (removing .ToArray())
- **Impact: NONE** — same allocation moves into Address constructor
- **Blast radius: Zero** — safe but useless

### If adding address caching/interning
- **EvmStack.cs**: Add cache lookup before Address construction
- **Potential cache location**: Per-transaction or per-block, keyed by 20-byte content
- **Risk**: Cache lookup overhead for cold addresses; memory management
- **Interfaces affected**: None — transparent to callers

### If adding span-based overloads to state APIs
- **IWorldState**: Add `GetBalance(ReadOnlySpan<byte>)`, etc.
- **StateProvider.cs**: Add span-keyed cache lookup path
- **EthereumGasPolicy.cs**: Add span-based `ConsumeAccountAccessGas`
- **StackAccessTracker.cs**: Add span-based `WarmUp` and `IsCold`
- **Blast radius: LARGE** — touches State, Evm, and Core modules
- **Consensus risk: Low** — read-only lookups, same results

### If changing Address to struct
- **Blast radius: ENORMOUS** — Address is used in >500 files across the entire codebase
- **Not feasible** without major refactor
