# Hypothesis: TRIE-1

## Candidate 1 (Recommended) — Slice-backed SpanSource for inline nodes

### Change
Add a `SlicedArraySource` variant to `SpanSource` that references a slice of
the parent node's backing `byte[]` instead of copying. At the 3 allocation sites,
instead of `fullRlp.ToArray()`, compute the offset/length within the parent's
`_rlp` backing array and construct a `SpanSource` that holds a reference to the
same array with offset+length metadata.

**Exact modifications:**

1. **`SpanSource.cs`** — Add a new `ISpanSource` implementation:
   ```csharp
   private sealed class SlicedArraySource : ISpanSource
   {
       private readonly byte[] _array;
       private readonly int _offset;
       private readonly int _length;
       // Span => _array.AsSpan(_offset, _length)
   }
   ```
   Add a new constructor: `SpanSource(byte[] array, int offset, int length)`

2. **`TrieNode.cs:1284,1352,1470`** — Replace:
   ```csharp
   TrieNode child = new(NodeType.Unknown, fullRlp.ToArray());
   ```
   With logic that extracts the parent's backing array + computes offset:
   ```csharp
   // Parent _rlp is backed by byte[], compute slice
   SpanSource childRlp = CreateSlicedSource(parentRlp, rlpStream.Position, fullRlp.Length);
   TrieNode child = new(NodeType.Unknown, childRlp);
   ```

### Mechanism
- **Zero-copy**: The inline node's RLP data stays in the parent's array. No heap
  allocation for the byte[] copy.
- **Parent lifetime**: The child holds a reference to the parent's backing array,
  keeping it alive via GC. This is safe because:
  - The parent `TrieNode` stores `_rlp` as a `SpanSource` which holds a `byte[]`
  - Even if the parent is unreferenced, the child keeps the array alive
  - The array may be larger than needed (parent's full RLP), but inline nodes are
    small (< 32 bytes) while parent branch RLP is typically 200-500 bytes, so the
    overhead is modest
- **Memory accounting**: `SlicedArraySource.MemorySize` should report only the
  object overhead (not the shared array), since the array is owned by the parent

### Expected impact
- **Eliminates ~500-2000 small heap allocations per block** (2-31 bytes each)
- Estimated **5-15% reduction in GC pressure** on the trie traversal hot path
- Overall block processing improvement: **2-5%** (trie traversal is ~20-30% of
  block time, and this eliminates allocations in the inner loop)
- The `SlicedArraySource` object itself is still a heap allocation (~32 bytes),
  but it avoids the separate byte[] allocation + copy. Net savings: 1 object +
  copy cost per inline node.

### Difficulty: M
- Touches `SpanSource.cs` (add new source type) and `TrieNode.cs` (3 sites)
- Need to verify `SpanSource.MemorySize`, `SpanSource.Equals`, and
  `SpanSource.ToArray()` all work correctly with the sliced variant
- Need to handle the case where parent `_rlp` is backed by `CappedArraySource`
  (not just raw `byte[]`)

### Risks
1. **Memory retention**: The child holds the entire parent byte[] alive. If a
   single inline child survives while the parent is collected, the parent's full
   RLP (~200-500 bytes) stays in memory. This is a small overhead per node.
2. **CappedArray case**: If the parent's `_rlp` uses `CappedArraySource` (from
   a buffer pool), the slice would keep the pooled array alive, preventing return
   to pool. Need to detect this case and fall back to copy.
3. **Correctness of Span**: The `SlicedArraySource.Span` must return exactly the
   inline node's bytes. Off-by-one in offset calculation would corrupt trie data.

### Files
- `src/Nethermind/Nethermind.Core/Buffers/SpanSource.cs`
- `src/Nethermind/Nethermind.Trie/TrieNode.cs` (lines 1284, 1352, 1470)

### Benchmark plan
1. Create `TrieTraversalInlineNodeBenchmark` in `Nethermind.Trie.Benchmark`:
   - Build a trie with small leaf values (force inline nodes)
   - Benchmark Get traversal with `[MemoryDiagnoser]`
   - Measure: allocated bytes, Gen0 collections, mean time
2. Run `PatriciaTreeBenchmarks` (existing) with `--memory` for baseline
3. Compare before/after on both benchmarks
4. Run `BlockProcessingBenchmark.Transfers_200` for end-to-end validation

---

## Candidate 2 — ArrayPool-based small buffer for inline node RLP

### Change
Instead of `fullRlp.ToArray()`, rent a buffer from `ArrayPool<byte>.Shared` and
wrap it in `CappedArray<byte>` → `SpanSource`. Return the buffer when the
`TrieNode` is unresolved or garbage collected.

**Exact modifications:**

1. **`TrieNode.cs:1284,1352,1470`** — Replace:
   ```csharp
   TrieNode child = new(NodeType.Unknown, fullRlp.ToArray());
   ```
   With:
   ```csharp
   byte[] rented = ArrayPool<byte>.Shared.Rent(fullRlp.Length);
   fullRlp.CopyTo(rented);
   CappedArray<byte> capped = new(rented, fullRlp.Length);
   TrieNode child = new(NodeType.Unknown, new SpanSource(capped));
   ```

2. **`TrieNode.cs`** — Add return logic in `UnresolveChild()` or when `_rlp` is
   replaced, to return the rented buffer.

### Mechanism
- `ArrayPool.Rent` reuses buffers, avoiding GC pressure from frequent small
  allocations
- `CappedArray<byte>` tracks the logical length vs rented length
- Still copies data, but avoids GC allocation overhead

### Expected impact
- **Reduces GC pressure** but still has the copy cost
- Estimated **3-8% reduction in GC pressure** on trie traversal
- Less than Candidate 1 because the copy still occurs
- `ArrayPool.Rent` for sizes < 32 bytes typically returns a 32-byte or 64-byte
  buffer (some waste)

### Difficulty: M
- Need reliable return-to-pool semantics (TrieNode doesn't implement IDisposable)
- Risk of pool exhaustion if buffers aren't returned
- `SpanSource` already supports `CappedArray<byte>`, so no changes needed there

### Risks
1. **Buffer return**: TrieNode is not disposable. Buffers would leak if not
   returned explicitly. Would need to track rented buffers carefully.
2. **Pool overhead**: For very small buffers (2-10 bytes), `ArrayPool.Rent` may
   have higher overhead than direct allocation due to bucket management.
3. **Complexity**: Managing buffer lifecycle across node resolution/unresolving
   adds error-prone complexity.

### Files
- `src/Nethermind/Nethermind.Trie/TrieNode.cs` (lines 1284, 1352, 1470 + unresolve logic)

### Benchmark plan
Same as Candidate 1.

---

## Candidate 3 — Direct span constructor avoiding intermediate byte[]

### Change
Add a constructor `TrieNode(NodeType nodeType, ReadOnlySpan<byte> rlp)` that
internally creates the `SpanSource` without the caller needing to call `.ToArray()`.
Inside, use the most efficient backing store available.

This is a minor refactor that centralizes the allocation decision, making it
easier to swap in Candidate 1 or 2 later.

**Exact modifications:**

1. **`TrieNode.cs`** — Add constructor:
   ```csharp
   public TrieNode(NodeType nodeType, ReadOnlySpan<byte> rlp)
       : this(nodeType, new SpanSource(rlp.ToArray()))
   { }
   ```
   (Note: a constructor like this already exists at line 289-291, but takes a
   `Hash256 keccak` parameter. Inline nodes don't have a keccak.)

2. **`TrieNode.cs:1284,1352,1470`** — Simplify to:
   ```csharp
   TrieNode child = new(NodeType.Unknown, fullRlp);
   ```

### Mechanism
- No direct performance gain — still allocates internally
- But centralizes the allocation, making future optimization (slice, pool, etc.)
  a single-point change
- Improves code clarity

### Expected impact
- **0% direct improvement** — this is a refactoring prerequisite
- Enables Candidate 1 or 2 as a follow-up with minimal diff

### Difficulty: S
- Single new constructor + 3 call sites simplified

### Risks
- None — pure refactor with no behavioral change

### Files
- `src/Nethermind/Nethermind.Trie/TrieNode.cs`

### Benchmark plan
Not needed — no performance change expected.

---

## Ranking by ROI

| Rank | Candidate | Impact | Difficulty | ROI |
|------|-----------|--------|------------|-----|
| 1 | **Candidate 1: Slice-backed SpanSource** | High (5-15% trie GC reduction) | M | Best |
| 2 | **Candidate 2: ArrayPool small buffers** | Med (3-8% trie GC reduction) | M | Moderate |
| 3 | **Candidate 3: Span constructor refactor** | None (enables others) | S | Low standalone |

**Recommended approach**: Implement Candidate 3 first (S difficulty, clean API),
then Candidate 1 on top (the slice optimization). This gives a clean two-commit
progression where the first is trivially correct and the second contains the
actual optimization.

## Key concern for Candidate 1

The main risk is the `CappedArraySource` case: when the parent's `_rlp` is
backed by a pooled `CappedArray<byte>`, creating a slice would prevent pool
return. The implementation must detect this via `SpanSource.TryGetCappedArray()`
and fall back to `.ToArray()` in that case. Checking the codebase:
- `ResolveUnknownNode()` at line 370 uses `new SpanSource(fullRlp)` where
  `fullRlp` is `byte[]` from `tree.LoadRlp()` — raw array, not pooled
- `TryResolveNode()` at line 426 uses `new SpanSource(fullRlp)` — same
- So the parent `_rlp` is typically a raw `byte[]`, making the slice approach safe
  for the common case
