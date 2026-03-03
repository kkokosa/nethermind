# Benchmark Inventory

Complete catalog of all BenchmarkDotNet benchmarks in the repository, organized
by project. Includes coverage gaps and recommendations for new benchmarks.

---

## Benchmark Projects

| Project | Path | Classes | Focus |
|---------|------|---------|-------|
| **Nethermind.Evm.Benchmark** | `src/Nethermind/Nethermind.Evm.Benchmark/` | 8 | EVM execution, opcodes, block/tx processing |
| **Nethermind.Benchmark** | `src/Nethermind/Nethermind.Benchmark/` | 40+ | Core utils, RLP, state, trie, crypto |
| **Nethermind.Trie.Benchmark** | `src/Nethermind/Nethermind.Trie.Benchmark/` | 3 | Trie node ops, cache, commit |
| **Nethermind.Precompiles.Benchmark** | `src/Nethermind/Nethermind.Precompiles.Benchmark/` | 19 | EVM precompiled contracts |
| **Nethermind.Network.Benchmark** | `src/Nethermind/Nethermind.Network.Benchmark/` | 8 | P2P handshake, encryption, message encoding |
| **Nethermind.JsonRpc.Benchmark** | `src/Nethermind/Nethermind.JsonRpc.Benchmark/` | 3 | RPC modules, serialization |
| **Nethermind.EthereumTests.Benchmark** | `src/Nethermind/Nethermind.EthereumTests.Benchmark/` | 1 | EF state test suite |

---

## How to Run

```bash
# Run all benchmarks in a project
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/

# Run specific benchmark class
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ -- --filter "*EvmStackBenchmarks*"

# Run specific method
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ -- --filter "*BlockProcessingBenchmark.Transfers_200*"

# Run with memory diagnoser (if not already in class)
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ -- --filter "*EvmOpcodesBenchmark*" --memory

# List available benchmarks without running
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ -- --list flat

# Export results to specific format
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ -- --filter "*BlockProcessingBenchmark*" --exporters json csv
```

**Benchmark solution**: `src/Nethermind/Benchmarks.slnx` contains all benchmark projects.

---

## 1. Nethermind.Evm.Benchmark

### EvmOpcodesBenchmark

| Method | What it measures | MemoryDiag | Params |
|--------|-----------------|------------|--------|
| `ExecuteOpcode()` | Individual opcode execution via function pointer dispatch (8192 ops/invoke) | No | All valid opcodes via `[ParamsSource]` |

Runs each opcode through the production execution path. Special handling for
state opcodes (SLOAD, SSTORE, TLOAD, TSTORE), call opcodes, and arithmetic.
Regression thresholds: 5% default, 15% calls, 20% state, 15% log.

### EvmStackBenchmarks

| Method | What it measures | MemoryDiag | Params |
|--------|-----------------|------------|--------|
| `Uint256(v)` | Push/pop UInt256 (4 ops) | No | 3 values (zero, large, max) |
| `Byte()` | Push/pop bytes (4 ops) | No | — |
| `PushZero()` | Push zero (4 ops) | No | — |
| `PushOne()` | Push one (4 ops) | No | — |
| `Swap()` | Swap stack positions (4 ops) | No | — |
| `Dup()` | Duplicate stack items (4 ops) | No | — |

### BlockProcessingBenchmark

| Method | What it measures | MemoryDiag | Ops/invoke |
|--------|-----------------|------------|------------|
| `EmptyBlock()` | Empty block processing | Yes | 5000 |
| `SingleTransfer()` | Single ETH transfer | Yes | 5000 |
| `Transfers_50()` | 50 legacy transfers | Yes | 500 |
| `Transfers_200()` | 200 legacy transfers (baseline) | Yes | 200 |
| `Eip1559_200()` | 200 EIP-1559 txs | Yes | 200 |
| `AccessList_50()` | 50 access-list txs | Yes | 500 |
| `ContractDeploy_10()` | 10 contract deployments | Yes | 5000 |
| `ContractCall_200()` | 200 contract calls | Yes | 200 |
| `MixedBlock()` | Mixed tx types (100+60+30+10) | Yes | 200 |

Full block processing via `BranchProcessor.Process()` under Osaka rules.

### TxProcessingBenchmark

| Method | What it measures | MemoryDiag | Ops/invoke |
|--------|-----------------|------------|------------|
| `SimpleTx()` | Simple ETH transfer (baseline) | Yes | 1000 |
| `MixedDataTx()` | Transfer + 128B mixed calldata | Yes | 1000 |
| `ZeroDataTx()` | Transfer + 128B zero calldata | Yes | 1000 |
| `LargeDataTx()` | Transfer + 1024B calldata | Yes | 1000 |
| `AccessListTx()` | EIP-2930 access-list tx | Yes | 1000 |
| `Eip1559Tx()` | EIP-1559 tx | Yes | 1000 |
| `ContractCall()` | Contract invocation | Yes | 1000 |
| `ContractDeploy()` | Contract deployment (CREATE) | Yes | 1000 |

Per-tx cost via `CallAndRestore()`.

### StaticCallBenchmarks

| Method | What it measures | MemoryDiag | Params |
|--------|-----------------|------------|--------|
| `ExecuteCode()` | STATICCALL execution (baseline) | Yes | 2 bytecodes |
| `ExecuteCodeNoTracing()` | Execution without tracing | Yes | 2 bytecodes |
| `No_machine_running()` | State reset overhead | Yes | 2 bytecodes |

### WarmupBenchmark

| Method | What it measures | MemoryDiag | Ops/invoke |
|--------|-----------------|------------|------------|
| `Warmup_SimpleTx()` | Warmup path for simple tx (baseline) | Yes | 1000 |
| `Warmup_AccessListTx()` | Warmup path for access-list tx | Yes | 1000 |
| `Warmup_Eip1559Tx()` | Warmup path for EIP-1559 tx | Yes | 1000 |
| `Warmup_ContractCall()` | Warmup path for contract call | Yes | 1000 |
| `CallAndRestore_SimpleTx()` | Full path reference | Yes | 1000 |
| `CallAndRestore_ContractCall()` | Full path reference | Yes | 1000 |

Compares prewarmer path (`ExecutionOptions.Warmup`) vs full path.

### MultipleUnsignedOperations

| Method | What it measures | MemoryDiag |
|--------|-----------------|------------|
| `ExecuteCode()` | Arithmetic ops (ADD, MUL, DIV, SUB, ADDMOD, MULMOD, LT, GT) | No |
| `No_machine_running()` | State provider reset (baseline) | No |

### EvmBenchmarks

| Method | What it measures | MemoryDiag |
|--------|-----------------|------------|
| `ExecuteCode()` | Custom bytecode from env var `NETH.BENCHMARK.BYTECODE` | Yes |

---

## 2. Nethermind.Benchmark

### Core Utilities

| Class | Methods | MemoryDiag | What it measures |
|-------|---------|------------|-----------------|
| `Keccak256Benchmarks` | `MeadowHashSpan`, `MeadowHashBytes`, `Current`, `ValueKeccak` | No | Keccak-256 implementations |
| `Keccak512Benchmarks` | `Improved`, `Current` | No | Keccak-512 hash |
| `FastHashBenchmarks` | `FastHash`, `FastHashAes`, `FastHashCrc` | Yes | Fast hash (AES/CRC/standard), sizes 16–1024 |
| `BytesCompareBenchmarks` | `Improved`, `Current` | No | Byte array equality, 6 scenarios |
| `BytesIsZeroBenchmarks` | `Improved`, `Current` | No | Zero-check on byte arrays, 5 scenarios |
| `BytesPadBenchmarks` | `Improved`, `Current` | No | Left/right padding to 32 bytes |
| `BytesReverseBenchmarks` | `Current`, `Improved`, `SwapVersion`, `Avx2Version` | No | Array reversal (scalar vs SIMD) |
| `ByteArrayToHexBenchmarks` | `Improved`, `SafeLookup` | No | Byte-to-hex conversion |
| `FromHexBenchmarks` | `Scalar`, `Vector128`, `Vector256`, `Vector512` | No | Hex decoding at sizes 32–1024 |
| `ToHexBenchmarks` | `Current`, `Improved` | No | Hex encoding |
| `LruCacheBenchmarks` | `WithItems` | No | LRU cache fill, varying capacity/items |
| `LruCacheAddAtCapacityBenchmarks` | `WithRecreation`, `WithClear` | No | LRU cache eviction stress |
| `LruCacheKeccakBytesBenchmarks` | `WithItems` | No | LRU with hash keys, varying capacity |
| `SeqlockCacheBenchmarks` | 10+ methods | Yes | SeqlockCache vs ConcurrentDict (hit/miss/set/mixed) |
| `SpanSourceBenchmark` | `MemorySize_*`, `Span_*` | No | SpanSource wrapper overhead |
| `SpecBenchmark` | `WithInheritance`, `WithoutInheritance` | Yes | Spec lookup with/without inheritance |
| `ParallelBenchmark` | `ParallelFor`, `ParallelForEach`, `UnbalancedParallel` | No | Parallel iteration strategies |
| `RecoverSignaturesBenchmark` | 6 methods | Yes | EIP-7702 signature recovery (3–100 txs) |
| `BackgroundTaskSchedulerBenchmarks` | 2 methods | Yes | Task scheduler throughput under load |

### EVM Microbenchmarks (in Nethermind.Benchmark/Evm/)

| Class | Methods | What it measures |
|-------|---------|-----------------|
| `BitwiseAndBenchmark` | `Current`, `Improved` | AND on 32-byte (scalar vs SIMD) |
| `BitwiseOrBenchmark` | `Current`, `Improved` | OR on 32-byte (scalar vs SIMD) |
| `BitwiseXorBenchmark` | `Current`, `Improved` | XOR on 32-byte (scalar vs SIMD) |
| `BitwiseNotBenchmark` | `Current`, `Improved` | NOT on 32-byte (scalar vs Vector XOR) |
| `SignExtendBenchmark` | `Current`, `Improved`, `Improved2` | SIGNEXTEND opcode |
| `JumpDestinationsBenchmark` | `Current`, `Improved`, `Improved2` | JUMPDEST analysis (48KB–512KB codes) |
| `MemoryCostBenchmark` | `Current` | EVM memory expansion cost, 3 scenarios |
| `Blake2Benchmark` | `Current`, `Improved` | Blake2 compression |
| `EcRecoverBenchmark` | — | Not implemented (stubs) |

None of these have `[MemoryDiagnoser]`.

### RLP Serialization (in Nethermind.Benchmark/Rlp/)

| Class | Methods | MemoryDiag | What it measures |
|-------|---------|------------|-----------------|
| `RlpEncodeAccountBenchmark` | `Improved`, `Current` | No | Account RLP encode, 2 scenarios |
| `RlpDecodeAccountBenchmark` | `Improved`, `Current` | No | Account RLP decode, 2 scenarios |
| `RlpEncodeBlockBenchmark` | `Improved2`, `Improved3`, `Current` | No | Block RLP encode, 2 scenarios |
| `RlpDecodeBlockBenchmark` | `Improved`, `Current` | No | Block RLP decode (simple + 100 txs) |
| `RlpEncodeHeaderBenchmark` | `Improved2`, `Current` | No | Header RLP encode |
| `RlpEncodeTransactionBenchmark` | `Current` | No | Transaction RLP encode |
| `RlpEncodeLongBenchmark` | `Improved`, `Current` | No | Long integer encoding, 13 values |
| `RlpDecodeKeccakBenchmark` | `Current` | No | Keccak hash decode, 4 special hashes |
| `RlpTrieNodeEncodingBenchmark` | `Encode_Extension`, `Encode_Branch`, `Encode_Leaf` | Yes | Trie node RLP encode by type |

### State (in Nethermind.Benchmark/State/)

| Class | Methods | MemoryDiag | What it measures |
|-------|---------|------------|-----------------|
| `StorageCellBenchmark` | `Parameter_Passing` | No | StorageCell by-ref passing overhead |
| `StorageTreeBenchmark` | `Set_index`, `Get_index` | Yes | Storage tree read/write |

### Store (in Nethermind.Benchmark/Store/)

| Class | Methods | MemoryDiag | What it measures |
|-------|---------|------------|-----------------|
| `PatriciaTreeBenchmarks` | 25+ methods | Yes | Trie insert, commit, hash, read, bulk ops (4096–10240 entries) |
| `WorldStateBenchmarks` | 6 methods | No | Account/slot read/write on 4096 accounts, 16384 slots |
| `HexPrefixFromBytesBenchmarks` | `Improved`, `Current` | No | Hex prefix conversion |
| `BloomStorageBenchmark` | `Improved`, `Old` | No | Bloom filter file storage (524k+ blooms) |

### Mining

| Class | Methods | What it measures |
|-------|---------|-----------------|
| `EthashHashimotoBenchmarks` | `Improved`, `Current` | Ethash Hashimoto hashing |

---

## 3. Nethermind.Trie.Benchmark

| Class | Methods | MemoryDiag | What it measures |
|-------|---------|------------|-----------------|
| `TrieNodeBenchmark` | 12 methods | Yes | Object allocation for TrieNode, Keccak, HexPrefix, Rlp, RlpStream at specific byte sizes |
| `TreeStoreBenchmark` | `Trie_committer_with_one_node` | Yes | Single node commit through TrieStore |
| `CacheBenchmark` | 5 methods | Yes | MemCountingCache memory overhead at 1–4 items |

---

## 4. Nethermind.Precompiles.Benchmark

All inherit from `PrecompileBenchmarkBase` with `Baseline()` method (25 ops/invoke).
Test inputs loaded from CSV/JSON files per precompile directory.

| Class | Precompile | EIP |
|-------|-----------|-----|
| `BN254AddBenchmark` | BN254 curve addition | EIP-196 |
| `BN254MulBenchmark` | BN254 scalar multiplication | EIP-196 |
| `BN254PairingBenchmark` | BN254 pairing check | EIP-197 |
| `Blake2fBenchmark` | BLAKE2f compression | EIP-152 |
| `BlsG1AddBenchmark` | BLS G1 addition | EIP-2537 |
| `BlsG1MulBenchmark` | BLS G1 multiplication | EIP-2537 |
| `BlsG1MSMBenchmark` | BLS G1 multi-scalar mul | EIP-2537 |
| `BlsG2AddBenchmark` | BLS G2 addition | EIP-2537 |
| `BlsG2MulBenchmark` | BLS G2 multiplication | EIP-2537 |
| `BlsG2MSMBenchmark` | BLS G2 multi-scalar mul | EIP-2537 |
| `BlsMapFpToG1Benchmark` | BLS Fp→G1 mapping | EIP-2537 |
| `BlsMapFp2ToG2Benchmark` | BLS Fp2→G2 mapping | EIP-2537 |
| `BlsPairingCheckBenchmark` | BLS pairing check | EIP-2537 |
| `EcRecoverBenchmark` | ECDSA recovery | ecrecover |
| `KeccakBenchmark` | Keccak-256 (0–512B inputs) | — |
| `ModExpBenchmark` | Modular exponentiation | EIP-198 |
| `PointEvaluationBenchmark` | KZG point evaluation | EIP-4844 |
| `RipEmdBenchmark` | RIPEMD-160 | — |
| `Sha256Benchmark` | SHA-256 | — |

None have `[MemoryDiagnoser]`.

---

## 5. Nethermind.Network.Benchmark

| Class | Methods | MemoryDiag | What it measures |
|-------|---------|------------|-----------------|
| `HandshakeBenchmarks` | `Current`, `CurrentAuth`, `CurrentAuthAck` | No | RLPx handshake (full/partial) |
| `EcdhAgreementBenchmarks` | `Current`, `Old` | No | ECDH key agreement (SecP256k1 vs BouncyCastle) |
| `KdfDerivationBenchmarks` | `Current` | No | Key derivation function |
| `InFlowBenchmarks` | `Current` | No | Incoming encrypted message decode |
| `OutFlowBenchmarks` | `Current` | No | Outgoing message encode + encrypt |
| `Eth62ProtocolHandlerBenchmarks` | `Current`, `JustSerialize`, `SerializeAndCreatePacket` | No | ETH62 transaction message handling |
| `NodeStatsCtorBenchmarks` | `Light`, `LightRep` | No | Node stats object creation |
| `DiscoveryBenchmarks` | `Old`, `New` | No | Stub (placeholder) |

---

## 6. Nethermind.JsonRpc.Benchmark

| Class | Methods | MemoryDiag | What it measures |
|-------|---------|------------|-----------------|
| `EthModuleBenchmarks` | `Current` | No | eth_getBalance + eth_getBlockByNumber end-to-end |
| `ParamInfoBenchmarks` | `Current`, `Cached`, `Cached_concurrent` | No | Reflection caching strategies (2 methods) |
| `UInt256ToHexStringBenchmark` | `Improved`, `Current` | No | UInt256→hex conversion (4 values) |

---

## 7. Nethermind.EthereumTests.Benchmark

| Class | Methods | MemoryDiag | What it measures |
|-------|---------|------------|-----------------|
| `EthereumTests` | `Run(testFile)` | No | EF general state test suite (all JSON test files) |

---

## Coverage Gaps

### Critical gaps (hot-path code with no benchmark)

| Gap | Hot path | Related optimization target |
|-----|----------|-----------------------------|
| **PopAddress allocation** | Per CALL/DELEGATECALL/STATICCALL | EVM-1 |
| **SSTORE/TSTORE value .ToArray()** | Per storage write | EVM-2 |
| **RETURN/REVERT data .ToArray()** | Per call frame return | EVM-3 |
| **Trie inline node resolution** | Per trie traversal with inline children | TRIE-1 |
| **Trie Set cloning + nibble allocs** | Per state write on sealed nodes | TRIE-2, TRIE-4 |
| **State commit with many contracts** | Per block commit | STATE-1 |
| **Storage root parallel threshold** | Per block commit | STATE-4 |
| **DB read/write metrics overhead** | Per DB operation | DB-1 |
| **Trie cache insertion throughput** | Per cached node | TRIE-5 |

### MemoryDiagnoser gaps (benchmarks exist but don't track allocations)

| Class | Project | Should add `[MemoryDiagnoser]` |
|-------|---------|-------------------------------|
| `EvmOpcodesBenchmark` | Evm.Benchmark | Yes — tracks opcode allocs |
| `EvmStackBenchmarks` | Evm.Benchmark | Yes — PopAddress alloc tracking |
| `WorldStateBenchmarks` | Benchmark | Yes — state commit alloc tracking |
| All RLP encode/decode | Benchmark | Yes — per-object alloc tracking |
| All precompile benchmarks | Precompiles.Benchmark | Low priority |
| All network benchmarks | Network.Benchmark | Low priority |

### Missing benchmark scenarios

| Scenario | Why it matters |
|----------|---------------|
| Nested CALL chains (10–100 depth) | Return data allocation compounding |
| High-SSTORE blocks (1000+ writes) | Storage allocation patterns |
| Block commit with 100+ dirty contracts | LINQ + parallel threshold impact |
| Trie traversal with mixed inline/hash nodes | Inline node allocation |
| Trie Set on fully-committed tree | Clone allocation profiling |
| Large access-list transactions | EIP-2929 warm/cold tracking overhead |
| Receipt-heavy blocks (1000+ logs) | Bloom parallel overhead, log .ToArray() |
| Code deployment-heavy blocks (50+ creates) | Code batch flush overhead |
| RocksDB read throughput under contention | Interlocked metrics overhead |

---

## Recommendations for New Benchmarks

Ordered by priority (highest first), matching OPTIMIZATION-TARGETS.md entries.

### P0: Must-have before optimization work

**1. EvmAddressPopBenchmark** (for EVM-1)
```
Project: Nethermind.Evm.Benchmark
Measures: PopAddress() allocation overhead
Method: Execute CALL-heavy bytecode, track alloc count
Diagnoser: [MemoryDiagnoser]
```

**2. EvmStorageWriteBenchmark** (for EVM-2)
```
Project: Nethermind.Evm.Benchmark
Measures: SSTORE value .ToArray() overhead
Method: Execute SSTORE-heavy bytecode with varying value sizes
Diagnoser: [MemoryDiagnoser]
```

**3. NestedCallBenchmark** (for EVM-3)
```
Project: Nethermind.Evm.Benchmark
Measures: Return data allocation in nested call chains
Method: Deploy contracts that chain 10/50/100 CALLs, measure alloc
Params: call depth (10, 50, 100), return data size (0, 32, 256)
Diagnoser: [MemoryDiagnoser]
```

**4. TrieTraversalBenchmark** (for TRIE-1)
```
Project: Nethermind.Trie.Benchmark
Measures: Inline node .ToArray() during Get traversal
Method: Build trie with small leaf values (force inline), traverse
Diagnoser: [MemoryDiagnoser]
```

**5. TrieSetAllocationBenchmark** (for TRIE-2, TRIE-4)
```
Project: Nethermind.Trie.Benchmark
Measures: Clone + nibble path allocations during Set on committed tree
Method: Commit tree, then Set random keys, track allocs
Diagnoser: [MemoryDiagnoser]
```

### P1: Important for state/commit optimization

**6. StateCommitBenchmark** (for STATE-1, STATE-4)
```
Project: Nethermind.Benchmark
Measures: Full block commit with varying contract counts
Method: Create world state with N contracts × M slots, commit
Params: contracts (10, 50, 200), slots_per_contract (10, 100, 1000)
Diagnoser: [MemoryDiagnoser]
```

**7. StorageTreeCommitBenchmark** (for STATE-3)
```
Project: Nethermind.Benchmark
Measures: StorageTree RLP encoding allocations during commit
Method: Set N storage slots, commit, track per-slot allocations
Params: slot_count (100, 500, 2000)
Diagnoser: [MemoryDiagnoser]
```

**8. TrieCacheInsertionBenchmark** (for TRIE-5)
```
Project: Nethermind.Trie.Benchmark
Measures: DirtyNodesCache insertion throughput (Interlocked overhead)
Method: Insert N nodes into cache, measure throughput
Params: node_count (1000, 10000)
Diagnoser: [MemoryDiagnoser]
```

### P2: Nice-to-have for broader coverage

**9. DbReadThroughputBenchmark** (for DB-1)
```
Project: New or Nethermind.Benchmark
Measures: RocksDB read throughput with/without Interlocked metrics
Method: Sequential and random reads at varying concurrency
```

**10. RlpEncodeLongAllocationBenchmark** (for RLP-1)
```
Add [MemoryDiagnoser] to existing RlpEncodeLongBenchmark
Validates per-integer allocation count across 13 value scenarios
```

**11. BloomParallelThresholdBenchmark** (for BP-1)
```
Project: Nethermind.Evm.Benchmark
Measures: Parallel vs serial bloom calculation at various receipt counts
Params: receipt_count (1, 5, 10, 50, 100, 500)
```

---

## Existing Benchmark Quality Notes

### Well-covered areas
- **Opcode-level EVM execution** — `EvmOpcodesBenchmark` covers all opcodes with real dispatch
- **Block processing** — `BlockProcessingBenchmark` covers 9 block scenarios with full pipeline
- **Transaction processing** — `TxProcessingBenchmark` covers 8 tx types
- **Patricia trie** — `PatriciaTreeBenchmarks` has 25+ methods covering insert/commit/hash/read
- **Precompiles** — Every precompile has a dedicated benchmark with real test vectors
- **RLP** — All major types (account, block, header, tx, trie node) covered

### Areas needing attention
- **Allocation tracking**: Most EVM and RLP benchmarks lack `[MemoryDiagnoser]`
- **State commit path**: Only `WorldStateBenchmarks` covers this, without allocation tracking
- **Trie modification**: `PatriciaTreeBenchmarks` covers bulk ops but not per-Set allocation
- **DB layer**: No benchmarks at all
- **Network message processing**: Benchmarks exist but are stale (some with `NotImplementedException`)
- **JsonRpc**: Only 3 benchmarks, no serialization throughput tests
