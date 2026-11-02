# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
    XzLib

xz compression and decompression on BufferIO.

- [`XzWriter`](@ref) compresses a stream of data to .xz.
- [`XzReader`](@ref) decompresses a stream of .xz data.
- [`XzSeekableReader`](@ref) decompresses seekable .xz data with random access.
- [`compress_xz`](@ref) and [`decompress_xz`](@ref) work on whole buffers.
- [`XzError`](@ref) reports liblzma failures.
"""
module XzLib

export XzWriter, XzReader, XzSeekableReader, XzError, compress_xz, decompress_xz

using BufferIO: BufferIO, AbstractBufReader, AbstractBufWriter, BufReader, BufWriter, CursorReader, VecWriter,
    IOError, IOErrorKinds, consume, get_buffer, get_nonempty_buffer, read_all!, shallow_flush
using MemoryViews: ImmutableMemoryView, MemoryView, MutableMemoryView

const DEFAULT_MEM_LIMIT = typemax(UInt64)
const IO_BUFFER_SIZE = 64 * 1024
const NO_BYTES = ImmutableMemoryView(Memory{UInt8}())

memorybudget() = Sys.total_memory() ÷ 4  # for threads and read-ahead, as xz does

function threadcount(threads::Integer)
    0 ≤ threads ≤ LZMA.THREADS_MAX ||
        throw(ArgumentError("threads must be within 0..$(LZMA.THREADS_MAX), with 0 picking automatically"))
    iszero(threads) || return threads
    return max(Int(LZMA.cputhreads()), 1)
end

include("liblzma.jl")
include("error.jl")
include("writer.jl")
include("reader.jl")
include("seekable.jl")

# Byte vectors and files are the common cases; other sources compile on first use.
precompile(compress_xz, (Vector{UInt8},))
precompile(decompress_xz, (Vector{UInt8},))
precompile(XzWriter, (IOStream,))
precompile(write, (XzWriter{BufWriter{IOStream}}, Vector{UInt8}))
precompile(close, (XzWriter{BufWriter{IOStream}},))
for T in (XzReader, XzSeekableReader)
    precompile(T, (IOStream,))
    precompile(BufferIO.fill_buffer, (T{BufReader{IOStream}},))
    precompile(read, (T{BufReader{IOStream}},))
    precompile(read, (T{BufReader{IOStream}}, Int))
    precompile(close, (T{BufReader{IOStream}},))
end
precompile(seek, (XzSeekableReader{BufReader{IOStream}}, Int))

end
