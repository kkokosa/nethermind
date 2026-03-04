// SPDX-FileCopyrightText: 2025 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using System;
using BenchmarkDotNet.Attributes;
using Nethermind.Core.Crypto;
using Nethermind.Core.Extensions;
using Nethermind.Core.Test;
using Nethermind.Db;
using Nethermind.Logging;
using Nethermind.Serialization.Rlp;
using Nethermind.Trie.Pruning;

namespace Nethermind.Trie.Benchmark;

/// <summary>
/// Benchmarks trie Get traversal that encounters inline child nodes (&lt;32 bytes RLP).
/// Measures the allocation cost of resolving inline nodes from parent RLP.
/// Target: TRIE-1 optimization — zero-copy slice vs byte[] copy for inline nodes.
/// </summary>
[MemoryDiagnoser]
public class TrieTraversalBenchmark
{
    private const int EntryCount = 1024;

    private PatriciaTree _committedTree = null!;
    private Hash256[] _keys = null!;
    private MemDb _db = null!;
    private TrieStore _trieStore = null!;
    private ITrieNodeCache _trieNodeCache = null!;

    [GlobalSetup]
    public void Setup()
    {
        _db = new MemDb();
        _trieNodeCache = new TrieNodeCache(NullLogManager.Instance);
        _trieStore = new TrieStore(
            _trieNodeCache,
            _db,
            new DepthAndMemoryBased(128, 128.MB()),
            No.Persistence,
            NullLogManager.Instance);

        // Use small values (1-8 bytes) to force inline nodes in the trie.
        // When leaf RLP (path + value) < 32 bytes, the node is embedded inline
        // in the parent rather than stored by hash reference.
        PatriciaTree tree = new PatriciaTree(
            _trieStore.GetTrieStore(null),
            Keccak.EmptyTreeHash,
            true,
            NullLogManager.Instance);

        _keys = new Hash256[EntryCount];
        for (int i = 0; i < EntryCount; i++)
        {
            // Keccak of sequential ints produces well-distributed keys
            Hash256 key = Keccak.Compute(i.ToBigEndianByteArray());
            _keys[i] = key;

            // Small value (4 bytes) ensures leaf nodes are inline (<32 bytes RLP)
            byte[] value = i.ToBigEndianByteArray();
            tree.Set(key.Bytes, new Rlp(value));
        }

        tree.Commit();
        tree.UpdateRootHash();

        // Create a fresh tree from the committed state — forces node resolution from RLP
        _committedTree = new PatriciaTree(
            _trieStore.GetTrieStore(null),
            tree.RootHash,
            false,
            NullLogManager.Instance);
    }

    [GlobalCleanup]
    public void Cleanup()
    {
        _trieStore.Dispose();
        _db.Dispose();
    }

    /// <summary>
    /// Reads all entries from a committed trie. Each Get traverses ~7-8 nodes from
    /// root to leaf. Inline nodes at lower levels trigger the allocation site under test.
    /// </summary>
    [Benchmark(OperationsPerInvoke = EntryCount)]
    public int ReadAllEntries()
    {
        int found = 0;
        for (int i = 0; i < EntryCount; i++)
        {
            ReadOnlySpan<byte> result = _committedTree.Get(_keys[i].Bytes);
            if (!result.IsEmpty)
                found++;
        }

        return found;
    }

    /// <summary>
    /// Reads entries from a deserialized tree (cold cache) — every node must be resolved
    /// from stored RLP, maximizing inline node resolution.
    /// </summary>
    [Benchmark(OperationsPerInvoke = EntryCount)]
    public int ReadWithDeserialization()
    {
        // Create a fresh tree each invocation to ensure cold node cache
        PatriciaTree coldTree = new PatriciaTree(
            new RawScopedTrieStore(_db),
            _committedTree.RootHash,
            false,
            NullLogManager.Instance);

        int found = 0;
        for (int i = 0; i < EntryCount; i++)
        {
            ReadOnlySpan<byte> result = coldTree.Get(_keys[i].Bytes);
            if (!result.IsEmpty)
                found++;
        }

        return found;
    }
}
