// SPDX-FileCopyrightText: 2026 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using System;
using System.Threading;
using System.Threading.Tasks;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Columns;
using BenchmarkDotNet.Configs;
using BenchmarkDotNet.Jobs;
using BenchmarkDotNet.Toolchains.InProcess.NoEmit;
using Nethermind.Blockchain;
using Nethermind.Core;
using Nethermind.Core.Crypto;
using Nethermind.Core.Specs;
using Nethermind.Core.Test;
using Nethermind.Evm.CodeAnalysis;
using Nethermind.Evm.GasPolicy;
using Nethermind.Evm.State;
using Nethermind.Evm.Tracing;
using Nethermind.Int256;
using Nethermind.Logging;
using Nethermind.Specs;
using Nethermind.Specs.Forks;

namespace Nethermind.Evm.Benchmark;

/// <summary>
/// Focused benchmark measuring SSTORE and TSTORE allocation overhead.
/// Uses InProcess mode to avoid BDN build timeout on large dependency graphs.
/// Tracks both execution time and heap allocations via [MemoryDiagnoser].
/// </summary>
[Config(typeof(SstoreConfig))]
[MemoryDiagnoser]
public unsafe class SstoreAllocationBenchmark
{
    private const int OpsPerInvoke = 4096;

    private delegate*<VirtualMachine<EthereumGasPolicy>, ref EvmStack, ref EthereumGasPolicy, ref int, EvmExceptionType>[] _opcodes = null!;
    private EvmOpcodesBenchmark.BenchmarkVm _vm = null!;
    private byte[] _stackBuffer = null!;
    private int _stackOffset;
    private int _stackLength;
    private EthereumGasPolicy _gas;
    private ExecutionEnvironment _env = null!;
    private VmState<EthereumGasPolicy> _vmState = null!;
    private IWorldState _stateProvider = null!;
    private IDisposable _stateScope = null!;
    private UInt256[] _storageKeys = null!;
    private int _iterationId;

    private static readonly UInt256 ValueA = UInt256.Parse("0x6F1D2C3B4A59687766554433221100FFEEDDCCBBAA99887766554433221100FF");
    private static readonly UInt256 ValueB = UInt256.Parse("0x5A0F9E8D7C6B5A4938271605F4E3D2C1B0A99887766554433221100FFEDCBA98");
    private static readonly UInt256 StorageBase = new(2_000_000UL);

    [Params("SSTORE", "TSTORE")]
    public string OpName { get; set; } = "SSTORE";

    private Instruction Opcode => OpName == "SSTORE" ? Instruction.SSTORE : Instruction.TSTORE;

    [GlobalSetup]
    public void Setup()
    {
        (_stackBuffer, _stackOffset, _stackLength) = EvmOpcodesBenchmark.CreateStackBuffer();
        _gas = EthereumGasPolicy.FromLong(long.MaxValue);

        IReleaseSpec spec = Fork.GetLatest();
        _vm = new EvmOpcodesBenchmark.BenchmarkVm(new NoOpBlockhashProvider(), MainnetSpecProvider.Instance, LimboLogs.Instance);
        _stateProvider = TestWorldStateFactory.CreateForTest();
        _stateScope = _stateProvider.BeginScope(IWorldState.PreGenesis);

        Address address = Address.SystemUser;
        _stateProvider.CreateAccount(address, UInt256.One);

        // Seed storage keys so SSTORE benchmarks a realistic trie (not only empty slots)
        int keyCount = OpsPerInvoke * 4;
        _storageKeys = new UInt256[keyCount];
        for (int i = 0; i < keyCount; i++)
        {
            UInt256 key = StorageBase + (UInt256)(ulong)i;
            _storageKeys[i] = key;
            UInt256 initialValue = (i & 1) == 0 ? ValueA : ValueB;
            byte[] bytes = new byte[32];
            initialValue.ToBigEndian(bytes);
            _stateProvider.Set(new StorageCell(address, key), bytes);
        }
        _stateProvider.Commit(spec);

        EthereumCodeInfoRepository codeInfoRepository = new(_stateProvider);

        BlockHeader header = new(
            Keccak.Zero, Keccak.Zero, address, UInt256.One,
            MainnetSpecProvider.PragueActivation.BlockNumber,
            long.MaxValue, 1UL, [], 0, 0);
        _vm.SetBlockExecutionContext(new BlockExecutionContext(header, spec, UInt256.Zero));
        _vm.SetTxExecutionContext(new TxExecutionContext(address, codeInfoRepository, null, 0));
        _vm.SetExecutionDependencies(_stateProvider, codeInfoRepository);

        byte[] bytecode = new byte[64];
        bytecode[0] = (byte)Instruction.JUMPDEST;
        _env = ExecutionEnvironment.Rent(
            codeInfo: new CodeInfo(bytecode),
            executingAccount: address, caller: address, codeSource: address,
            callDepth: 0, transferValue: 0, value: 0, inputData: default);
        _vmState = VmState<EthereumGasPolicy>.RentTopLevel(
            EthereumGasPolicy.FromLong(long.MaxValue),
            ExecutionType.TRANSACTION, _env,
            new StackAccessTracker(), Snapshot.Empty);
        _vmState.InitializeStacks();

        _vm.SetVmState(_vmState);
        _vm.SetTracer(NullTxTracer.Instance);

        _opcodes = EvmInstructions.GenerateOpCodes<EthereumGasPolicy, OffFlag>(spec);

        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
    }

    [GlobalCleanup]
    public void Cleanup()
    {
        _vmState?.Dispose();
        _env?.Dispose();
        _stateScope?.Dispose();
    }

    [IterationSetup]
    public void IterationSetup()
    {
        _iterationId++;
        // Pre-seed transient storage so internal collections are pre-sized
        if (Opcode is Instruction.TLOAD or Instruction.TSTORE)
        {
            Address address = _env.ExecutingAccount;
            byte[] seedValue = new byte[32];
            ValueA.ToBigEndian(seedValue);
            for (int i = 0; i < OpsPerInvoke; i++)
            {
                long sequence = ((long)_iterationId * OpsPerInvoke) + i;
                int index = (int)(sequence % _storageKeys.Length);
                StorageCell cell = new(address, _storageKeys[index]);
                _stateProvider.SetTransientState(in cell, seedValue);
            }
            if (Opcode == Instruction.TSTORE)
            {
                _stateProvider.ResetTransient();
            }
        }
    }

    [IterationCleanup]
    public void IterationCleanup()
    {
        _stateProvider.Reset(resetBlockChanges: true);
        CacheCodeInfoRepository.Clear();
    }

    [Benchmark(OperationsPerInvoke = OpsPerInvoke)]
    public EvmExceptionType Execute()
    {
        Span<byte> stackSpan = _stackBuffer.AsSpan(_stackOffset, _stackLength);
        EvmStack stack = new(2, NullTxTracer.Instance, stackSpan);
        EvmExceptionType result = EvmExceptionType.None;
        int opcodeIndex = (int)Opcode;

        for (int i = 0; i < OpsPerInvoke; i++)
        {
            long sequence = ((long)_iterationId * OpsPerInvoke) + i;
            int keyIndex = (int)(sequence % _storageKeys.Length);

            // Write key and value to stack
            UInt256 key = _storageKeys[keyIndex];
            UInt256 value = ((i + _iterationId) & 1) == 0 ? ValueA : ValueB;
            Span<byte> slot0 = stackSpan.Slice(0, 32);
            Span<byte> slot1 = stackSpan.Slice(32, 32);
            value.ToBigEndian(slot0);  // value at slot 0 (popped second)
            key.ToBigEndian(slot1);    // key at slot 1 (popped first)

            stack.Head = 2;
            EthereumGasPolicy gas = _gas;
            int pc = 0;
            result = _opcodes[opcodeIndex](_vm, ref stack, ref gas, ref pc);
        }

        return result;
    }

    private class NoOpBlockhashProvider : IBlockhashProvider
    {
        public Hash256 GetBlockhash(BlockHeader currentBlock, long number, IReleaseSpec spec) => Keccak.Zero;
        public Task Prefetch(BlockHeader currentBlock, CancellationToken token) => Task.CompletedTask;
    }

    private class SstoreConfig : ManualConfig
    {
        public SstoreConfig()
        {
            // InProcess avoids BDN build timeout on large dependency graphs.
            // 1 launch x 10 iterations = 10 data points per parameter.
            AddJob(Job.Default
                .WithToolchain(InProcessNoEmitToolchain.Instance)
                .WithInvocationCount(1)
                .WithUnrollFactor(1)
                .WithLaunchCount(1)
                .WithWarmupCount(3)
                .WithIterationCount(10)
                .WithGcForce(true));
            AddColumn(StatisticColumn.Min);
            AddColumn(StatisticColumn.Max);
            AddColumn(StatisticColumn.Median);
            AddColumn(StatisticColumn.P90);
            AddColumn(StatisticColumn.P95);
        }
    }
}
