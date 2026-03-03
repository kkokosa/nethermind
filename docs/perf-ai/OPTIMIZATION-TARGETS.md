# Optimization Targets

Concrete optimization candidates identified by code analysis. Each entry references
actual source lines, explains why it matters, and estimates difficulty and impact.

Prioritized by impact/difficulty ratio. All findings verified against source code.

---

## Priority Legend

| Difficulty | Meaning |
|-----------|---------|
| **S** | Small — isolated change, < 50 lines, low risk |
| **M** | Medium — touches multiple files or requires API changes |
| **L** | Large — architectural change, wide blast radius |

| Impact | Meaning |
|--------|---------|
| **High** | Hot path, per-opcode or per-tx frequency, measurable in block processing time |
| **Med** | Warm path, per-block or per-commit frequency |
| **Low** | Cold path, rare execution, or tracing-only |

---

## 1. EVM Module (Nethermind.Evm)

### EVM-1: PopAddress() allocates via ToArray() on every CALL

**File**: `EvmStack.cs:467,477`
```csharp
address = new Address(_bytes.Slice(..., AddressSize).ToArray());
```

- **Why it matters**: Called for every CALL, DELEGATECALL, STATICCALL, CALLCODE, BALANCE,
  EXTCODESIZE, EXTCODECOPY, EXTCODEHASH, SELFDESTRUCT. `Address` already has a
  `ReadOnlySpan<byte>` constructor (Address.cs:141), so `.ToArray()` is pure waste.
- **Frequency**: Per address-consuming opcode — thousands per block
- **Difficulty**: S — remove `.ToArray()`, pass span directly
- **Impact**: High — eliminates 20-byte heap allocation per address opcode
- **Benchmark exists**: `EvmStackBenchmarks.cs` (partial), `EvmOpcodesBenchmark.cs` (indirect)
- **Needs benchmark**: Yes — isolate PopAddress allocation count

### EVM-2: SSTORE/TSTORE allocate via bytes.ToArray() on every storage write

**File**: `Instructions/EvmInstructions.Storage.cs:402,564`
```csharp
vm.WorldState.Set(in storageCell, newIsZero ? BytesZero : bytes.ToArray());
```
Also TSTORE at line 109:
```csharp
vm.WorldState.SetTransientState(in storageCell, !bytes.IsZero() ? bytes.ToArray() : BytesZero32);
```

- **Why it matters**: Every storage write that changes a value allocates a 32-byte array.
  SSTORE is one of the most frequent state-mutating opcodes.
- **Frequency**: Per storage write — hundreds to thousands per block
- **Difficulty**: M — requires `IWorldState.Set()` to accept `ReadOnlySpan<byte>`
- **Impact**: High — 32-byte allocation per SSTORE
- **Benchmark exists**: `EvmOpcodesBenchmark.cs` (SSTORE at line 96)
- **Needs benchmark**: Add [MemoryDiagnoser] to existing SSTORE benchmark

### EVM-3: RETURN/REVERT allocate via returnData.ToArray()

**File**: `Instructions/EvmInstructions.Call.cs:362`, `EvmInstructions.ControlFlow.cs:189`
```csharp
vm.ReturnData = returnData.ToArray();
```

- **Why it matters**: Every contract call return copies return data from pooled EVM memory
  into a new heap array. Defeats the EvmPooledMemory pooling strategy. In nested call
  scenarios (10–100+ calls per tx), this compounds.
- **Frequency**: Per call frame return — tens to hundreds per transaction
- **Difficulty**: M — change `ReturnData` type from `byte[]` to `ReadOnlyMemory<byte>`
- **Impact**: High — allocation proportional to return data size, per call frame
- **Benchmark exists**: `StaticCallBenchmarks.cs` (indirect)
- **Needs benchmark**: Yes — nested call return data benchmark

### EVM-4: TransactionProcessor receipt output allocates twice

**File**: `TransactionProcessing/TransactionProcessor.cs:275,280,281`
```csharp
byte[] output = substate.ShouldRevert ? substate.Output.Bytes.ToArray() : [];
// ...
tracer.MarkAsSuccess(env.ExecutingAccount, spentGas, substate.Output.Bytes.ToArray(), logs, stateRoot);
LogEntry[] logs = substate.Logs.Count != 0 ? substate.Logs.ToArray() : [];
```

- **Why it matters**: Per-transaction: output bytes are `.ToArray()`'d, logs list is `.ToArray()`'d.
  On the success path (line 281), output is converted even if tracer doesn't need it.
- **Frequency**: Once per transaction
- **Difficulty**: M — change `MarkAsSuccess`/`MarkAsFailed` to accept `ReadOnlyMemory<byte>`
- **Impact**: Med — per-tx overhead, moderate allocation size
- **Benchmark exists**: `TxProcessingBenchmark.cs` (indirect)
- **Needs benchmark**: Add allocation tracking to tx processing benchmark

---

## 2. Trie Module (Nethermind.Trie)

### TRIE-1: Inline node resolution allocates via fullRlp.ToArray()

**File**: `TrieNode.cs:1284`
```csharp
TrieNode child = new(NodeType.Unknown, fullRlp.ToArray());
```

- **Why it matters**: When resolving inline trie nodes (< 32 bytes, stored directly in parent
  RLP), the span is copied to a heap array. Inline nodes are common in lower trie levels.
  Called during every trie traversal that encounters an inline child.
- **Frequency**: Per inline node during trie Get/Set — thousands per block
- **Difficulty**: M — TrieNode constructor needs a span-accepting path
- **Impact**: High — allocations during the hottest trie traversal path
- **Benchmark exists**: `RlpTrieNodeEncodingBenchmark.cs` (encoding only)
- **Needs benchmark**: Yes — trie traversal with inline nodes

### TRIE-2: Node cloning in Set() allocates per structural change

**File**: `PatriciaTree.cs:626,664,715,719,736`
```csharp
node = node.CloneWithChangedValue(value);        // line 626
node.CloneWithChangedKey(HexPrefix.GetArray(...)) // line 664
node = child.CloneWithChangedKey(HexPrefix.ConcatNibbles(...)) // line 715
node = node.Clone();                              // line 719
```

- **Why it matters**: Sealed (committed) nodes are immutable. Every Set that modifies a
  committed node allocates a new TrieNode + clones NodeData. Combined with
  `HexPrefix.GetArray()` and `ConcatNibbles()` allocating byte arrays for nibble paths,
  a single Set can produce 3–5 allocations.
- **Frequency**: Per trie Set on sealed nodes — hundreds per block
- **Difficulty**: L — requires rethinking node mutability or pooling cloned nodes
- **Impact**: High — multiple allocations per state write
- **Benchmark exists**: No
- **Needs benchmark**: Yes — trie Set allocation profiling

### TRIE-3: Repeated Keccak in GenerateKey() during commit

**File**: `TrieNode.cs:520-521`
```csharp
Metrics.TreeNodeHashCalculations++;
return Nethermind.Core.Crypto.Keccak.Compute(rlp.Span);
```

- **Why it matters**: Every dirty node has its Keccak recomputed from full RLP during commit.
  In a branch node with 16 children where only 1 changed, all dirty ancestors recompute
  their Keccak. No incremental hashing is possible (Keccak limitation), but caching
  unchanged subtree hashes could reduce redundant work.
- **Frequency**: Per dirty node during commit — proportional to tree depth × changes
- **Difficulty**: M — cache management for partially-dirty branches
- **Impact**: Med — Keccak is fast but this is O(dirty_nodes × node_size)
- **Benchmark exists**: No
- **Needs benchmark**: Yes — commit-time Keccak overhead

### TRIE-4: HexPrefix nibble path allocations

**File**: `HexPrefix.cs:148,191-194,251-255`
```csharp
return path.ToArray();             // line 148
byte[] result = new byte[...];     // lines 191, 251
```

- **Why it matters**: `GetArray()`, `PrependNibble()`, and `ConcatNibbles()` allocate byte
  arrays for nibble paths. Small path cache covers lengths ≤ 3, but branch creation in
  Set() can exceed this. Called from PatriciaTree.cs lines 664, 715.
- **Frequency**: Per branch creation/modification during Set
- **Difficulty**: S — expand cache size or use stackalloc + pooling
- **Impact**: Med — small arrays but high frequency during heavy writes
- **Benchmark exists**: No
- **Needs benchmark**: Yes — trie structural modification allocations

### TRIE-5: Interlocked operations per cached node in DirtyNodesCache

**File**: `Pruning/TrieStoreDirtyNodesCache.cs:220-228`
```csharp
Interlocked.Increment(ref _count);
Interlocked.Add(ref _totalMemory, memoryUsage);
Interlocked.Increment(ref _dirtyCount);
Interlocked.Add(ref _totalDirtyMemory, memoryUsage);
```

- **Why it matters**: 4–5 Interlocked operations per node insertion into cache. These are
  full memory barriers. With 256 shards, contention is reduced but per-operation cost
  remains.
- **Frequency**: Per cached trie node — thousands per block
- **Difficulty**: S — batch counter updates or use relaxed counters
- **Impact**: Med — measurable on high-throughput paths
- **Benchmark exists**: No
- **Needs benchmark**: Yes — cache insertion throughput

---

## 3. State Module (Nethermind.State)

### STATE-1: LINQ chain in parallel storage root update

**File**: `PersistentStorageProvider.cs:275-285`
```csharp
using ArrayPoolList<...> storages = _storages
    .Where(kv => ...)
    .OrderByDescending(kv => kv.Value.EstimatedChanges)
    .Select((kv) => (...))
    .ToPooledList(_storages.Count);
```

- **Why it matters**: Three LINQ operators (Where → OrderByDescending → Select) create
  intermediate enumerator objects + O(n log n) sort. Called on every block commit in
  `FlushToTree()`. For blocks touching 100+ contracts, this is measurable.
- **Frequency**: Once per block commit
- **Difficulty**: S — replace with manual loop + in-place sort
- **Impact**: Med — per-block overhead, scales with contract count
- **Benchmark exists**: No
- **Needs benchmark**: Yes — commit with 100+ dirty storage trees

### STATE-2: OrderBy in code batch flush

**File**: `StateProvider.cs:626`
```csharp
foreach (var kvp in dict.OrderBy(static kvp => kvp.Key))
```

- **Why it matters**: LINQ OrderBy on code dictionary during async flush. Creates sorted
  copy. High-deployment blocks (contract factories) can have 100+ entries.
- **Frequency**: Once per block commit (async)
- **Difficulty**: S — use `List<>.Sort()` instead of LINQ
- **Impact**: Low — async path, but still GC pressure
- **Benchmark exists**: No
- **Needs benchmark**: Contract deployment-heavy block benchmark

### STATE-3: StorageTree RLP encoding allocates per value

**File**: `StorageTree.cs:77-98`
```csharp
Rlp rlpEncoded = Rlp.Encode(value);  // ALLOCATION
encodedValue = rlpEncoded.Bytes;
```

- **Why it matters**: Every storage value written to the trie goes through `Rlp.Encode(byte[])`,
  which allocates an Rlp wrapper object. For bulk storage updates (100+ slots per contract),
  this is significant.
- **Frequency**: Per storage slot write during commit
- **Difficulty**: M — need span-based Rlp encoding path for storage values
- **Impact**: Med — proportional to storage writes per block
- **Benchmark exists**: No (StorageTreeBenchmark.cs exists but doesn't track allocations)
- **Needs benchmark**: Yes — storage commit allocation profiling

### STATE-4: Storage root parallelization threshold is count-based, not work-based

**File**: `PersistentStorageProvider.cs:245`
```csharp
if (_toUpdateRoots.Count < 3)
    UpdateRootHashesSingleThread();
else
    UpdateRootHashesMultiThread();
```

- **Why it matters**: Threshold is based on contract count (3), not total work.
  4 contracts with 10 slots each wastes parallel overhead. 2 contracts with 100k slots
  each misses parallelism. `EstimatedChanges` is already available but unused for
  the threshold decision.
- **Frequency**: Once per block commit
- **Difficulty**: S — use sum of EstimatedChanges as threshold
- **Impact**: Med — can both avoid overhead and capture missed parallelism
- **Benchmark exists**: No
- **Needs benchmark**: Yes — uneven storage distribution scenarios

---

## 4. RLP Serialization (Nethermind.Serialization.Rlp)

### RLP-1: Rlp.Encode(long) allocates a byte[] for every integer > 127

**File**: `Rlp.cs:276-283`
```csharp
< 0x100 => new(new byte[] { 129, (byte)value }),
< 0x1_0000 => new(new byte[] { 130, (byte)(value >> 8), (byte)value }),
// ... up to 9 bytes
```

- **Why it matters**: Every numeric field encoding (gas, nonce, block number, value, etc.)
  allocates a new byte array. A transaction encodes ~10 numeric fields; at 100+ tx/block,
  that's 1000+ small array allocations per block.
- **Frequency**: Per numeric field encoding — thousands per block
- **Difficulty**: M — need cached Rlp instances for common value ranges or encode to span
- **Impact**: Med — small arrays but very high frequency
- **Benchmark exists**: `RlpEncodeLongBenchmark.cs`
- **Needs benchmark**: Add [MemoryDiagnoser] to existing benchmark

### RLP-2: Encoder .ToArray() on every object serialization to storage

**File**: `AccountDecoder.cs:71`, `HeaderDecoder.cs:163`, `CompactReceiptStorageDecoder.cs:127`
```csharp
return new Rlp(rlpStream.Data.ToArray());
```

- **Why it matters**: Every account, header, and receipt encoded for storage copies the
  RlpStream's internal buffer to a new array. The RlpStream already has the data; the
  copy is for the Rlp wrapper.
- **Frequency**: Per object serialized to storage — hundreds per block
- **Difficulty**: M — need Rlp to accept CappedArray directly or use pooled arrays
- **Impact**: Med — proportional to objects persisted
- **Benchmark exists**: `RlpEncodeAccountBenchmark.cs`, `RlpEncodeBlockBenchmark.cs`
- **Needs benchmark**: Add [MemoryDiagnoser] to existing benchmarks

---

## 5. Database Layer (Nethermind.Db.Rocks)

### DB-1: Interlocked.Increment on every read and write for metrics

**File**: `DbOnTheRocks.cs:335,340`
```csharp
Interlocked.Increment(ref _totalReads);   // on every Get
Interlocked.Increment(ref _totalWrites);  // on every Set
```

- **Why it matters**: Full memory barrier on every DB operation. Reads heavily dominate
  (state lookups). Under high read throughput, this creates unnecessary contention.
- **Frequency**: Per DB read/write — tens of thousands per block
- **Difficulty**: S — use `[ThreadStatic]` counters or periodic aggregation
- **Impact**: Med — memory barrier cost × high frequency
- **Benchmark exists**: No
- **Needs benchmark**: Yes — DB read throughput microbenchmark

---

## 6. Block Processing (Nethermind.Consensus)

### BP-1: Parallel bloom calculation for all blocks regardless of size

**File**: `BlockProcessor.cs:158-161`
```csharp
ParallelUnbalancedWork.For(0, receipts.Length, ...)
```

- **Why it matters**: Parallel infrastructure overhead (task creation, work stealing) is
  paid even for blocks with 1–10 receipts, where serial execution is faster.
- **Frequency**: Once per block
- **Difficulty**: S — add `if (receipts.Length < threshold)` serial fallback
- **Impact**: Low — small per-block cost, but easy win
- **Benchmark exists**: `BlockProcessingBenchmark.cs`
- **Needs benchmark**: Small-block vs large-block comparison

---

## Prioritized Summary

Ranked by impact/difficulty ratio (best ROI first):

| Rank | ID | Target | Diff | Impact | Has Bench? |
|------|----|--------|------|--------|------------|
| 1 | EVM-1 | PopAddress .ToArray() removal | S | High | Partial |
| 2 | TRIE-1 | Inline node .ToArray() in traversal | M | High | No |
| 3 | EVM-2 | SSTORE/TSTORE .ToArray() per write | M | High | Partial |
| 4 | EVM-3 | RETURN/REVERT data .ToArray() per frame | M | High | Partial |
| 5 | STATE-1 | LINQ in storage root flush | S | Med | No |
| 6 | TRIE-5 | Interlocked ops per cached node | S | Med | No |
| 7 | DB-1 | Interlocked per DB read/write | S | Med | No |
| 8 | STATE-4 | Storage root parallel threshold | S | Med | No |
| 9 | TRIE-4 | HexPrefix nibble path allocations | S | Med | No |
| 10 | BP-1 | Bloom parallel overhead for small blocks | S | Low | Partial |
| 11 | RLP-1 | Rlp.Encode(long) per-integer alloc | M | Med | Yes |
| 12 | EVM-4 | Receipt output double .ToArray() | M | Med | Partial |
| 13 | STATE-3 | StorageTree RLP encode per value | M | Med | No |
| 14 | RLP-2 | Encoder .ToArray() for storage | M | Med | Yes |
| 15 | TRIE-2 | Node cloning in Set() | L | High | No |
| 16 | TRIE-3 | Keccak recomputation in commit | M | Med | No |
| 17 | STATE-2 | OrderBy in code batch flush | S | Low | No |

### Benchmark coverage gaps

The following need new benchmarks before optimization work can begin:

| Module | Missing benchmark |
|--------|------------------|
| EVM | PopAddress allocation microbenchmark |
| EVM | Nested call return data allocation tracking |
| Trie | Trie traversal with inline nodes |
| Trie | Set-path allocation profiling (clones + nibbles) |
| Trie | Commit-time Keccak overhead |
| Trie | Cache insertion throughput |
| State | Commit with 100+ dirty storage trees |
| State | Storage commit allocation profiling |
| State | Uneven storage distribution scenarios |
| DB | Read throughput microbenchmark |

### Quick wins (S difficulty, immediate value)

These can be done first to establish the workflow and build confidence:

1. **EVM-1**: Remove `.ToArray()` from `PopAddress()` — Address already accepts `ReadOnlySpan<byte>`
2. **STATE-1**: Replace LINQ chain with manual loop in `UpdateRootHashesMultiThread`
3. **TRIE-5**: Batch Interlocked ops in `IncrementMemory()` or use relaxed counters
4. **DB-1**: Replace `Interlocked.Increment` with thread-local counters for metrics
5. **STATE-4**: Use `EstimatedChanges` sum instead of contract count for parallel threshold
6. **BP-1**: Add receipt count threshold for serial bloom calculation
