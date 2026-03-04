// SPDX-FileCopyrightText: 2024 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using System;
using System.Runtime.InteropServices;
using BenchmarkDotNet.Attributes;
using Nethermind.Core;
using Nethermind.Evm.Tracing;

namespace Nethermind.Evm.Benchmark;

[MemoryDiagnoser]
public class EvmPopAddressBenchmarks
{
    // Simulate a realistic mix: a small set of "hot" addresses that repeat frequently (DeFi pattern)
    private const int UniqueAddressCount = 8;
    private const int OpsPerInvoke = 16;

    private byte[] _stack = null!;
    private Address[] _addresses = null!;

    [GlobalSetup]
    public void GlobalSetup()
    {
        _stack = new byte[(EvmStack.MaxStackSize + EvmStack.RegisterLength * 32) * 1024];
        _addresses = new Address[UniqueAddressCount];

        // Create a set of distinct addresses
        for (int i = 0; i < UniqueAddressCount; i++)
        {
            byte[] bytes = new byte[Address.Size];
            bytes[0] = (byte)(i + 1);
            bytes[19] = (byte)(i + 0xAA);
            _addresses[i] = new Address(bytes);
        }
    }

    /// <summary>
    /// Measures PopAddress throughput when the same addresses repeat (cache-hit scenario).
    /// This simulates a DeFi block where CALL targets like WETH/USDC appear repeatedly.
    /// </summary>
    [Benchmark(OperationsPerInvoke = OpsPerInvoke)]
    public Address PopAddress_RepeatedAddresses()
    {
        EvmStack stack = new(0, NullTxTracer.Instance, _stack.AsSpan());
        Address last = null;

        // Push and pop the same small set of addresses multiple times
        for (int round = 0; round < OpsPerInvoke / UniqueAddressCount; round++)
        {
            for (int i = 0; i < UniqueAddressCount; i++)
            {
                stack.PushAddress<OffFlag>(_addresses[i]);
            }
            for (int i = 0; i < UniqueAddressCount; i++)
            {
                last = stack.PopAddress();
            }
        }

        return last;
    }

    /// <summary>
    /// Measures PopAddress with a single address pushed/popped repeatedly.
    /// Best-case scenario for caching — 100% hit rate after first call.
    /// </summary>
    [Benchmark(OperationsPerInvoke = OpsPerInvoke)]
    public Address PopAddress_SingleAddress()
    {
        EvmStack stack = new(0, NullTxTracer.Instance, _stack.AsSpan());
        Address last = null;

        for (int i = 0; i < OpsPerInvoke; i++)
        {
            stack.PushAddress<OffFlag>(_addresses[0]);
            last = stack.PopAddress();
        }

        return last;
    }
}
