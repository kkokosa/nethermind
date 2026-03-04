# Research Brief: TRIE-1

## Target — Inline node resolution allocates via fullRlp.ToArray()

When resolving inline trie nodes (nodes < 32 bytes that are embedded directly in
parent RLP rather than stored by hash reference), the code copies the RLP span
into a new heap-allocated byte array. This allocation occurs on every trie
traversal (Get and Set) that encounters an inline child node.

## Current Implementation

The allocation occurs at **3 call sites**, all in `TrieNode.cs`:

### Site 1: `ResolveChildWithChildPath()` — line 1284
```csharp
// TrieNode.cs:1280-1286 (default case in child resolution)
default:
    rlpStream.Position--;
    ReadOnlySpan<byte> fullRlp = rlpStream.PeekNextItem();
    TrieNode child = new(NodeType.Unknown, fullRlp.ToArray());  // ALLOCATION
    data = childOrRef = child;
    break;
```
This is the primary child resolution method called during Get/Set traversal.

### Site 2: `ResolveAllChildBranch()` — line 1352
```csharp
// TrieNode.cs:1349-1356 (fast path for range visitor)
default:
    ReadOnlySpan<byte> fullRlp = rlpStream.PeekNextItem();
    TrieNode child = new(NodeType.Unknown, fullRlp.ToArray());  // ALLOCATION
    rlpStream.SkipItem();
    chCount++;
    output[i] = child;
    break;
```
Used by trie visitors that traverse entire ranges (e.g., snap sync, proofs).

### Site 3: `ChildIterator.ResolveChildWithChildPath()` — line 1470
```csharp
// TrieNode.cs:1466-1472 (ref struct ChildIterator, faster forward iteration)
default:
    _rlpStream.Position--;
    ReadOnlySpan<byte> fullRlp = _rlpStream.PeekNextItem();
    TrieNode child = new(NodeType.Unknown, fullRlp.ToArray());  // ALLOCATION
    data = childOrRef = child;
    break;
```
Used by `CreateChildIterator()` for sequential child iteration during commit.

### How inline nodes work
- In Ethereum's Modified Merkle Patricia Trie, if a child node's RLP encoding
  is < 32 bytes, it is embedded directly in the parent's RLP (not referenced by
  hash). This is common for leaf nodes in lower trie levels and extension nodes
  with short paths.
- When the parent node's RLP is decoded and a child is requested, the code peeks
  the inline RLP span from the parent's `ValueRlpStream` and creates a new
  `TrieNode` with a copy of that data.

### Constructor chain
```
new TrieNode(NodeType.Unknown, fullRlp.ToArray())
  → TrieNode(NodeType nodeType, byte[]? rlp, bool isDirty = false)
    → TrieNode(NodeType nodeType, SpanSource rlp, bool isDirty = false)
       → _rlp = new SpanSource(rlp)   // wraps the byte[]
```
`SpanSource` is a discriminated union struct that holds either a `byte[]` or a
`CappedArraySource` (wrapping `CappedArray<byte>`). It already supports
`CappedArray<byte>` as a backing store.

### Why it copies
The `fullRlp` span points into the parent's `_rlp` backing memory. The child
`TrieNode` needs its own independent copy because:
1. The child outlives the stack frame (stored in `_nodeData[i]`)
2. The parent could be unresolved (its `_rlp` released) while the child is still
   needed
3. The child may be cloned/modified during Set operations

## Call Graph

### Hot callers (block processing path)

```
PatriciaTree.Get()  →  TrieNode.GetChildWithChildPath()
  → ResolveChildWithChildPath() [line 1243]        ← Site 1 (line 1284)

PatriciaTree.SetNew()  →  TrieNode.GetChildWithChildPath()
  → ResolveChildWithChildPath() [line 1243]        ← Site 1 (line 1284)

PatriciaTree.CompactNodeIntoParent()  →  GetChildWithChildPath()
  → ResolveChildWithChildPath()                    ← Site 1

TrieNode.CreateChildIterator()
  → ChildIterator.GetChildWithChildPath()
    → ChildIterator.ResolveChildWithChildPath()     ← Site 3 (line 1470)
```

All of these are called during every trie Get and Set operation — i.e., per
account read, per storage read, per state write during block processing.

### Warm callers (commit/visitor path)
```
TrieNode.ResolveAllChildBranch()                    ← Site 2 (line 1352)
  ← called by trie visitors (snap sync, proofs, range traversal)
```

### Call frequency estimate
- Per block: hundreds to thousands of trie reads (account balance, nonce, code hash,
  storage slots) + hundreds of trie writes (state changes)
- Each traversal from root to leaf visits ~7-8 nodes (trie depth for state trie)
- Inline nodes are most common at depth > 4 (lower levels where leaf values are small)
- Conservative estimate: **500-2000 inline node allocations per block**

### Callers in PatriciaTree.cs
`GetChildWithChildPath` is called at these lines in `PatriciaTree.cs`:
- Line 249: extension child resolution in Get path
- Line 283: trace logging in commit
- Line 596: extension child in Set traversal
- Line 658: collapsing extension in Set
- Line 681: branch child in Set traversal
- Line 779: branch iteration in CompactNodeIntoParent
- Line 812, 834, 835: original node comparison in CompactNodeIntoParent
- Line 903, 916: Get traversal
- Line 960, 974: Get with keepChildRef

## Baseline Benchmark

**No benchmark exists** that specifically measures inline node allocation during
trie traversal. The closest existing benchmarks:

- `PatriciaTreeBenchmarks` (`Nethermind.Benchmark/Store/`) — has `[MemoryDiagnoser]`,
  covers insert/commit/hash/read with 4096-10240 entries, but doesn't isolate
  inline node resolution
- `RlpTrieNodeEncodingBenchmark` — encoding only, not decoding/traversal
- `TrieNodeBenchmark` — object allocation sizes, not traversal patterns

A new `TrieTraversalBenchmark` must be created (see BENCHMARK-INVENTORY.md P0 #4).

## Prior Art

### Geth (Go)
- Geth PR #30932 removed redundant byte copies during node decoding by using
  `decodeNodeUnsafe()` — relies on guaranteeing input buffer immutability
- In Geth's path-based storage, inline nodes are decoded directly from parent RLP
  without separate allocation; the parent byte slice is retained as the backing store
- Key insight: Geth avoids copying by ensuring the parent's byte slice stays alive

### Reth (Rust)
- Uses lazy-loaded sparse tries where inline nodes are embedded within parent RLP
  without separate allocation
- Rust's ownership model (slicing with lifetime tracking) naturally avoids copies
- Arena-like patterns through worker-local memory management

### Key takeaway
Both Geth and Reth avoid the copy by keeping a reference to the parent's backing
memory. In C#, this is achievable if the child's `SpanSource` can reference a
slice of the parent's `SpanSource` backing array.

## Blast Radius

### What changes
- `TrieNode.cs`: 3 call sites (lines 1284, 1352, 1470)
- Potentially `SpanSource.cs`: if adding a slice-backed variant
- No public API changes required

### What depends on current behavior
- The child `TrieNode._rlp` is accessed via `FullRlp`, `RlpStream`, `HasRlp`
- `SpanSource.Span` returns `Span<byte>` — any slice-based solution must still
  provide the correct span over just the inline node's RLP
- `SpanSource.MemorySize` is used for memory accounting — must be updated
- `SpanSource.ToArray()` is called during commit serialization — must work correctly

### Consensus safety
- No consensus risk: the optimization only changes how the same bytes are stored
  in memory, not what bytes are stored
- The inline node's RLP content remains identical
- All decode paths (`ResolveNode`, `DecodeRlp`) work from `SpanSource.Span`,
  which would return the same data regardless of backing
