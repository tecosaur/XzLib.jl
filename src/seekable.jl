# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Offsets are from the start of the .xz data.
struct XzBlock
    compressed_offset::Int
    uncompressed_offset::Int
    total_size::Int
    unpadded_size::Int
    uncompressed_size::Int
    check::Cint
end

struct XzIndex
    blocks::Vector{XzBlock}
    uncompressed_size::Int
end

struct Readahead
    block::Int
    input::Memory{UInt8}
    output::Memory{UInt8}
    task::Task
    cancelled::Threads.Atomic{Bool}
end

const LONG_READ = 256 * 1024     # read sequentially before decoding ahead speculatively
const AHEAD_FACTOR = 4           # speculate this many times as far ahead as has been read
const OUTPUT_CHUNK = 256 * 1024  # per liblzma call, so workers soon notice GC and cancellation

"""
    XzSeekableReader(source::Union{IO, AbstractBufReader}; threads=0, memlimit=typemax(UInt64), bufsize=$(IO_BUFFER_SIZE))
    XzSeekableReader(f, source; kwargs...)

Create a seekable `AbstractBufReader` that decompresses the .xz data in `source`.

The .xz data run from the current position of `source` to its end, and `source`
must be seekable, since the reader first reads the Index at the end of the data.
`close` closes `source`. The second form calls `f` on the reader then closes it.

`seek`, `skip`, `position`, and `filesize` all work in uncompressed offsets.
Seeking itself is cheap. The next read decodes from the start of the Block
holding its first byte, so its cost depends on the file's Block size (see
`blocksize` in [`XzWriter`](@ref)), while a forward seek within the current
Block continues decoding rather than restarting. Once reading proves
sequential, up to `threads` of the following Blocks are decoded ahead on worker
tasks, in parallel when Julia has several threads.

Wrap the reader in `BufferIO.IOReader` to pass it where a `Base.IO` is expected.

# Arguments

- `source`: seekable IO holding .xz data
- `threads`: maximum number of Blocks to decode ahead, or `0` for one per Julia thread,
  with `1` decoding only on the reading task
- `memlimit`: memory usage limit per Block decoder in bytes
- `bufsize`: size of the output buffer in bytes

Throws `ArgumentError` for invalid arguments, `XzError` if the .xz Index
cannot be read, and `XzError` while reading if the data are corrupt, after
which reads throw until the next `seek`.

# Examples

```jldoctest
julia> using XzLib

julia> data = repeat(b"0123456789", 100_000);

julia> reader = XzSeekableReader(IOBuffer(compress_xz(data; blocksize=100_000)));

julia> seek(reader, 654_321);

julia> String(read(reader, 4))
"1234"
```
"""
mutable struct XzSeekableReader{T<:AbstractBufReader} <: XzBufReader
    const source::T
    const origin::Int
    const index::XzIndex
    const decoder::LZMA.Stream
    const options::LZMA.Block  # referred to by `decoder` while it runs
    const buffer::Memory{UInt8}
    const queue::Vector{Readahead}
    const spares::Vector{Memory{UInt8}}
    const workers::Int
    const memlimit::UInt64
    bytes::ImmutableMemoryView{UInt8}
    held::Memory{UInt8}  # Readahead output backing `bytes`, if any
    next::Int            # Block after the one being read
    isdecoding::Bool     # whether `decoder` is part way through Block `next - 1`
    outpos::Int          # uncompressed position just past `bytes`
    target::Int          # bytes before this are discarded
    readstart::Int       # where reading last became sequential
    wanted::Int          # where the reads under way end, if known
    window::Int
    error::Union{Nothing,Exception}  # thrown until the next seek
    isopen::Bool
end

function XzSeekableReader(source::AbstractBufReader; threads::Integer=0,
                          memlimit::Integer=DEFAULT_MEM_LIMIT, bufsize::Integer=IO_BUFFER_SIZE)
    threads ≥ 0 || throw(ArgumentError("threads must be non-negative, with 0 for one per Julia thread"))
    memlimit > 0 || throw(ArgumentError("memlimit must be positive"))
    bufsize ≥ 1 || throw(ArgumentError("bufsize must be positive"))
    origin = position(source)
    index = readindex(source, origin)
    largest = maximum(b -> b.total_size + b.uncompressed_size, index.blocks; init = 1)
    ahead = if iszero(threads) Threads.nthreads() else threads end
    workers = if ahead > 1 min(ahead, memorybudget() ÷ largest) else 0 end
    reader = XzSeekableReader(
        source, origin, index, LZMA.Stream(), LZMA.Block(), Memory{UInt8}(undef, bufsize), Readahead[],
        Memory{UInt8}[], Int(workers), UInt64(memlimit), NO_BYTES, Memory{UInt8}(),
        1, false, 0, 0, 0, 0, FIRST_OUTPUT_WINDOW, nothing, true)
    return finalizer(reader) do reader
        cancel!(reader)
        LZMA.free(reader.decoder)
    end
end

function Base.show(io::IO, reader::XzSeekableReader)
    (; index) = reader
    print(io, summary(reader), "(", length(index.blocks), " blocks, ",
          index.uncompressed_size, " bytes, threads=", max(reader.workers, 1), ")")
end

Base.filesize(reader::XzSeekableReader) = reader.index.uncompressed_size
Base.position(reader::XzSeekableReader) = max(reader.outpos - length(reader.bytes), reader.target)
Base.read(reader::XzSeekableReader) = read(reader, filesize(reader) - position(reader))  # allocates once
BufferIO.relative_seek(reader::XzSeekableReader, delta::Int) = seek(reader, position(reader) + delta)

# Reads that know their length let `readahead!` start every Block they need at once.
Base.read(reader::XzSeekableReader, n::Integer) =
    (expect!(reader, n); @invoke read(reader::AbstractBufReader, n::Integer))
Base.read!(reader::XzSeekableReader, A::AbstractArray{UInt8}) =
    (expect!(reader, length(A)); @invoke read!(reader::AbstractBufReader, A))
Base.readbytes!(reader::XzSeekableReader, b::AbstractVector{UInt8}, n::Integer=length(b)) =
    (expect!(reader, n); @invoke readbytes!(reader::AbstractBufReader, b, n::Integer))
BufferIO.read_into!(reader::XzSeekableReader, dst::MutableMemoryView{UInt8}) =
    (expect!(reader, length(dst)); @invoke BufferIO.read_into!(reader::AbstractBufReader, dst))
BufferIO.read_all!(reader::XzSeekableReader, dst::MutableMemoryView{UInt8}) =
    (expect!(reader, length(dst)); @invoke BufferIO.read_all!(reader::AbstractBufReader, dst))
BufferIO.unsafe_read_all!(reader::XzSeekableReader, p::Ptr{UInt8}, n::Int) =
    (expect!(reader, n); @invoke BufferIO.unsafe_read_all!(reader::AbstractBufReader, p, n))

function Base.seek(reader::XzSeekableReader, pos::Integer)
    isopen(reader) || throw(IOError(IOErrorKinds.ClosedIO))
    (; index, queue) = reader
    0 ≤ pos ≤ index.uncompressed_size || throw(IOError(IOErrorKinds.BadSeek))
    isintact = isnothing(reader.error)  # a failed read leaves `decoder`, `next`, and `outpos` stale
    reader.error = nothing
    start = reader.outpos - length(reader.bytes)
    if isintact && reader.target ≤ start ≤ pos ≤ reader.outpos
        consume(reader, pos - start)
        return reader
    end
    0 < pos - position(reader) ≤ LONG_READ || (reader.readstart = pos)  # a short hop forward reads on
    reader.target = reader.wanted = pos
    reader.bytes = NO_BYTES
    k = if pos == index.uncompressed_size length(index.blocks) + 1 else blockat(index, pos) end
    isintact && reader.isdecoding && k == reader.next - 1 && pos ≥ reader.outpos && return reader
    while !isempty(queue) && first(queue).block < k
        popfirst!(queue).cancelled[] = true
    end
    isempty(queue) || first(queue).block == k || cancel!(reader)
    reader.isdecoding = false
    reader.next = k
    reader.outpos = if k > length(index.blocks)
        index.uncompressed_size
    else
        index.blocks[k].uncompressed_offset
    end
    reader.window = FIRST_OUTPUT_WINDOW
    return reader
end

function Base.close(reader::XzSeekableReader)
    cancel!(reader)
    empty!(reader.spares)
    @invoke close(reader::XzBufReader)
end

function readindex(source::AbstractBufReader, origin::Int)
    stream = LZMA.Stream()
    index = Ref(C_NULL)
    try
        ret = LZMA.file_info_decoder(stream, index, typemax(UInt64), filesize(source) - origin)
        while ret == LZMA.STATUS_OK
            input = something(get_nonempty_buffer(source), NO_BYTES)
            used, _, ret = LZMA.code!(stream, input, MemoryView(UInt8[]))
            consume(source, used)
            if ret == LZMA.SEEK_NEEDED
                seek(source, origin + Int(stream.seek_pos))
                ret = LZMA.STATUS_OK
            end
        end
        ret == LZMA.STREAM_END || throw(XzError(:index, ret))
        return XzIndex(index[])
    finally
        LZMA.free(stream)
        index[] == C_NULL || LZMA.index_end(index[])
    end
end

function XzIndex(index::Ptr{Cvoid})
    iter = Ref{LZMA.IndexIter}()
    LZMA.index_iter_init(iter, index)
    blocks = XzBlock[]
    while !LZMA.index_iter_next(iter, LZMA.INDEX_ITER_BLOCK)
        (; stream, block) = iter[]
        push!(blocks, XzBlock(
            block.compressed_file_offset, block.uncompressed_file_offset, block.total_size,
            block.unpadded_size, block.uncompressed_size,
            unsafe_load(Ptr{LZMA.StreamFlags}(stream.flags)).check))
    end
    return XzIndex(blocks, sum(b -> b.uncompressed_size, blocks; init = 0))
end

blockat(index::XzIndex, pos::Integer) =
    searchsortedlast(index.blocks, XzBlock(0, pos, 0, 0, 0, 0), by = b -> b.uncompressed_offset)

function refill!(reader::XzSeekableReader)
    (; index, queue, spares) = reader
    isempty(reader.held) || push!(spares, reader.held)
    reader.held = Memory{UInt8}()
    while true
        readahead!(reader)
        if reader.isdecoding
            n = decode!(reader)
            n > 0 && return n
        end
        k = reader.next
        k > length(index.blocks) && return 0
        reader.next += 1
        if isempty(queue) || first(queue).block != k
            startblock!(reader, k)
            continue
        end
        (; input, output, task) = popfirst!(queue)
        err = fetch(task)
        err isa XzError && throw(err)
        push!(spares, input)
        (; uncompressed_offset, uncompressed_size) = index.blocks[k]
        reader.held = output
        reader.outpos = uncompressed_offset + uncompressed_size
        reader.bytes = ImmutableMemoryView(output)[max(reader.target - uncompressed_offset, 0)+1:uncompressed_size]
        isempty(reader.bytes) || return length(reader.bytes)
    end
end

function startblock!(reader::XzSeekableReader, k::Int)
    (; source) = reader
    block = reader.index.blocks[k]
    seeksource!(reader, block.compressed_offset)
    header = peekbytes(source, (Int(first(peekbytes(source, 1, k))) + 1) * 4, k)
    consume(source, initblock!(reader.decoder, reader.options, block, k, header, reader.memlimit))
    reader.outpos = block.uncompressed_offset
    reader.isdecoding = true
end

# Returns the bytes made available, or 0 once the Block ends.
function decode!(reader::XzSeekableReader)
    (; source, decoder, options, buffer) = reader
    k = reader.next - 1
    block = reader.index.blocks[k]
    consumed() = Int(options.header_size + decoder.total_in)  # of the Block's compressed bytes
    seeksource!(reader, block.compressed_offset + consumed())
    while true
        isdiscarding = reader.outpos < reader.target
        room = min(length(buffer), if isdiscarding reader.target - reader.outpos else reader.window end)
        input = peekbytes(source, 1, k)[1:min(end, block.total_size - consumed())]
        used, made, ret = LZMA.code!(decoder, input, MemoryView(buffer)[1:room])
        consume(source, used)
        reader.outpos += made
        ret == LZMA.STREAM_END && (reader.isdecoding = false)
        ret == LZMA.STATUS_OK && used + made == 0 && (ret = LZMA.DATA_ERROR)  # the Index says the Block has ended
        ret in (LZMA.STATUS_OK, LZMA.STREAM_END) || throw(XzError(:decode, k, ret))
        if !isdiscarding && made > 0
            reader.window = min(2 * reader.window, length(buffer))
            reader.bytes = ImmutableMemoryView(buffer)[1:made]
            return made
        end
        reader.isdecoding || return 0
    end
end

# Decode ahead what reads are known to need, and once reading is sequential,
# at least one Block.
function readahead!(reader::XzSeekableReader)
    (; index, queue, outpos, readstart) = reader
    issequential = outpos - readstart ≥ LONG_READ
    horizon = max(reader.wanted, if issequential outpos + AHEAD_FACTOR * (outpos - readstart) else 0 end)
    k = if isempty(queue) reader.next + !reader.isdecoding else last(queue).block + 1 end
    while length(queue) < reader.workers && k ≤ length(index.blocks) &&
          (index.blocks[k].uncompressed_offset < horizon || issequential && isempty(queue))
        block = index.blocks[k]
        seeksource!(reader, block.compressed_offset)
        input, output = spare!(reader, block.total_size), spare!(reader, block.uncompressed_size)
        read_all!(reader.source, MemoryView(input)[1:block.total_size]) == block.total_size ||
            throw(XzError(:read, k, LZMA.BUF_ERROR))
        cancelled = Threads.Atomic{Bool}(false)
        task = Threads.@spawn decodeblock($input, $output, $block, $k, $(reader.memlimit), $cancelled)
        push!(queue, Readahead(k, input, output, task, cancelled))
        k += 1
    end
end

function decodeblock(input::Memory{UInt8}, output::Memory{UInt8}, block::XzBlock, k::Int,
                     memlimit::UInt64, cancelled::Threads.Atomic{Bool})
    stream, options = LZMA.Stream(), LZMA.Block()
    try
        inpos = initblock!(stream, options, block, k, ImmutableMemoryView(input), memlimit)
        outpos = 0
        GC.@preserve options while !cancelled[]
            yield()  # or a worker on the reading task's thread stalls it
            room = min(OUTPUT_CHUNK, block.uncompressed_size - outpos)
            used, made, ret = LZMA.code!(stream, ImmutableMemoryView(input)[inpos+1:block.total_size],
                                    MemoryView(output)[outpos+1:outpos+room])
            inpos += used
            outpos += made
            ret == LZMA.STREAM_END && return nothing
            ret == LZMA.STATUS_OK && used + made == 0 && (ret = LZMA.DATA_ERROR)
            ret == LZMA.STATUS_OK || throw(XzError(:decode, k, ret))
        end
    catch err
        err isa XzError || rethrow()
        return err  # for the reading task to throw
    finally
        LZMA.free(stream)
    end
end

# Returns the header's size.
function initblock!(stream::LZMA.Stream, options::LZMA.Block, block::XzBlock, k::Int,
                    header::ImmutableMemoryView{UInt8}, memlimit::UInt64)
    filters = Memory{LZMA.Filter}(undef, LZMA.FILTERS_MAX + 1)
    options.version = 1
    options.check = block.check
    options.header_size = (UInt32(first(header)) + 1) * 4
    options.filters = pointer(filters)
    start() = if LZMA.block_compressed_size(options, block.unpadded_size) != LZMA.STATUS_OK ||
                 options.uncompressed_size ∉ (LZMA.VLI_UNKNOWN, block.uncompressed_size)
        LZMA.DATA_ERROR
    elseif LZMA.raw_decoder_memusage(options.filters) > memlimit
        LZMA.MEMLIMIT_ERROR
    else
        options.uncompressed_size = block.uncompressed_size
        LZMA.block_decoder(stream, options)
    end
    GC.@preserve header filters begin
        ret = LZMA.block_header_decode(options, pointer(header))  # frees the filters if it fails
        if ret == LZMA.STATUS_OK
            ret = start()
            LZMA.filters_free(options.filters)
        end
    end
    ret == LZMA.STATUS_OK || throw(XzError(:decode, k, ret))
    return Int(options.header_size)
end

expect!(reader::XzSeekableReader, n::Integer) =
    reader.wanted = max(reader.wanted, position(reader) + clamp(n, 0, filesize(reader) - position(reader)))

function seeksource!((; source, origin)::XzSeekableReader, pos::Int)
    position(source) == origin + pos || seek(source, origin + pos)
end

peekbytes(source::AbstractBufReader, n::Int, k::Int) =
    @something(get_nonempty_buffer(source, n), throw(XzError(:read, k, LZMA.BUF_ERROR)))

function spare!(reader::XzSeekableReader, n::Int)
    i = findfirst(spare -> length(spare) ≥ n, reader.spares)
    if isnothing(i) Memory{UInt8}(undef, n) else popat!(reader.spares, i) end
end

function cancel!(reader::XzSeekableReader)
    for r in reader.queue
        r.cancelled[] = true
    end
    empty!(reader.queue)
end
