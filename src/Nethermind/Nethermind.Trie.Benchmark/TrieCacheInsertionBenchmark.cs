// SPDX-FileCopyrightText: 2024 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using System;
using System.Threading;
using System.Threading.Tasks;
using BenchmarkDotNet.Attributes;
using Nethermind.Core.Crypto;
using Nethermind.Core.Test;
using Nethermind.Db;
using Nethermind.Logging;
using Nethermind.Trie.Pruning;

namespace Nethermind.Trie.Benchmark;

/// <summary>
/// Measures DirtyNodesCache insertion throughput, specifically the Interlocked
/// counter overhead in IncrementMemory / IncrementMemoryUsedByDirtyCache.
/// Each FindCachedOrUnknown call with a unique hash triggers a cache-miss insert.
/// </summary>
[MemoryDiagnoser]
public class TrieCacheInsertionBenchmark
{
    private Hash256[] _hashes = null!;
    private TrieStore _trieStore = null!;

    [Params(1000, 10000)]
    public int NodeCount { get; set; }

    [GlobalSetup]
    public void Setup()
    {
        _hashes = new Hash256[NodeCount];
        byte[] buffer = new byte[32];
        for (int i = 0; i < NodeCount; i++)
        {
            // Deterministic unique hashes
            BitConverter.TryWriteBytes(buffer.AsSpan(0, 4), i);
            _hashes[i] = new Hash256(buffer);
        }

        CreateTrieStore();
    }

    [IterationSetup]
    public void IterationSetup()
    {
        // Fresh TrieStore per iteration so every FindCachedOrUnknown is a cache miss
        _trieStore.Dispose();
        CreateTrieStore();
    }

    private void CreateTrieStore()
    {
        TestFinalizedStateProvider finalizedStateProvider = new TestFinalizedStateProvider(64);
        PruningConfig pruningConfig = new PruningConfig();
        _trieStore = new TrieStore(
            new NodeStorage(new MemDb()),
            No.Pruning,
            No.Persistence,
            finalizedStateProvider,
            pruningConfig,
            LimboLogs.Instance);
        finalizedStateProvider.TrieStore = _trieStore;
    }

    [Benchmark(Baseline = true)]
    public TrieNode SingleThread_Insert()
    {
        TrieNode last = null!;
        TreePath path = TreePath.Empty;
        for (int i = 0; i < NodeCount; i++)
        {
            last = _trieStore.FindCachedOrUnknown(null, in path, _hashes[i]);
        }
        return last;
    }

    [Benchmark]
    public void MultiThread_Insert_4()
    {
        RunParallel(4);
    }

    [Benchmark]
    public void MultiThread_Insert_8()
    {
        RunParallel(8);
    }

    private void RunParallel(int threadCount)
    {
        int perThread = NodeCount / threadCount;
        Task[] tasks = new Task[threadCount];
        for (int t = 0; t < threadCount; t++)
        {
            int start = t * perThread;
            int end = (t == threadCount - 1) ? NodeCount : start + perThread;
            tasks[t] = Task.Run(() =>
            {
                TreePath path = TreePath.Empty;
                for (int i = start; i < end; i++)
                {
                    _trieStore.FindCachedOrUnknown(null, in path, _hashes[i]);
                }
            });
        }
        Task.WaitAll(tasks);
    }

    [GlobalCleanup]
    public void Cleanup()
    {
        _trieStore.Dispose();
    }
}
