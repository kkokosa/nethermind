// SPDX-FileCopyrightText: 2025 Demerzel Solutions Limited
// SPDX-License-Identifier: LGPL-3.0-only

using System;
using System.Threading.Tasks;
using Nethermind.Core.Extensions;


namespace Nethermind.Core.Buffers;

/// <summary>
/// Represents a source of a span.
/// </summary>
/// <remarks>
/// The design is similar to the <see cref="ValueTask"/> where a single field contains
/// a value of two types. In this case it can be an array, or an actual implementation of a <see cref="ISpanSource"/>,
/// like <see cref="TinyArray"/>.
/// </remarks>
public readonly struct SpanSource : ISpanSource, IEquatable<SpanSource>
{
    /// <summary>
    /// A union reference, discriminated by its type.
    /// It can be either byte[], or an actual implementation of a <see cref="ISpanSource"/>.
    /// </summary>
    private readonly object _obj;

    public SpanSource(byte[] array)
    {
        _obj = array;
    }

    public SpanSource(CappedArray<byte> capped)
    {
        _obj = new CappedArraySource(capped);
    }

    /// <summary>
    /// Creates a span source referencing a slice of an existing byte array, avoiding a copy.
    /// Used for inline trie nodes that share the parent node's backing array.
    /// </summary>
    public SpanSource(byte[] array, int offset, int length)
    {
        _obj = new SlicedArraySource(array, offset, length);
    }

    public static implicit operator SpanSource(byte[] bytes) => new(bytes);

    public int MemorySize
    {
        get
        {
            const int objSize = MemorySizes.RefSize;

            object obj = _obj;

            if (obj is null)
                return objSize;

            if (obj is byte[] array)
            {
                return ReferenceEquals(array, Empty._obj)
                    ? objSize
                    : objSize + MemorySizes.ArrayOverhead + array.Length;
            }

            return obj is ISpanSource source ? objSize + source.MemorySize : 0;
        }
    }

    public int Length
    {
        get
        {
            object obj = _obj;
            if (obj is byte[] array)
                return array.Length;

            if (obj is null) return 0;
            return ((ISpanSource)obj).Length;
        }
    }

    public Span<byte> Span
    {
        get
        {
            object obj = _obj;

            if (obj is null)
                return Span<byte>.Empty;

            if (obj is byte[] array)
                return array.AsSpan();

            return ((ISpanSource)obj).Span;
        }
    }

    public bool IsNotNull => !IsNull;
    public bool IsNull => _obj == null;
    public bool IsNullOrEmpty
    {
        get
        {
            object obj = _obj;

            if (obj is null)
                return true;

            if (obj is byte[] array)
                return array.Length == 0;

            return ((ISpanSource)obj).Length == 0;
        }
    }

    public bool IsNotNullOrEmpty => !IsNullOrEmpty;

    public static readonly SpanSource Empty = new([]);

    public static readonly SpanSource Null = default;

    public bool Equals(SpanSource other)
    {
        Span<byte> comparand = other.Span;

        object obj = _obj;
        if (obj is byte[] array)
        {
            return array.AsSpan().SequenceEqual(comparand);
        }

        return ((ISpanSource)obj).Span.SequenceEqual(comparand);
    }

    /// <summary>
    /// A <see cref="IsNull"/> aware span source. Returns null if the underlying is null or materializes the array.
    /// </summary>
    /// <returns></returns>
    public byte[]? ToArray()
    {
        object? obj = _obj;
        return obj is null ? null : obj as byte[] ?? ((ISpanSource)obj).Span.ToArray();
    }

    public bool TryGetCappedArray(out CappedArray<byte> cappedArray)
    {
        if (_obj is CappedArraySource source)
        {
            cappedArray = source.Capped;
            return true;
        }

        cappedArray = default;
        return false;
    }

    /// <summary>
    /// Tries to get the backing byte[] from this SpanSource.
    /// Returns true if backed by a plain byte[] (not CappedArray or sliced).
    /// Used to create zero-copy slices for inline trie nodes.
    /// </summary>
    public bool TryGetArray(out byte[] array)
    {
        if (_obj is byte[] backing)
        {
            array = backing;
            return true;
        }

        array = null!;
        return false;
    }

    private sealed class CappedArraySource : ISpanSource
    {
        public readonly CappedArray<byte> Capped;

        public CappedArraySource(CappedArray<byte> capped)
        {
            Capped = capped;
        }

        public int Length => Capped.Length;

        public bool SequenceEqual(ReadOnlySpan<byte> other) => Capped.AsSpan().SequenceEqual(other);

        public Span<byte> Span => Capped.AsSpan();
        public int MemorySize => MemorySizes.SmallObjectOverhead +
                                 MemorySizes.ArrayOverhead +
                                 Capped.UnderlyingLength;
    }

    /// <summary>
    /// References a slice of an existing byte[] without copying.
    /// The shared array is kept alive by the GC reference — safe because
    /// inline trie nodes are small (&lt;32 bytes) while parent arrays are ~200-500 bytes.
    /// </summary>
    private sealed class SlicedArraySource : ISpanSource
    {
        private readonly byte[] _array;
        private readonly int _offset;
        private readonly int _length;

        public SlicedArraySource(byte[] array, int offset, int length)
        {
            _array = array;
            _offset = offset;
            _length = length;
        }

        public int Length => _length;

        public Span<byte> Span => _array.AsSpan(_offset, _length);

        // Only report object overhead — the array is shared with the parent node
        public int MemorySize => MemorySizes.SmallObjectOverhead +
                                 MemorySizes.RefSize +
                                 sizeof(int) * 2;
    }

    public override string ToString()
    {
        object obj = _obj;
        if (obj is null)
            return "null";

        if (obj is byte[] array)
        {
            return $"array: {array.ToHexString()}";
        }

        return $"source: {((ISpanSource)obj).Span.ToHexString()}";
    }
}
