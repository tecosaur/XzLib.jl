# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

const PRESET_DICT_POW2 = (18, 20, 21, 22, 22, 23, 23, 24, 25, 26)  # from lzma_lzma_preset
const CHECKS = (none = LZMA.CHECK_NONE, crc32 = LZMA.CHECK_CRC32, crc64 = LZMA.CHECK_CRC64, sha256 = LZMA.CHECK_SHA256)

"""
    XzWriter(sink::Union{IO, AbstractBufWriter}; level=6, check=:crc64, threads=0, blocksize=nothing, bufsize=$(IO_BUFFER_SIZE))
    XzWriter(f, sink; kwargs...)

Create an `AbstractBufWriter` that writes .xz-compressed data to `sink`.

`flush` ends the current Block, so that everything written so far can be
decoded. `close` finishes the .xz data and closes `sink`. The second form calls
`f` on the writer then closes it, unless `f` throws, in which case the .xz
data are left unfinished so that they don't pass for complete. Likewise, if
encoding or writing to `sink` fails, the writer closes itself and `sink`,
leaving the .xz data unfinished.

# Arguments

- `level`: compression preset, from `0` (fastest) to `9` (smallest)
- `check`: integrity check, one of `:none`, `:crc32`, `:crc64`, or `:sha256`
- `threads`: number of liblzma threads, or `0` for one per available CPU like
  `xz -T0`; either way reduced as needed to keep memory usage within a quarter of RAM
- `blocksize`: uncompressed bytes per Block. The default matches `xz`: three times
  the dictionary size, and at least 1 MiB (24 MiB at level 6). Smaller Blocks compress
  slightly worse but make seeking in [`XzSeekableReader`](@ref) cheaper. `0` writes
  a single Block, on one thread.
- `bufsize`: size of the input buffer in bytes

With one thread, output is written as input arrives. With more, each Block is
written once it is complete, recording its sizes, which lets liblzma decode it
on its own thread.

Throws `ArgumentError` for invalid arguments, and `XzError` if liblzma fails.

# Examples

```jldoctest
julia> using XzLib

julia> path = tempname();

julia> XzWriter(open(path, "w"); level=9) do writer
           write(writer, "Hello, world!")
       end
13

julia> String(decompress_xz(read(path)))
"Hello, world!"
```
"""
mutable struct XzWriter{T<:AbstractBufWriter} <: AbstractBufWriter
    const sink::T
    const encoder::LZMA.Stream
    const blocksize::Int  # typemax(Int) when liblzma splits Blocks
    buffer::Memory{UInt8}
    filled::Int
    blockleft::Int
end

XzWriter(sink::AbstractBufWriter; bufsize::Integer=IO_BUFFER_SIZE, options...) =
    XzWriter(sink, encoderoptions(; options...), bufsize)

function XzWriter(sink::AbstractBufWriter, options::LZMA.Mt, bufsize::Integer)
    bufsize ≥ 1 || throw(ArgumentError("bufsize must be positive"))
    encoder = LZMA.Stream()
    ret = if options.threads == 1
        LZMA.easy_encoder(encoder, options.preset, options.check)
    else
        LZMA.stream_encoder_mt(encoder, options)
    end
    ret == LZMA.STATUS_OK || throw(XzError(:encode, ret))
    blocksize = if options.threads == 1 && options.block_size > 0 Int(options.block_size) else typemax(Int) end
    writer = XzWriter(sink, encoder, blocksize, Memory{UInt8}(undef, bufsize), 0, blocksize)
    return finalizer(writer -> LZMA.free(writer.encoder), writer)
end

XzWriter(io::IO; kwargs...) = XzWriter(BufWriter(io, IO_BUFFER_SIZE); kwargs...)

function XzWriter(f, sink::Union{IO,AbstractBufWriter}; kwargs...)
    writer = XzWriter(sink; kwargs...)
    result = try
        f(writer)
    catch
        release!(writer)
        rethrow()
    end
    close(writer)
    return result
end

"""
    compress_xz(data; kwargs...)::Vector{UInt8}

Compress `data`, anything `write` accepts, to .xz. The keyword arguments are
those of [`XzWriter`](@ref).

# Examples

```jldoctest
julia> using XzLib

julia> compressed = compress_xz("Hello, world!");

julia> String(decompress_xz(compressed))
"Hello, world!"
```
"""
function compress_xz(data; bufsize::Integer=IO_BUFFER_SIZE, options...)
    sink = VecWriter()
    writer = XzWriter(sink, encoderoptions(; datasize = sizeof(data), options...), bufsize)
    write(writer, data)
    close(writer)
    return sink.vec
end

Base.show(io::IO, writer::XzWriter) = print(io, summary(writer))

BufferIO.get_buffer(writer::XzWriter) = MemoryView(writer.buffer)[writer.filled+1:end]

function BufferIO.consume(writer::XzWriter, n::Int)
    @boundscheck 0 ≤ n ≤ length(get_buffer(writer)) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    writer.filled += n
    return nothing
end

BufferIO.grow_buffer(writer::XzWriter) = shallow_flush(writer)

function BufferIO.shallow_flush(writer::XzWriter)
    isopen(writer) || throw(IOError(IOErrorKinds.ClosedIO))
    n = writer.filled
    encode!(writer, LZMA.RUN)
    return n
end

function Base.flush(writer::XzWriter)
    isopen(writer) || throw(IOError(IOErrorKinds.ClosedIO))
    encode!(writer, LZMA.FULL_FLUSH)
    flush(writer.sink)
end

Base.isopen(writer::XzWriter) = !isempty(writer.buffer)

function Base.close(writer::XzWriter)
    isopen(writer) || return nothing
    encode!(writer, LZMA.FINISH)
    release!(writer)
end

function encoderoptions(; level::Integer=6, check::Symbol=:crc64, threads::Integer=0,
                        blocksize::Union{Integer,Nothing}=nothing, datasize::Integer=typemax(Int))
    0 ≤ level ≤ 9 || throw(ArgumentError("compression level must be within 0..9"))
    check in keys(CHECKS) || throw(ArgumentError("check must be one of $(join(keys(CHECKS), ", "))"))
    blocksize = something(blocksize, max(3 << PRESET_DICT_POW2[level + 1], 1 << 20))
    0 ≤ blocksize ≤ LZMA.BLOCK_SIZE_MAX || throw(ArgumentError("blocksize must be within 0..$(LZMA.BLOCK_SIZE_MAX)"))
    threads = threadcount(threads)
    issingle = iszero(blocksize) || datasize ≤ blocksize  # threads share out whole Blocks
    options = LZMA.Mt(;
        threads = if issingle 1 else threads end,
        block_size = blocksize, preset = level, check = CHECKS[check])
    while options.threads > 1 && LZMA.stream_encoder_mt_memusage(options) > memorybudget()
        options.threads -= 1
    end
    return options
end

# After a failure the encoder's state is unknown, so release the writer, leaving the .xz data unfinished.
function encode!(writer::XzWriter, action::Cint)
    input = ImmutableMemoryView(writer.buffer)[1:writer.filled]
    try
        while !isempty(input)
            if iszero(writer.blockleft)
                run!(writer, NO_BYTES, LZMA.FULL_FLUSH)
                writer.blockleft = writer.blocksize
            end
            used = run!(writer, input[1:min(end, writer.blockleft)], LZMA.RUN)
            writer.blockleft -= used
            input = input[used+1:end]
        end
        action == LZMA.RUN || run!(writer, NO_BYTES, action)
    catch
        release!(writer)
        rethrow()
    end
    action == LZMA.FULL_FLUSH && (writer.blockleft = writer.blocksize)
    writer.filled = 0
end

# Returns the input used.
function run!(writer::XzWriter, input::ImmutableMemoryView{UInt8}, action::Cint)
    (; sink, encoder) = writer
    used = 0
    while true
        output = get_nonempty_buffer(sink)
        isnothing(output) && throw(IOError(IOErrorKinds.WriterFull))
        Δin, Δout, ret = LZMA.code!(encoder, input[used+1:end], output, action)
        consume(sink, Δout)
        used += Δin
        ret == LZMA.STREAM_END && return used
        ret == LZMA.STATUS_OK || throw(XzError(:encode, ret))
        action == LZMA.RUN && used == length(input) && return used
    end
end

function release!(writer::XzWriter)
    isopen(writer) || return nothing
    LZMA.free(writer.encoder)
    writer.buffer = Memory{UInt8}()
    writer.filled = 0
    close(writer.sink)
end
