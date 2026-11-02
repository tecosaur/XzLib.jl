# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Both readers have fields `source`, `decoder`, `bytes` (what `get_buffer`
# returns), `error` (thrown by reads until cleared), and `isopen`, and implement
# `refill!` to decode more bytes once `bytes` is empty.

abstract type XzBufReader <: AbstractBufReader end

const FIRST_OUTPUT_WINDOW = 256  # so a small first read need not wait for a full buffer

(T::Type{<:XzBufReader})(io::IO; kwargs...) = T(BufReader(io, IO_BUFFER_SIZE); kwargs...)

function (T::Type{<:XzBufReader})(f, source::Union{IO,AbstractBufReader}; kwargs...)
    reader = T(source; kwargs...)
    try
        f(reader)
    finally
        close(reader)
    end
end

Base.show(io::IO, reader::XzBufReader) = print(io, summary(reader))

BufferIO.get_buffer(reader::XzBufReader) = reader.bytes

function BufferIO.consume(reader::XzBufReader, n::Int)
    @boundscheck 0 ≤ n ≤ length(reader.bytes) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    reader.bytes = @inbounds reader.bytes[n+1:end]
    return nothing
end

BufferIO.fill_buffer(reader::XzBufReader) = if isempty(reader.bytes) decoding(refill!, reader) end

# Run `f(reader)`, keeping any error it throws for later reads.
function decoding(f, reader::XzBufReader)
    isopen(reader) || throw(IOError(IOErrorKinds.ClosedIO))
    isnothing(reader.error) || throw(reader.error)
    try
        f(reader)
    catch err
        reader.error = err
        rethrow()
    end
end

Base.isopen(reader::XzBufReader) = reader.isopen

function Base.close(reader::XzBufReader)
    isopen(reader) || return nothing
    LZMA.free(reader.decoder)
    reader.bytes = NO_BYTES
    reader.isopen = false
    close(reader.source)
end

"""
    XzReader(source::Union{IO, AbstractBufReader}; threads=0, memlimit=typemax(UInt64), bufsize=$(IO_BUFFER_SIZE))
    XzReader(f, source; kwargs...)

Create an `AbstractBufReader` that decompresses the .xz data read from `source`.

`source` may hold several concatenated .xz streams, which are read as one, and
need not be seekable, so pipes and sockets work too. `close` closes `source`.
The second form calls `f` on the reader then closes it. For random access, see
[`XzSeekableReader`](@ref).

# Arguments

- `threads`: number of liblzma decoding threads, or `0` for one per available CPU.
  Blocks decode in parallel only when they record their sizes (see [`XzWriter`](@ref)).
- `memlimit`: memory usage limit in bytes
- `bufsize`: size of the output buffer in bytes

Throws `ArgumentError` for invalid arguments, and `XzError` if the data are
corrupt, after which reads throw the same error.

# Examples

```jldoctest
julia> using XzLib

julia> reader = XzReader(IOBuffer(compress_xz("Hello, world!")));

julia> read(reader, String)
"Hello, world!"
```
"""
mutable struct XzReader{T<:AbstractBufReader} <: XzBufReader
    const source::T
    const decoder::LZMA.Stream
    const buffer::Memory{UInt8}
    bytes::ImmutableMemoryView{UInt8}
    window::Int
    isfinished::Bool
    error::Union{Nothing,Exception}  # never cleared
    isopen::Bool
end

function XzReader(source::AbstractBufReader; threads::Integer=0, memlimit::Integer=DEFAULT_MEM_LIMIT,
                  bufsize::Integer=IO_BUFFER_SIZE)
    memlimit > 0 || throw(ArgumentError("memlimit must be positive"))
    bufsize ≥ 1 || throw(ArgumentError("bufsize must be positive"))
    threads = threadcount(threads)
    decoder = LZMA.Stream()
    ret = if threads == 1
        LZMA.stream_decoder(decoder, memlimit, LZMA.CONCATENATED)
    else
        LZMA.stream_decoder_mt(decoder, LZMA.Mt(;
            flags = LZMA.CONCATENATED, threads,
            memlimit_threading = memorybudget(),
            memlimit_stop = memlimit))
    end
    ret == LZMA.STATUS_OK || throw(XzError(:decode, ret))
    reader = XzReader(
        source, decoder, Memory{UInt8}(undef, bufsize), NO_BYTES, FIRST_OUTPUT_WINDOW, false, nothing, true)
    return finalizer(reader -> LZMA.free(reader.decoder), reader)
end

"""
    decompress_xz(data; kwargs...)::Vector{UInt8}

Decompress the .xz `data`, a byte vector or string. The keyword arguments are
those of [`XzReader`](@ref).
"""
decompress_xz(data; kwargs...) = XzReader(read, CursorReader(data); kwargs...)

Base.position(reader::XzReader) = Int(reader.decoder.total_out) - length(reader.bytes)

# Decodes straight into the result, rather than through the buffer.
function Base.read(reader::XzReader)
    result = collect(reader.bytes)
    consume(reader, length(reader.bytes))
    filled = decoding(reader) do reader
        n = length(result)
        while true
            n == length(result) && resize!(result, max(2n, IO_BUFFER_SIZE))
            made = decode!(reader, MemoryView(result)[n+1:end])
            iszero(made) && return n
            n += made
        end
    end
    return resize!(result, filled)
end

function refill!(reader::XzReader)
    (; buffer) = reader
    made = decode!(reader, MemoryView(buffer)[1:min(reader.window, end)])
    reader.window = min(2 * reader.window, length(buffer))
    reader.bytes = ImmutableMemoryView(buffer)[1:made]
    return made
end

# Returns the bytes decoded into `output`, or 0 at the end of the data.
function decode!(reader::XzReader, output::MutableMemoryView{UInt8})
    (; source, decoder) = reader
    while !reader.isfinished
        input = get_nonempty_buffer(source)
        action = if isnothing(input) LZMA.FINISH else LZMA.RUN end  # FINISH tells the decoder no more streams follow
        used, made, ret = LZMA.code!(decoder, something(input, NO_BYTES), output, action)
        consume(source, used)
        ret in (LZMA.STATUS_OK, LZMA.STREAM_END) || throw(XzError(:decode, ret))
        reader.isfinished = ret == LZMA.STREAM_END
        made > 0 && return made
    end
    return 0
end
