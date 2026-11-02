# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Random
using BufferIO: BufferIO, BufReader, IOError, IOReader, MemoryView

# Replay random seeks/reads/skips against an IOBuffer of the plain data,
# returning the first divergence (or nothing).
function divergence(compressed::Vector{UInt8}, data::Vector{UInt8}; steps = 300, seed = 1, threads = 2, bufsize = 16 * 1024)
    rng = Xoshiro(seed)
    reader = XzSeekableReader(IOBuffer(compressed); threads, bufsize)
    oracle = IOBuffer(data)
    for step in 1:steps
        op = rand(rng, (:seek, :seek, :hop, :hop, :read, :read, :skip, :readall))
        if op === :seek
            pos = rand(rng, 0:length(data))
            seek(reader, pos)
            seek(oracle, pos)
        elseif op === :hop
            pos = min(position(oracle) + rand(rng, 0:6000), length(data))
            seek(reader, pos)
            seek(oracle, pos)
        elseif op === :read
            n = rand(rng, (0, 1, 17, 1000, 9000))
            got, want = read(reader, n), read(oracle, n)
            got == want || return (; step, op, n, position = position(oracle))
        elseif op === :skip
            n = min(rand(rng, 0:5000), length(data) - position(oracle))
            skip(reader, n)
            skip(oracle, n)
        else
            read(reader) == read(oracle) || return (; step, op)
        end
        position(reader) == position(oracle) || return (; step, op, got = position(reader), want = position(oracle))
        eof(reader) == eof(oracle) || return (; step, op, eof = eof(oracle))
    end
    close(reader)
    nothing
end

# Move a byte of uncompressed size from the second Block to the first in the
# Index, re-signing it, so the Index disagrees with the Blocks but not itself.
function misindex(compressed::Vector{UInt8}, blocksize::Int)
    out = copy(compressed)
    function readvli(i)
        v, shift = 0, 0
        while true
            b = out[i]
            v |= Int(b & 0x7f) << shift
            shift += 7
            b < 0x80 && return v, i + 1
            i += 1
        end
    end
    indexsize = (Int(reinterpret(UInt32, out[end-7:end-4])[1]) + 1) * 4
    start = length(out) - 12 - indexsize + 1
    _, i = readvli(start + 1)  # past the indicator and record count
    for Δ in (1, -1)
        _, i = readvli(i)  # unpadded size
        size, next = readvli(i)
        @assert size == blocksize
        out[i] += Δ
        i = next
    end
    stop = start + indexsize - 4
    crc = GC.@preserve out ccall((:lzma_crc32, XzLib.LZMA.liblzma), UInt32, (Ptr{UInt8}, Csize_t, UInt32), pointer(out, start), stop - start, 0)
    out[stop:stop+3] = reinterpret(UInt8, [htol(crc)])
    out
end

geterror(f) = try f(); nothing catch err err end

const SAMPLE = let rng = Xoshiro(42)
    words = [randstring(rng, rand(rng, 2:8)) for _ in 1:300]
    Vector{UInt8}(join(rand(rng, words, 40_000), ' '))
end

@testset "XzSeekableReader" begin
    multiblock = compress_xz(SAMPLE; blocksize = 16 * 1024, threads = 4)
    layouts = [
        "multi-block" => (multiblock, SAMPLE),
        "single block, sizes unknown" => (compress_xz(SAMPLE; blocksize = 0), SAMPLE),
        "multi-block, sizes unknown" => (compress_xz(SAMPLE; blocksize = 16 * 1024), SAMPLE),
        "multi-stream with padding and an empty stream" => (
            vcat(compress_xz(SAMPLE[1:50_000]; blocksize = 8192), zeros(UInt8, 8),
                 compress_xz(UInt8[]), compress_xz(SAMPLE[50_001:end]; blocksize = 20_000)),
            SAMPLE),
        "multi-stream with differing checks" => (
            vcat(compress_xz(SAMPLE[1:80_000]; check = :crc32),
                 compress_xz(SAMPLE[80_001:160_000]; check = :sha256, blocksize = 16 * 1024, threads = 4),
                 compress_xz(SAMPLE[160_001:end]; check = :none, blocksize = 32 * 1024, threads = 4)),
            SAMPLE),
        "empty" => (compress_xz(UInt8[]), UInt8[]),
    ]

    @testset "sequential read: $name" for (name, (compressed, data)) in layouts
        reader = XzSeekableReader(IOBuffer(compressed))
        @test position(reader) == 0
        @test filesize(reader) == length(data)
        @test read(reader) == data
        @test eof(reader)
        @test position(reader) == length(data)
        close(reader)
    end

    @testset "random access matches IOBuffer: $name" for (name, (compressed, data)) in layouts
        @test divergence(compressed, data) === nothing
    end

    @testset "decoding threads" begin
        @test divergence(multiblock, SAMPLE; threads = 1, seed = 2) === nothing
        @test divergence(multiblock, SAMPLE; threads = 8, seed = 3) === nothing
    end

    @testset "sequential reading within large Blocks: $name, threads=$threads" for
            (name, compressed) in ["multi-block" => compress_xz(repeat(SAMPLE, 6); blocksize = 512 * 1024, threads = 4),
                                   "single block, sizes unknown" => compress_xz(repeat(SAMPLE, 6); blocksize = 0)],
            threads in (1, 4)
        data = repeat(SAMPLE, 6)
        reader = XzSeekableReader(IOBuffer(compressed); threads)
        chunks = Vector{UInt8}[]
        while !eof(reader)
            push!(chunks, read(reader, 1000))
        end
        @test reduce(vcat, chunks) == data
        seek(reader, 100_000)
        @test read(reader, 900_000) == data[100_001:1_000_000]
        seek(reader, 300_000)
        @test [read(reader, UInt8) for _ in 1:400_000] == data[300_001:700_000]
        close(reader)
    end

    @testset "decoding ahead: $name" for (name, threads) in ["sizes known" => 4, "sizes unknown" => 1]
        data = repeat(SAMPLE, 8)
        reader = XzSeekableReader(IOBuffer(compress_xz(data; blocksize = 128 * 1024, threads)); threads = 4)
        isahead() = !isempty(reader.queue)
        @test read(reader, 64) == data[1:64]
        seek(reader, 700_000)
        @test read(reader, 64) == data[700_001:700_064]
        @test !isahead()
        @test read(reader, 1_000_000) == data[700_065:1_700_064]
        @test isahead()
        ahead = first(reader.queue).block
        pos = reader.index.blocks[ahead].uncompressed_offset + 10
        seek(reader, pos)  # into a Block already being decoded ahead
        @test first(reader.queue).block == ahead
        @test read(reader, 200_000) == data[pos+1:pos+200_000]
        seek(reader, 100)
        @test !isahead()
        for _ in 1:40  # short hops forward read on sequentially
            seek(reader, position(reader) + 10_000)
            read(reader, 64)
        end
        @test isahead()
        seek(reader, 100)
        @test read(reader) == data[101:end]
        seekstart(reader)
        read(reader, 1_000_000)
        @test isahead()
        flags = [r.cancelled for r in reader.queue]
        finalize(reader)  # as when a reader is collected without being closed
        @test all(flag -> flag[], flags)
        reader = XzSeekableReader(IOBuffer(compress_xz(data; blocksize = 128 * 1024)); threads = 1)
        @test read(reader) == data
        @test reader.workers == 0
    end

    @testset "reads of known length" begin
        data = repeat(SAMPLE, 8)
        compressed = compress_xz(data; blocksize = 128 * 1024)
        reader = XzSeekableReader(IOBuffer(compressed); threads = 8)
        XzLib.expect!(reader, 600_000)
        BufferIO.fill_buffer(reader)
        @test [r.block for r in reader.queue] == 2:5  # Blocks 2–5 start within 600 kB, Block 1 is decoded here
        seek(reader, 1_500_000)  # past the Blocks decoding ahead
        @test isempty(reader.queue)
        reads = [
            (r, n) -> read(r, n),
            (r, n) -> read!(r, Vector{UInt8}(undef, n)),
            (r, n) -> (b = Vector{UInt8}(undef, n); readbytes!(r, b, n); b),
            (r, n) -> (b = Vector{UInt8}(undef, n); BufferIO.read_all!(r, MemoryView(b)); b),
            (r, n) -> (b = Vector{UInt8}(undef, n); GC.@preserve b unsafe_read(r, pointer(b), n); b),
            (r, n) -> (b = Vector{UInt8}(undef, n); k = BufferIO.read_into!(r, MemoryView(b)); b[1:k]),
        ]
        for f in reads
            seek(reader, 200_000)
            got = f(reader, 500_000)
            @test got == data[200_001:200_000+length(got)]
            @test reader.wanted ≥ 700_000
        end
    end

    @testset "sequential reading keeps a Block ahead" begin
        data = repeat(SAMPLE, 8)
        reader = XzSeekableReader(IOBuffer(compress_xz(data; blocksize = 1 << 20)); threads = 4)
        buf = Vector{UInt8}(undef, 4096)
        for _ in 1:75  # 300 kB, well short of Block 2
            BufferIO.read_all!(reader, MemoryView(buf))
        end
        @test [r.block for r in reader.queue] == [2]
        @test read(reader) == data[75 * 4096 + 1:end]
    end

    @testset "byte-oriented reading" begin
        reader = XzSeekableReader(IOBuffer(multiblock))
        oracle = IOBuffer(SAMPLE)
        @test peek(reader, UInt8) == peek(oracle, UInt8)
        @test [readuntil(reader, UInt8(' ')) for _ in 1:2000] == [readuntil(oracle, UInt8(' ')) for _ in 1:2000]
        @test position(reader) == position(oracle)
        @test bytesavailable(reader) > 0
    end

    @testset "as an IO" begin
        reader = XzSeekableReader(IOBuffer(multiblock))
        io = IOReader(reader)
        @test io isa IO
        seek(io, 30_000)
        @test read(io, 5) == SAMPLE[30_001:30_005]
        @test position(io) == 30_005
    end

    @testset "block boundaries" begin
        reader = XzSeekableReader(IOBuffer(multiblock))
        for boundary in 16 * 1024 .* (1, 2, 5), pos in boundary .+ (-1, 0, 1)
            seek(reader, pos)
            @test read(reader, 3) == SAMPLE[pos+1:pos+3]
        end
        close(reader)
    end

    @testset "xz data after a prefix" begin
        io = IOBuffer(vcat(b"not xz data", multiblock))
        skip(io, 11)
        reader = XzSeekableReader(io)
        @test read(reader, 5) == SAMPLE[1:5]
        seek(reader, 30_000)
        @test read(reader, 5) == SAMPLE[30_001:30_005]
        seekstart(reader)
        @test read(reader) == SAMPLE
    end

    @testset "seekstart, seekend, and seeking after EOF" begin
        reader = XzSeekableReader(IOBuffer(multiblock))
        seekend(reader)
        @test eof(reader)
        @test position(reader) == length(SAMPLE)
        seekstart(reader)
        @test read(reader, 4) == SAMPLE[1:4]
        read(reader)
        seek(reader, 100)
        @test read(reader, 4) == SAMPLE[101:104]
    end

    @testset "invalid seeks" begin
        reader = XzSeekableReader(IOBuffer(multiblock))
        @test_throws IOError seek(reader, -1)
        @test_throws IOError seek(reader, length(SAMPLE) + 1)
        @test read(reader, 3) == SAMPLE[1:3]
    end

    @testset "tiny buffers" begin
        @test divergence(multiblock, SAMPLE; bufsize = 7, steps = 60, seed = 4) === nothing
        reader = XzSeekableReader(BufReader(IOBuffer(multiblock), 7); bufsize = 7)
        seek(reader, 50_000)
        @test read(reader, 20_000) == SAMPLE[50_001:70_000]
    end

    @testset "closing" begin
        io = IOBuffer(multiblock)
        reader = XzSeekableReader(io)
        read(reader, 5)
        close(reader)
        @test !isopen(reader)
        @test !isopen(io)
        @test_throws IOError read(reader, 1)
        @test_throws IOError seek(reader, 0)
        close(reader)
    end

    @testset "malformed input" begin
        @test_throws XzError XzSeekableReader(IOBuffer(b"definitely not an xz file"))
        @test_throws XzError XzSeekableReader(IOBuffer(multiblock[1:end-10]))
        @test_throws ArgumentError XzSeekableReader(IOBuffer(multiblock); threads = -1)
        @test XzSeekableReader(IOBuffer(multiblock); threads = 0).workers ==
            XzSeekableReader(IOBuffer(multiblock); threads = Threads.nthreads()).workers
        @test_throws ArgumentError XzSeekableReader(IOBuffer(multiblock); bufsize = 0)
        @test_throws MethodError XzSeekableReader(IOBuffer(multiblock); stop_on_end = true)
        corrupt = copy(multiblock)
        corrupt[length(corrupt) ÷ 2] ⊻= 0xff
        reader = XzSeekableReader(IOBuffer(corrupt))
        err = geterror(() -> read(reader))
        @test err isa XzError
        @test occursin("corrupt", sprint(showerror, err))
        @test geterror(() -> read(reader, 1)) === err
        seek(reader, 0)
        @test read(reader, 5) == SAMPLE[1:5]
        err = geterror(() -> read(XzSeekableReader(IOBuffer(multiblock); memlimit = 1)))
        @test err isa XzError && err.code === :memlimit
    end

    @testset "seeking after a corrupt Block, threads=$threads" for threads in (1, 4)
        (; blocks) = XzSeekableReader(IOBuffer(multiblock)).index
        corrupt = copy(multiblock)
        corrupt[blocks[4].compressed_offset + blocks[4].total_size] ⊻= 0xff  # its check, found once decoded
        reader = XzSeekableReader(IOBuffer(corrupt); threads)
        err = geterror(() -> read(reader))
        @test err isa XzError && err.operation === :decode && err.code === :corrupt && err.block == 4
        seek(reader, blocks[4].uncompressed_offset)
        @test geterror(() -> read(reader, blocks[4].uncompressed_size)) == err
        pos = blocks[5].uncompressed_offset
        seek(reader, pos)
        @test read(reader, 5) == SAMPLE[pos+1:pos+5]
    end

    @testset "Index disagreeing with the Blocks: $name" for (name, threads) in ["sizes known" => 4, "sizes unknown" => 1]
        compressed = misindex(compress_xz(SAMPLE; blocksize = 20_000, threads), 20_000)
        for threads in (1, 4)
            err = geterror(() -> read(XzSeekableReader(IOBuffer(compressed); threads)))
            @test err isa XzError && err.code === :corrupt
        end
        reader = XzSeekableReader(IOBuffer(compressed))
        seek(reader, 50_000)
        @test read(reader, 5) == SAMPLE[50_001:50_005]
    end
end
