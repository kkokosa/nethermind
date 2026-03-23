# Nethermind Performance Architecture

This document maps the performance-critical architecture of Nethermind.
It covers module dependencies, the block processing pipeline, EVM execution,
state/trie internals, and key data structures — everything needed to identify
and attack optimization targets.

---

## 1. Module Dependency Graph

Dependencies flow bottom-up. Lower modules are foundational (few deps, high reuse);
higher modules orchestrate more subsystems. Performance work should target the
lowest module that owns the hot path.

```
L0  Nethermind.Logging                         (no deps)
     │
L1  Nethermind.Core ─────────────────────────── Nethermind.Serialization.Rlp
     │                                            │
L2  Nethermind.Crypto    Nethermind.Config      Nethermind.Specs
     │                    │                       │
L3  Nethermind.Db ────── Nethermind.Trie         Nethermind.Db.Rocks
     │                    │
L4  Nethermind.Evm ────────────────────────────  Nethermind.Evm.Precompiles
     │                                            │
L5  Nethermind.State ─── Nethermind.TxPool
     │                    │
L6  Nethermind.Blockchain ───────────────────── (hub: 9 project refs)
     │
L7  Nethermind.Consensus  Nethermind.Network    Nethermind.Synchronization
     │                     │
L8  Nethermind.Facade     Nethermind.JsonRpc
```

### Direct references (perf-critical modules only)

| Module | References |
|--------|-----------|
| **Core** | Logging |
| **Serialization.Rlp** | Core |
| **Crypto** | Core, Serialization.Rlp |
| **Db** | Config, Serialization.Rlp |
| **Trie** | Core, Db, Serialization.Rlp |
| **Evm** | Core, Crypto, Serialization.Rlp, Specs |
| **Evm.Precompiles** | Core, Evm, Crypto, Serialization.Rlp, Specs |
| **State** | Core, Db, Serialization.Rlp, Trie, Evm |
| **TxPool** | Config, Core, Crypto, Db, Evm, State |
| **Blockchain** | Abi, Core, Db, Evm, Evm.Precompiles, State, TxPool, Specs |
| **Consensus** | Blockchain, Config, Core, Crypto, Evm, TxPool |

### Performance-critical dependency chains

```
Transaction execution:  Consensus → Blockchain → TxPool → State → Trie → Db
Contract execution:     Evm → State → Trie → Db
RLP hot path:           Serialization.Rlp → Core
```

---

## 2. Block Processing Pipeline

From network receipt to state commit. Each stage shows the key class, file, and
methods on the hot path.

### Flow diagram

```
Eth62ProtocolHandler.HandleMessage()          ← P2P NewBlock message
  └─ SyncServer.AddNewBlock()                 ← Validate + broadcast
       ├─ BlockValidator.ValidateSuggestedBlock()
       └─ BlockTree.SuggestBlock()            ← Insert into chain
            └─ NewBestBlock event
                 │
BlockchainProcessor.Enqueue()                 ← Two-stage channel pipeline
  ├─ _recoveryQueue → RunRecovery()           ← Recover tx sender addresses
  └─ _blockQueue   → RunProcessing()          ← Main processing thread
       └─ Process()
            └─ PrepareProcessingBranch()      ← Trace to common ancestor
                 │
BranchProcessor.Process()                     ← Per-block loop
  ├─ BeginScope(parentStateRoot)
  └─ FOR each block:
       ├─ Prewarmer task (background)         ← Prefetch state
       ├─ BlockProcessor.ProcessOne()         ← Core execution
       │    ├─ PrepareBlockForProcessing()
       │    ├─ ProcessBlock()                 ← See detail below
       │    ├─ ValidateProcessedBlock()
       │    └─ StoreTxReceipts()
       ├─ PreCommitBlock() → CommitTree()     ← Persist trie to DB
       └─ (every 64 blocks: flush to DB, new scope)
```

### ProcessBlock() detail — the inner hot path

```
ProcessBlock()
  ├─ StoreBeaconRoot()                        ← EIP-4788
  ├─ ApplyBlockhashStateChanges()
  ├─ Commit(commitRoots: false)               ← Snapshot pre-tx state
  │
  ├─ BlockTransactionsExecutor.ProcessTransactions()
  │    └─ FOR each transaction:               ← Sequential (no tx parallelism)
  │         TransactionProcessor.Execute()
  │           ├─ CalculateIntrinsicGas()
  │           ├─ ValidateStatic() + ValidateSender()
  │           ├─ BuyGas() + IncrementNonce()
  │           ├─ Commit()                     ← Gas deduction snapshot
  │           ├─ ExecuteEvmCall()             ← EVM bytecode execution
  │           └─ PayFees()                    ← Refund + miner payment
  │
  ├─ Commit(commitRoots: false)
  ├─ CalculateBlooms()                        ← PARALLEL per receipt
  ├─ CalculateReceiptsRoot()
  ├─ ApplyMinerRewards()
  ├─ ProcessWithdrawals()
  ├─ ProcessExecutionRequests()
  ├─ Commit(commitRoots: true)                ← Full state commit
  ├─ RecalculateStateRoot()                   ← Merkle root computation
  └─ SetBlockHash()
```

### Key files

| Component | File | Key methods |
|-----------|------|-------------|
| Network receipt | `Nethermind.Network/.../Eth62ProtocolHandler.cs` | `HandleMessage()`, `Handle(NewBlockMessage)` |
| Sync server | `Nethermind.Synchronization/SyncServer.cs` | `AddNewBlock()`, `SyncBlock()` |
| Blockchain processor | `Nethermind.Consensus/Processing/BlockchainProcessor.cs` | `Enqueue()`, `RunProcessing()`, `Process()` |
| Branch processor | `Nethermind.Consensus/Processing/BranchProcessor.cs` | `Process()`, `PreCommitBlock()` |
| Block processor | `Nethermind.Consensus/Processing/BlockProcessor.cs` | `ProcessOne()`, `ProcessBlock()` |
| Transaction processor | `Nethermind.Evm/TransactionProcessing/TransactionProcessor.cs` | `Execute()`, `ExecuteCore()` |
| Block validator | `Nethermind.Consensus/Validators/BlockValidator.cs` | `ValidateSuggestedBlock()` |

### Performance characteristics

- **Two-stage pipeline**: Recovery queue (tx sender recovery) feeds processing queue (bounded at 2048 blocks)
- **Single-reader channels**: No lock contention on dequeue
- **Thread priority elevation**: Processing thread runs at highest OS priority
- **GC scheduling**: Background GC toggled based on queue load
- **Sequential transactions**: No intra-block tx parallelism (Ethereum execution model constraint)
- **Parallel blooms**: Receipt bloom filters computed in parallel
- **Background prewarming**: State access prefetch runs concurrently with processing
- **64-block flush interval**: Accumulated state flushed to DB periodically

---

## 3. EVM Execution Flow

### Entry point

```
EthereumVirtualMachine : VirtualMachine<EthereumGasPolicy>
```

`VirtualMachine<TGasPolicy>` is generic over gas policy — the `TGasPolicy` struct
is passed by ref through the entire call chain, enabling zero-allocation gas tracking
with no virtual dispatch.

**File**: `Nethermind.Evm/VirtualMachine.cs`

### Execution architecture

```
ExecuteTransaction<TTracingInst>()            ← Main entry, generic over tracing flag
  └─ while (true)                             ← Frame loop (iterative, not recursive)
       ├─ if precompile:
       │    ExecutePrecompile()
       │      └─ precompile.Run(callData, spec)
       │
       ├─ if regular EVM code:
       │    ExecuteCall<TTracingInst>()
       │      └─ RunByteCode<TTracingInst, TCancelable>()
       │           └─ while (pc < code.Length)  ← Opcode dispatch loop
       │                ├─ fetch instruction byte
       │                ├─ if POP: inline         ← Most common opcode, special-cased
       │                ├─ else: _opcodeMethods[opcode](this, ref stack, ref gas, ref pc)
       │                │         ↑ function pointer dispatch via calli
       │                ├─ check gas
       │                └─ check for return/exception
       │
       ├─ if CallResult.IsReturn:
       │    ├─ top-level → return TransactionSubstate
       │    └─ nested   → pop parent frame, merge results
       │
       └─ if CallResult has StateToExecute:
            push current frame, continue with new frame
```

### Opcode dispatch mechanism

The EVM uses an **array of 256 unsafe function pointers** indexed by opcode byte:

```csharp
delegate*<VirtualMachine<TGasPolicy>, ref EvmStack, ref TGasPolicy, ref int, EvmExceptionType>[]
```

- **No virtual dispatch** — direct `calli` instruction
- **No switch statement** — array lookup is O(1) with no branch misprediction
- **PGO refresh**: Opcode table regenerated every 10k transactions (up to 500k) to benefit from profile-guided optimization

**File**: `Nethermind.Evm/VirtualMachine.Standard.cs` — `PrepareOpcodes<TTracingInst>()`

### Compile-time specialization

The `TTracingInst` generic parameter eliminates tracing overhead at compile time:
- When tracing is off, all `if (typeof(TTracingInst) == typeof(IsTracing))` branches are
  eliminated by the JIT
- Two cached opcode tables: `spec.EvmInstructionsNoTrace` and `spec.EvmInstructionsTraced`

### Call operations (CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2)

**File**: `Nethermind.Evm/Instructions/EvmInstructions.Call.cs` and `.Create.cs`

All call types are generic over `TOpCall` marker struct (OpCall, OpDelegateCall, etc.)
to eliminate runtime branching on call type.

Call flow:
1. Pop parameters from stack (gas, address, value, memory offsets)
2. Charge access gas (EIP-2929 warm/cold)
3. Charge value transfer + new account creation gas
4. Apply 63/64 rule for gas forwarding
5. Create new `VmState<TGasPolicy>` frame → return to main loop

CREATE flow adds:
1. Init code size validation (EIP-3860)
2. Address computation (nonce-based for CREATE, salt-based for CREATE2)
3. EOF rejection check

### Gas tracking

`TGasPolicy` is a struct (e.g., `EthereumGasPolicy`) passed by `ref` everywhere:
- `UpdateGas(ref gas, cost)` — charge, return false if OOG
- `UpdateMemoryCost(ref gas, loc, len, state)` — memory expansion
- `ConsumeAccountAccessGasWithDelegation()` — EIP-2929
- No allocation, no virtual calls — all inlined by JIT

### Key files

| Component | File |
|-----------|------|
| VM entry + frame loop | `Nethermind.Evm/VirtualMachine.cs` |
| Opcode generation | `Nethermind.Evm/VirtualMachine.Standard.cs` |
| Opcode implementations | `Nethermind.Evm/Instructions/EvmInstructions.*.cs` |
| EVM stack | `Nethermind.Evm/EvmStack.cs` |
| EVM memory | `Nethermind.Evm/EvmPooledMemory.cs` |
| Execution environment | `Nethermind.Evm/ExecutionEnvironment.cs` |
| VM state / call frames | `Nethermind.Evm/VmState.cs` |
| Instruction enum | `Nethermind.Evm/Instruction.cs` |
| Gas policy | `Nethermind.Evm/GasPolicy/EthereumGasPolicy.cs` |

### Existing EVM optimizations

| Optimization | Detail |
|-------------|--------|
| Function pointer dispatch | 256-element array, `calli` — no virtual call overhead |
| Inlined POP | Most frequent opcode handled inline in the dispatch loop |
| SIMD stack ops | `Vector256<byte>` for 32-byte push/pop, AVX2 byte shuffling for endianness |
| Compile-time tracing | `TTracingInst` generic eliminates tracing branches when not tracing |
| Pooled ExecutionEnvironment | `ConcurrentQueue<ExecutionEnvironment>` reuse pool |
| Pooled VmState | Frame objects rented/returned per call depth |
| Pooled EVM memory | `ArrayPool<byte>.Shared` for memory backing arrays |
| Struct gas policy | Zero-allocation gas tracking via generic struct |
| Unsafe pointer arithmetic | Stack operations use `Unsafe.Add` / `Unsafe.ReadUnaligned` |
| PGO-aware opcode refresh | Tables regenerated periodically to benefit from tiered JIT |

---

## 4. State and Trie Read/Write Paths

### Architecture overview

```
WorldState (facade)
  ├─ StateProvider          ← Account state (nonce, balance, code hash)
  │    └─ StateTree         ← Patricia trie for accounts
  ├─ PersistentStorageProvider ← Contract storage (per-address)
  │    └─ StorageTree[]     ← Patricia trie per contract
  ├─ TransientStorageProvider  ← EIP-1153 transient storage
  └─ IWorldStateScopeProvider  ← Scoping + trie persistence
```

**File**: `Nethermind.State/WorldState.cs`

### Account read path

```
WorldState.GetAccount(address)
  └─ StateProvider.GetThroughCache(address)
       ├─ _intraTxCache[address] hit?     ← O(1) Dictionary lookup
       │    └─ YES: return from change log
       │
       └─ NO: GetAndAddToCache(address)
            ├─ _blockChanges[address] hit? ← O(1) block-level cache
            └─ StateTree.Get(address)      ← Trie traversal
                 ├─ KeccakCache.Compute(address.Bytes)
                 └─ PatriciaTree.Get(nibbles)
                      └─ traverse Branch → Extension → Leaf
```

**Three cache levels** (cheapest to most expensive):
1. **Intra-tx cache** (`_intraTxCache`): Dictionary<AddressAsKey, StackList<int>> — change indices
2. **Block-level cache** (`_blockChanges`): Dictionary<AddressAsKey, ChangeTrace>
3. **Trie traversal**: PatriciaTree.Get → TrieNode resolution → DB read

### Account write path

```
WorldState.AddToBalance(address, amount) [or IncrementNonce, etc.]
  └─ StateProvider:
       GetThroughCache(address)           ← Load current value
       Account.WithChangedBalance(...)    ← Immutable: creates new Account
       PushUpdate(address, newAccount)    ← Append to change log
         ├─ _intraTxCache[address].Push(changeIndex)
         └─ _changes.Add(Change{address, account, Update})
```

Writes are **append-only** to a change log. The change log supports O(1) snapshot/restore
by recording stack positions.

### Storage read/write path

```
Read:  WorldState.Get(StorageCell{address, index})
         └─ PersistentStorageProvider.Get(cell)
              ├─ _intraBlockCache hit?
              └─ StorageTree.Get(index)
                   ├─ Lookup table for index < 1024  ← Avoids Keccak!
                   └─ PatriciaTree.Get(nibbles)

Write: WorldState.Set(StorageCell, value)
         └─ PersistentStorageProvider: append to change log
              └─ _originalValues[cell] recorded for EIP-1283 refunds
```

**Storage key optimization**: `StorageTree` maintains a **precomputed lookup table** of
Keccak hashes for storage indices 0–1023. Since >99% of storage accesses use low indices,
this eliminates Keccak hashing on the hot path.

**File**: `Nethermind.State/StorageTree.cs` — `CreateLookup()`, `ComputeKeyWithLookup()`

### Commit path (block finalization)

```
WorldState.Commit(spec, tracer, commitRoots=true)
  ├─ TransientStorageProvider.Commit()    ← Clear transient state
  ├─ PersistentStorageProvider.Commit()   ← Process storage changes
  │    ├─ Reverse-iterate change log
  │    ├─ Skip if value == original       ← No-op optimization
  │    ├─ SaveChange() to StorageTree
  │    └─ FlushToTree(writeBatch)
  ├─ StateProvider.Commit()               ← Process account changes
  │    ├─ Reverse-iterate change log
  │    ├─ EIP-158 empty account removal
  │    ├─ Async code batch flush          ← Overlaps with account processing
  │    └─ FlushToTree(writeBatch)
  └─ RecalculateStateRoot()               ← Compute Merkle root
       └─ StateTree.UpdateRootHash()

CommitTree() [called by BranchProcessor.PreCommitBlock]
  └─ Persist dirty trie nodes to DB
```

### Patricia trie internals

**File**: `Nethermind.Trie/PatriciaTree.cs`

**Get** (read traversal):
```
PatriciaTree.Get(rawKey)
  ├─ Convert key bytes → nibbles (stackalloc byte[64])
  └─ GetNew(nibbles, root):
       while (true):
         node.ResolveNode(store, path)    ← Lazy RLP decode
         if Leaf:  return value if key matches
         if Branch: follow child[nibble], advance path
         if Extension: match prefix, follow child
```

**Set** (write traversal):
```
PatriciaTree.Set(rawKey, value)
  ├─ Interlocked write guard             ← Serial writes only
  ├─ Convert key → nibbles
  └─ SetNew(stack, nibbles, value, root):
       traverse to target leaf/position
       if value unchanged: return (no-op)
       if node.IsSealed: clone + modify   ← Immutable committed nodes
       else: modify in-place, clear Keccak
       handle splits: Leaf→Branch, new Extensions
```

**Concurrency model**: Reads are parallel-safe. Writes are serialized via
`Interlocked.CompareExchange` on `_isWriteInProgress`.

### Node storage scheme (HalfPath)

**File**: `Nethermind.Trie/NodeStorage.cs`

The default HalfPath scheme organizes DB keys by trie section:
- **State top-level** (section 0): 42 bytes — `[section:1][path:8][len:1][hash:32]`
- **State lower** (section 1): same layout
- **Storage**: 74 bytes — `[section:1][address:32][path:8][len:1][hash:32]`

Benefits: Better RocksDB cache locality, section-aware read-ahead prefetching.

### Trie performance characteristics

| Optimization | Detail |
|-------------|--------|
| Stack-allocated nibbles | Keys ≤ 64 bytes use `stackalloc` |
| Lazy RLP decode | `TrieNode.ResolveNode()` defers decode until first access |
| Storage key lookup table | Indices 0–1023 use precomputed Keccak hashes |
| Node unresolving | Persisted nodes at depth > 4 discard decoded data to save RAM |
| Change log reversal | Single-pass commit with duplicate elimination |
| Async code flush | Code DB writes overlap with account processing |
| Parallel storage commits | Independent storage trees committed concurrently (with quota) |
| Per-scope account cache | Accounts loaded in a block cached for the scope |
| Null account tracking | Missing accounts recorded to avoid re-querying |
| HalfPath storage | Section-based DB keys for better cache locality |
| InlineArray for branches | 16-element branch array uses C# 12 InlineArray (compact, no indirection) |

---

## 5. Key Data Structures

### Hot-path value types

| Type | Kind | Size | File | Notes |
|------|------|------|------|-------|
| `EvmStack` | `ref struct` | ~33 KB (1025 × 32B) | `Nethermind.Evm/EvmStack.cs` | Stack-allocated, SIMD push/pop via `Vector256<byte>`, `AggressiveInlining` on all hot methods, unsafe pointer arithmetic |
| `EvmPooledMemory` | `struct` | ~48B + pooled array | `Nethermind.Evm/EvmPooledMemory.cs` | `ArrayPool<byte>.Shared`, word-aligned expansion, quadratic gas cost, lazy init |
| `ValueHash256` | `readonly struct` | 32B | `Nethermind.Core/Crypto/Hash256.cs` | Stores as `Vector256<byte>`, SIMD equality, zero-copy via span |
| `ValueDecoderContext` | `ref struct` | ~48B | `Nethermind.Serialization.Rlp/Rlp.cs` | Stack-only RLP decoder, `ReadOnlySpan<byte>` data, zero-copy slicing |
| `AccountStruct` | `readonly struct` | 96B | `Nethermind.Core/Account.cs` | 2×UInt256 + 2×ValueHash256, SIMD-based IsNull check via `vpor` |
| `TreePath` | struct | small | `Nethermind.Trie/TreePath.cs` | Nibble path tracking, stack-allocated |

### Heap-allocated core types

| Type | Size (approx) | File | Notes |
|------|---------------|------|-------|
| `Hash256` | ~64B | `Nethermind.Core/Crypto/Hash256.cs` | Wraps `ValueHash256`, thread-static byte buffer, `Vector256` equality |
| `Address` | ~72B | `Nethermind.Core/Address.cs` | 20B address, `Vector128` + `uint` equality comparison |
| `Account` | ~80–96B | `Nethermind.Core/Account.cs` | Immutable, null-optimized hashes, functional `WithChanged*()` pattern |
| `Transaction` | ~200–400B | `Nethermind.Core/Transaction.cs` | Lazy hash with lock, `ReadOnlyMemory<byte>` calldata (zero-copy) |
| `BlockHeader` | ~200–250B | `Nethermind.Core/BlockHeader.cs` | Many nullable Hash256 fields, composition with Block |
| `TrieNode` | ~48B base | `Nethermind.Trie/TrieNode.cs` | Lazy RLP via `SpanSource`, atomic flags, InlineArray for branches |

### Pooled / reused objects

| Type | Pool mechanism | File |
|------|---------------|------|
| `ExecutionEnvironment` | `ConcurrentQueue<>` static pool | `Nethermind.Evm/ExecutionEnvironment.cs` |
| `VmState<TGasPolicy>` | `ConcurrentQueue<>` static pool | `Nethermind.Evm/VmState.cs` |
| EVM data stack (`byte[]`) | `StackPool` static pool | `Nethermind.Evm/VmState.cs` |
| EVM memory backing | `ArrayPool<byte>.Shared` | `Nethermind.Evm/EvmPooledMemory.cs` |
| Traverse stack | Reused per Set operation | `Nethermind.Trie/PatriciaTree.cs` |

### RLP serialization

**File**: `Nethermind.Serialization.Rlp/Rlp.cs`

Two paths:
- **RlpStream** (class): Heap-allocated, used for encoding with pre-sized buffer
- **ValueDecoderContext** (ref struct): Stack-allocated, used for decoding from `ReadOnlySpan<byte>`

Hot methods: `DecodeUInt256()`, `DecodeAddress()`, `DecodeKeccak()`, `ReadSequenceLength()`

All use span-based zero-copy access. `DecodeKeccak()` deduplicates common hashes
(empty tree root, empty code hash) to avoid allocation.

### RocksDB wrapper

**File**: `Nethermind.Db.Rocks/DbOnTheRocks.cs`

- Multiple read options: `_defaultReadOptions`, `_hintCacheMissOptions`, `_readAheadReadOptions`
- Write batching: Accumulated writes flushed together
- Column families via `ColumnsDb<T>` — separate columns for state, code, storage, etc.
- Row cache and block cache configuration for tuning

---

## 6. Performance Optimization Map

Summary of where time is spent and what's already optimized, to guide future work.

### Hot path ranking (by time in block processing)

```
1. EVM opcode execution          ← Function pointers, SIMD stack, pooled memory
2. State trie traversal (Get)    ← Lazy decode, cached nodes, stackalloc keys
3. State trie commit (Set)       ← Parallel storage, async code flush
4. Keccak hashing                ← Storage lookup table for indices < 1024
5. RLP encode/decode             ← ref struct decoder, span-based
6. RocksDB read/write            ← Batching, column families, read-ahead
7. Transaction validation        ← Intrinsic gas, signature recovery
8. Bloom calculation             ← Parallel per receipt
```

### Already-optimized areas (diminishing returns expected)

- EVM opcode dispatch (function pointers — hard to beat)
- EVM stack operations (SIMD, unsafe, ref struct)
- Gas tracking (generic struct, zero-alloc)
- Storage key hashing for low indices (lookup table)
- Object pooling (ExecutionEnvironment, VmState, EVM memory)

### Potential optimization targets

- Trie node resolution and caching strategies
- RocksDB read patterns and cache tuning
- State commit batching and parallelization
- RLP encoding allocation patterns
- Memory expansion gas calculation
- Prewarmer effectiveness and coverage
- Keccak hashing for high storage indices
- Transaction processing pipeline overhead
