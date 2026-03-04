// SPDX-FileCopyrightText: 2025 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;

namespace Nethermind.Core;

/// <summary>
/// Thread-local pool of exact-sized byte arrays for storage values (1-32 bytes).
/// Avoids per-SSTORE/TSTORE GC allocations by reusing arrays across blocks.
/// Arrays are returned to the pool when the storage provider resets after block processing.
/// </summary>
internal static class StorageValuePool
{
    public const int MaxSize = 32;
    private const int MaxPooledPerSize = 512;

    [ThreadStatic]
    private static List<byte[]>?[]? t_pools;

    /// <summary>
    /// Rent an exact-sized byte array and copy the source span into it.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static byte[] RentAndCopy(ReadOnlySpan<byte> source)
    {
        int length = source.Length;
        byte[] buffer = TryRent(length) ?? new byte[length];
        source.CopyTo(buffer);
        return buffer;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static byte[]? TryRent(int length)
    {
        if ((uint)(length - 1) >= MaxSize) return null;

        List<byte[]>?[]? pools = t_pools;
        if (pools is null) return null;

        List<byte[]>? pool = pools[length];
        if (pool is null || pool.Count == 0) return null;

        // Pop from end (O(1) removal)
        int lastIndex = pool.Count - 1;
        byte[] result = pool[lastIndex];
        pool.RemoveAt(lastIndex);
        return result;
    }

    /// <summary>
    /// Return an exact-sized byte array to the pool for reuse.
    /// Only accepts arrays of size 1-32 (storage value range after WithoutLeadingZeros).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void Return(byte[] array)
    {
        int length = array.Length;
        if ((uint)(length - 1) >= MaxSize) return;

        List<byte[]>?[]? pools = t_pools ??= new List<byte[]>?[MaxSize + 1];
        List<byte[]>? pool = pools[length] ??= new List<byte[]>();

        if (pool.Count < MaxPooledPerSize)
        {
            pool.Add(array);
        }
    }
}
