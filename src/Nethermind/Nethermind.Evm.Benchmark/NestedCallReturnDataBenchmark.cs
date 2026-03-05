// SPDX-FileCopyrightText: 2025 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Columns;
using BenchmarkDotNet.Configs;
using BenchmarkDotNet.Jobs;
using BenchmarkDotNet.Toolchains.InProcess.NoEmit;
using Nethermind.Blockchain;
using Nethermind.Core;
using Nethermind.Core.Extensions;
using Nethermind.Core.Specs;
using Nethermind.Core.Test;
using Nethermind.Core.Test.Builders;
using Nethermind.Evm.CodeAnalysis;
using Nethermind.Evm.Tracing;
using Nethermind.Evm.TransactionProcessing;
using Nethermind.Int256;
using Nethermind.Logging;
using Nethermind.Specs;
using Nethermind.Specs.Forks;
using System;

namespace Nethermind.Evm.Benchmark;

/// <summary>
/// Measures the allocation cost of RETURN/REVERT data in nested call chains.
/// The inner contract returns data of a parameterized size, and the caller
/// loops calling it repeatedly, exercising the return-data copy path.
/// </summary>
[Config(typeof(NestedCallConfig))]
[MemoryDiagnoser]
public class NestedCallReturnDataBenchmark
{
    private class NestedCallConfig : ManualConfig
    {
        public NestedCallConfig()
        {
            AddJob(Job.MediumRun.WithToolchain(InProcessNoEmitToolchain.Instance));
            AddColumn(StatisticColumn.Median);
            AddColumn(StatisticColumn.P95);
        }
    }

    private const int N = 200;

    private static readonly IReleaseSpec Spec = Osaka.Instance;
    private static readonly ISpecProvider SpecProvider = new TestSpecProvider(Osaka.Instance);

    // Inner contract: stores data in memory and RETURNs it.
    // Size is configured via the ReturnDataSize parameter.
    private static byte[] BuildInnerContract(int returnSize)
    {
        Prepare code = Prepare.EvmCode;
        // Fill memory with non-zero data so RETURN copies real bytes
        for (int offset = 0; offset < returnSize; offset += 32)
        {
            code.PushData(0xABCDEF01_23456789); // 8-byte value, zero-extended to 32
            code.PushData(offset);
            code.Op(Instruction.MSTORE);
        }
        code.PushData(returnSize); // length
        code.PushData(0);          // offset
        code.Op(Instruction.RETURN);
        return code.Done;
    }

    // Caller contract: calls the inner contract in a gas-limited loop, reading return data.
    // Uses CALL with retSize=returnSize so the EVM copies return data into caller memory.
    private static byte[] BuildCallerContract(Address innerAddr, int returnSize)
    {
        // JUMPDEST
        // PUSH retSize  PUSH 0  PUSH 0  PUSH 0  PUSH 0  PUSH20 addr  GAS  CALL  POP
        // PUSH 0  JUMP
        Prepare code = Prepare.EvmCode;
        code.Op(Instruction.JUMPDEST);     // offset 0
        code.PushData(returnSize);         // retSize
        code.PushData(0);                  // retOffset
        code.PushData(0);                  // argsSize
        code.PushData(0);                  // argsOffset
        code.PushData(0);                  // value
        code.PushData(innerAddr);          // target
        code.Op(Instruction.GAS);          // gasLimit = all remaining
        code.Op(Instruction.CALL);
        code.Op(Instruction.POP);          // discard success flag
        code.PushData(0);                  // jump back to JUMPDEST
        code.Op(Instruction.JUMP);
        return code.Done;
    }

    private static readonly Address InnerAddr = TestItem.AddressB;
    private static readonly Address CallerAddr = TestItem.AddressC;

    [Params(0, 32, 256)]
    public int ReturnDataSize { get; set; }

    private IWorldState _stateProvider = null!;
    private IDisposable _stateScope = null!;
    private ITransactionProcessor _processor = null!;
    private BlockHeader _header = null!;
    private Transaction _callTx = null!;

    [GlobalSetup]
    public void GlobalSetup()
    {
        _stateProvider = TestWorldStateFactory.CreateForTest();
        _stateScope = _stateProvider.BeginScope(IWorldState.PreGenesis);

        // Fund sender
        _stateProvider.CreateAccount(TestItem.AddressA, 10_000.Ether());

        // Deploy inner contract (returns ReturnDataSize bytes)
        byte[] innerCode = BuildInnerContract(ReturnDataSize);
        _stateProvider.CreateAccount(InnerAddr, UInt256.Zero);
        _stateProvider.InsertCode(InnerAddr, innerCode, Spec);

        // Deploy caller contract (loops calling inner)
        byte[] callerCode = BuildCallerContract(InnerAddr, ReturnDataSize);
        _stateProvider.CreateAccount(CallerAddr, UInt256.Zero);
        _stateProvider.InsertCode(CallerAddr, callerCode, Spec);

        _stateProvider.Commit(Spec);
        _stateProvider.CommitTree(0);

        _header = Build.A.BlockHeader
            .WithNumber(1)
            .WithGasLimit(30_000_000)
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

        // Transaction: call the caller contract with enough gas for many nested calls
        _callTx = Build.A.Transaction
            .WithTo(CallerAddr)
            .WithGasLimit(10_000_000)
            .WithGasPrice(20.GWei())
            .SignedAndResolved(TestItem.PrivateKeyA)
            .TestObject;

        // Pre-warm
        _processor.SetBlockExecutionContext(_header);
        _processor.CallAndRestore(_callTx, NullTxTracer.Instance);
    }

    [GlobalCleanup]
    public void GlobalCleanup()
    {
        _stateScope?.Dispose();
    }

    [Benchmark]
    public void NestedCallsWithReturnData()
    {
        for (int i = 0; i < N; i++)
        {
            _processor.CallAndRestore(_callTx, NullTxTracer.Instance);
        }
    }
}
