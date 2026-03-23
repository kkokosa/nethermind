-- Migration 003: Add BlockProcessingBenchmark entries to benchmark_registry
-- These track full-pipeline block processing performance across all optimization areas.

INSERT OR IGNORE INTO benchmark_registry (full_name, short_name, area, weight, is_key_benchmark)
VALUES
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.EmptyBlock', 'BP:EmptyBlock', 'bp', 1.0, 1),
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.SingleTransfer', 'BP:SingleTransfer', 'bp', 1.0, 0),
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.Transfers_50', 'BP:Transfers_50', 'bp', 1.5, 0),
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.Transfers_200', 'BP:Transfers_200', 'bp', 2.0, 1),
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.Eip1559_200', 'BP:Eip1559_200', 'bp', 1.5, 0),
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.AccessList_50', 'BP:AccessList_50', 'bp', 1.0, 0),
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.ContractDeploy_10', 'BP:ContractDeploy_10', 'bp', 1.0, 0),
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.ContractCall_200', 'BP:ContractCall_200', 'bp', 2.0, 1),
    ('Nethermind.Evm.Benchmark.BlockProcessingBenchmark.MixedBlock', 'BP:MixedBlock', 'bp', 3.0, 1);
