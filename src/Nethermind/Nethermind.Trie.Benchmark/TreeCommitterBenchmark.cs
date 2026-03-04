using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Jobs;
using Nethermind.Logging;

namespace Nethermind.Trie.Benchmark
{
    [MemoryDiagnoser]
    [DryJob(RuntimeMoniker.NetCoreApp31)]
    public class TreeStoreBenchmark
    {
        static TreeStoreBenchmark()
        {
            _ = LimboLogs.Instance.GetClassLogger(); // lazy-init
        }

        [Benchmark]
        public TrieNode Trie_committer_with_one_node()
        {
            TrieNode trieNode = new TrieNode(NodeType.Unknown); // 56B
            return trieNode;
        }
    }
}
