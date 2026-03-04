// SPDX-FileCopyrightText: 2025 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using System;
using System.Collections.Generic;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Columns;
using BenchmarkDotNet.Configs;
using BenchmarkDotNet.Exporters.Json;
using BenchmarkDotNet.Jobs;
using BenchmarkDotNet.Toolchains.InProcess.NoEmit;
using Nethermind.Blockchain;
using Nethermind.Core;
using Nethermind.Core.Extensions;
using Nethermind.Core.Specs;
using Nethermind.Core.Test;
using Nethermind.Core.Test.Builders;
using Nethermind.Evm.CodeAnalysis;
using Nethermind.Evm.State;
using Nethermind.Evm.Tracing;
using Nethermind.Evm.TransactionProcessing;
using Nethermind.Int256;
using Nethermind.Logging;
using Nethermind.Specs;
using Nethermind.Specs.Forks;

namespace Nethermind.Evm.Benchmark;

/// <summary>
/// Measures allocation and throughput of nested CALL chains that return data via
/// RETURN/REVERT. Each call frame copies return data from pooled EVM memory;
/// this benchmark quantifies the cost of the per-frame .ToArray() allocation.
///
/// Uses a self-recursive contract: reads a depth counter from calldata, calls
/// itself with depth-1, and propagates the return data upward. At depth 0 it
/// returns a fixed-size payload.
///
/// Parameterized by call depth and return data size.
/// </summary>
[Config(typeof(NestedCallReturnConfig))]
[MemoryDiagnoser]
[JsonExporterAttribute.FullCompressed]
public class NestedCallReturnBenchmark
{
    private class NestedCallReturnConfig : ManualConfig
    {
        public NestedCallReturnConfig()
        {
            AddJob(Job.MediumRun.WithToolchain(InProcessNoEmitToolchain.Instance));
            AddColumn(StatisticColumn.Median);
            AddColumn(StatisticColumn.P95);
        }
    }

    private const int N = 200;

    private static readonly IReleaseSpec Spec = Osaka.Instance;
    private static readonly ISpecProvider SpecProvider = new TestSpecProvider(Osaka.Instance);

    [Params(5, 10, 20)]
    public int CallDepth { get; set; }

    [Params(32, 128)]
    public int ReturnDataSize { get; set; }

    private IWorldState _stateProvider = null!;
    private IDisposable _stateScope = null!;
    private ITransactionProcessor _processor = null!;
    private BlockHeader _header = null!;
    private Transaction _tx = null!;

    /// <summary>
    /// Builds bytecode for a self-recursive contract.
    /// Reads depth from calldata[0..31]. If depth == 0, returns a payload of
    /// <paramref name="retSize"/> bytes. Otherwise calls itself with depth-1
    /// and relays the return data.
    /// </summary>
    private static byte[] BuildRecursiveContract(int retSize)
    {
        List<byte> code = new();

        // Load depth from calldata[0..31]
        code.Add((byte)Instruction.PUSH1); code.Add(0);
        code.Add((byte)Instruction.CALLDATALOAD);

        // DUP1, ISZERO — check if depth == 0
        code.Add((byte)Instruction.DUP1);
        code.Add((byte)Instruction.ISZERO);

        // PUSH1 <leaf_offset>, JUMPI — jump to leaf if depth == 0
        code.Add((byte)Instruction.PUSH1);
        int leafOffsetIdx = code.Count;
        code.Add(0); // placeholder, patched below
        code.Add((byte)Instruction.JUMPI);

        // --- RELAY path: depth > 0 ---
        // Compute depth-1 and store at memory[0..31] as calldata for self-call
        code.Add((byte)Instruction.PUSH1); code.Add(1);
        code.Add((byte)Instruction.SWAP1);
        code.Add((byte)Instruction.SUB);
        code.Add((byte)Instruction.PUSH1); code.Add(0);
        code.Add((byte)Instruction.MSTORE);

        // CALL(gas, addr, value, argsOff, argsLen, retOff, retLen)
        PushSize(code, retSize);          // retLen
        code.Add((byte)Instruction.PUSH1); code.Add(0);   // retOff
        code.Add((byte)Instruction.PUSH1); code.Add(32);  // argsLen
        code.Add((byte)Instruction.PUSH1); code.Add(0);   // argsOff
        code.Add((byte)Instruction.PUSH1); code.Add(0);   // value
        code.Add((byte)Instruction.ADDRESS);               // to = self
        code.Add((byte)Instruction.GAS);                   // gas = remaining
        code.Add((byte)Instruction.CALL);
        code.Add((byte)Instruction.POP);                   // discard success flag

        // Return the subcall's output (CALL wrote it to memory[0..retSize])
        PushSize(code, retSize);
        code.Add((byte)Instruction.PUSH1); code.Add(0);
        code.Add((byte)Instruction.RETURN);

        // --- LEAF path: depth == 0 ---
        int leafOffset = code.Count;
        if (leafOffset > 255) throw new InvalidOperationException("Leaf offset exceeds PUSH1 range");
        code[leafOffsetIdx] = (byte)leafOffset;

        code.Add((byte)Instruction.JUMPDEST);
        code.Add((byte)Instruction.POP); // pop the duplicated depth (0)

        // Fill memory[0..retSize] with 0x42 bytes
        for (int i = 0; i < retSize; i += 32)
        {
            code.Add((byte)Instruction.PUSH32);
            for (int j = 0; j < 32; j++)
                code.Add(0x42);
            code.Add((byte)Instruction.PUSH1); code.Add((byte)i);
            code.Add((byte)Instruction.MSTORE);
        }

        // Return retSize bytes from memory offset 0
        PushSize(code, retSize);
        code.Add((byte)Instruction.PUSH1); code.Add(0);
        code.Add((byte)Instruction.RETURN);

        return code.ToArray();
    }

    /// <summary>
    /// Pushes a size value using PUSH1 (0..255) or PUSH2 (256..65535).
    /// </summary>
    private static void PushSize(List<byte> code, int size)
    {
        if (size <= 255)
        {
            code.Add((byte)Instruction.PUSH1);
            code.Add((byte)size);
        }
        else
        {
            code.Add((byte)Instruction.PUSH2);
            code.Add((byte)(size >> 8));
            code.Add((byte)(size & 0xFF));
        }
    }

    [GlobalSetup]
    public void GlobalSetup()
    {
        _stateProvider = TestWorldStateFactory.CreateForTest();
        _stateScope = _stateProvider.BeginScope(IWorldState.PreGenesis);

        // Fund the sender
        _stateProvider.CreateAccount(TestItem.AddressA, 10_000.Ether());

        // Deploy the self-recursive contract at AddressB
        byte[] contractCode = BuildRecursiveContract(ReturnDataSize);
        _stateProvider.CreateAccount(TestItem.AddressB, UInt256.Zero);
        _stateProvider.InsertCode(TestItem.AddressB, contractCode, Spec);

        _stateProvider.Commit(Spec);
        _stateProvider.CommitTree(0);

        _header = Build.A.BlockHeader
            .WithNumber(1)
            .WithGasLimit(100_000_000)
            .WithBaseFee(10.GWei())
            .WithStateRoot(_stateProvider.StateRoot)
            .TestObject;

        EthereumCodeInfoRepository codeInfo = new(_stateProvider);
        EthereumVirtualMachine vm = new(
            new TestBlockhashProvider(),
            SpecProvider,
            LimboLogs.Instance);
        _processor = new EthereumTransactionProcessor(
            BlobBaseFeeCalculator.Instance,
            SpecProvider,
            _stateProvider,
            vm,
            codeInfo,
            LimboLogs.Instance);

        // Calldata: 32-byte big-endian depth counter
        byte[] calldata = new byte[32];
        calldata[31] = (byte)CallDepth;

        _tx = Build.A.Transaction
            .WithTo(TestItem.AddressB)
            .WithData(calldata)
            .WithGasLimit(100_000_000)
            .WithGasPrice(20.GWei())
            .SignedAndResolved(TestItem.PrivateKeyA)
            .TestObject;

        // Pre-warm all paths
        _processor.SetBlockExecutionContext(_header);
        _processor.CallAndRestore(_tx, NullTxTracer.Instance);
    }

    [GlobalCleanup]
    public void GlobalCleanup() => _stateScope.Dispose();

    /// <summary>
    /// Exercises a chain of N nested CALLs, each returning <see cref="ReturnDataSize"/>
    /// bytes via RETURN. Measures per-call-chain cost including return data allocation.
    /// </summary>
    [Benchmark(OperationsPerInvoke = N)]
    public TransactionResult NestedCallReturn()
    {
        TransactionResult result = default;
        for (int i = 0; i < N; i++)
            result = _processor.CallAndRestore(_tx, NullTxTracer.Instance);
        return result;
    }
}
