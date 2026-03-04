// SPDX-FileCopyrightText: 2025 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using System;
using BenchmarkDotNet.Attributes;
using Nethermind.Core.Crypto;
using Nethermind.Core.Extensions;
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

    private Hash256[] _keys = null!;
    private MemDb _db = null!;
    private Hash256 _rootHash = null!;

    [GlobalSetup]
    public void Setup()
    {
        _db = new MemDb();

        // Use small values (1-8 bytes) to force inline nodes in the trie.
        // When leaf RLP (path + value) < 32 bytes, the node is embedded inline
        // in the parent rather than stored by hash reference.
        PatriciaTree tree = new PatriciaTree(
            _db,
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
        _rootHash = tree.RootHash;
    }

    [GlobalCleanup]
    public void Cleanup()
    {
        _db.Dispose();
    }

    /// <summary>
    /// Reads entries from a cold tree — every node must be resolved from stored RLP,
    /// maximizing inline node resolution allocations.
    /// </summary>
    [Benchmark(OperationsPerInvoke = EntryCount)]
    public int ReadWithDeserialization()
    {
        // Create a fresh tree each invocation to ensure cold node cache
        PatriciaTree coldTree = new PatriciaTree(
            _db,
            _rootHash,
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
