# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
Bindings to the parts of liblzma that XzLib uses.
"""
module LZMA

using MemoryViews: ImmutableMemoryView, MutableMemoryView
using XZ_jll: liblzma

const STATUS_OK         = Cint(0)
const STREAM_END        = Cint(1)
const UNSUPPORTED_CHECK = Cint(3)
const MEM_ERROR         = Cint(5)
const MEMLIMIT_ERROR    = Cint(6)
const FORMAT_ERROR      = Cint(7)
const OPTIONS_ERROR     = Cint(8)
const DATA_ERROR        = Cint(9)
const BUF_ERROR         = Cint(10)
const SEEK_NEEDED       = Cint(12)

const RUN        = Cint(0)
const FULL_FLUSH = Cint(2)
const FINISH     = Cint(3)

const CONCATENATED = UInt32(0x08)

const CHECK_NONE   = Cint(0)
const CHECK_CRC32  = Cint(1)
const CHECK_CRC64  = Cint(4)
const CHECK_SHA256 = Cint(10)

const THREADS_MAX = 16384
const BLOCK_SIZE_MAX = typemax(UInt64) ÷ THREADS_MAX  # from stream_encoder_mt.c
const INDEX_ITER_BLOCK = Cint(2)
const VLI_UNKNOWN = typemax(UInt64)
const FILTERS_MAX = 4
const MT_TIMEOUT_MS = 100  # bounds how long a threaded lzma_code call holds up Julia's GC

mutable struct Stream
    next_in::Ptr{UInt8}
    avail_in::Csize_t
    total_in::UInt64
    next_out::Ptr{UInt8}
    avail_out::Csize_t
    total_out::UInt64
    allocator::Ptr{Cvoid}
    internal::Ptr{Cvoid}
    reserved_ptr::NTuple{4,Ptr{Cvoid}}
    seek_pos::UInt64  # set by decoders returning SEEK_NEEDED
    reserved::NTuple{3,UInt64}
    reserved_enum::NTuple{2,Cint}
end

Stream() = Stream(C_NULL, 0, 0, C_NULL, 0, 0, C_NULL, C_NULL, ntuple(_ -> C_NULL, 4), 0, (0, 0, 0), (0, 0))

mutable struct Mt
    flags::UInt32
    threads::UInt32
    block_size::UInt64
    timeout::UInt32
    preset::UInt32
    filters::Ptr{Cvoid}
    check::Cint
    reserved_enum::NTuple{3,Cint}
    reserved_int::NTuple{4,UInt32}
    memlimit_threading::UInt64
    memlimit_stop::UInt64
    reserved_vli::NTuple{2,UInt64}
    reserved_ptr::NTuple{4,Ptr{Cvoid}}
end

Mt(; flags=0, threads=1, block_size=0, preset=6, check=CHECK_CRC64, memlimit_threading=0, memlimit_stop=0) =
    Mt(flags, threads, block_size, MT_TIMEOUT_MS, preset, C_NULL, check, (0, 0, 0), (0, 0, 0, 0),
           memlimit_threading, memlimit_stop, (0, 0), ntuple(_ -> C_NULL, 4))

# The leading fields of lzma_stream_flags.
struct StreamFlags
    version::UInt32
    backward_size::UInt64
    check::Cint
end

struct IndexIterStream
    flags::Ptr{StreamFlags}
    reserved::NTuple{14,UInt64}
end

struct IndexIterBlock
    number_in_file::UInt64
    compressed_file_offset::UInt64
    uncompressed_file_offset::UInt64
    number_in_stream::UInt64
    compressed_stream_offset::UInt64
    uncompressed_stream_offset::UInt64
    uncompressed_size::UInt64
    unpadded_size::UInt64
    total_size::UInt64
    reserved::NTuple{8,UInt64}
end

struct IndexIter
    stream::IndexIterStream
    block::IndexIterBlock
    internal::NTuple{6,UInt64}
end

struct Filter
    id::UInt64
    options::Ptr{Cvoid}
end

mutable struct Block
    version::UInt32
    header_size::UInt32
    check::Cint
    compressed_size::UInt64
    uncompressed_size::UInt64
    filters::Ptr{Filter}
    raw_check::NTuple{64,UInt8}
    reserved::NTuple{10,UInt64}
    reserved_enum::NTuple{4,Cint}
    flags::NTuple{8,Bool}  # ignore_check, then reserved
end

Block() = Block(0, 0, 0, 0, 0, C_NULL, ntuple(_ -> 0x00, Val(64)), ntuple(_ -> 0, 10), (0, 0, 0, 0), ntuple(_ -> false, 8))

cputhreads() = @ccall liblzma.lzma_cputhreads()::UInt32  # 0 if unknown

# Returns the bytes used and made, and the status.
function code!(stream::Stream, input::ImmutableMemoryView{UInt8}, output::MutableMemoryView{UInt8}, action::Cint=RUN)
    GC.@preserve input output begin
        stream.next_in, stream.avail_in = pointer(input), length(input)
        stream.next_out, stream.avail_out = pointer(output), length(output)
        ret = @ccall liblzma.lzma_code(stream::Ref{Stream}, action::Cint)::Cint
    end
    GC.safepoint()  # callers loop without allocating, so might never let GC run
    return length(input) - Int(stream.avail_in), length(output) - Int(stream.avail_out), ret
end

free(stream::Stream) = @ccall liblzma.lzma_end(stream::Ref{Stream})::Cvoid

easy_encoder(stream::Stream, preset::Integer, check::Integer) =
    @ccall liblzma.lzma_easy_encoder(stream::Ref{Stream}, preset::UInt32, check::Cint)::Cint
stream_encoder_mt(stream::Stream, options::Mt) =
    @ccall liblzma.lzma_stream_encoder_mt(stream::Ref{Stream}, options::Ref{Mt})::Cint
stream_encoder_mt_memusage(options::Mt) =
    @ccall liblzma.lzma_stream_encoder_mt_memusage(options::Ref{Mt})::UInt64

stream_decoder(stream::Stream, memlimit::Integer, flags::Integer) =
    @ccall liblzma.lzma_stream_decoder(stream::Ref{Stream}, memlimit::UInt64, flags::UInt32)::Cint
stream_decoder_mt(stream::Stream, options::Mt) =
    @ccall liblzma.lzma_stream_decoder_mt(stream::Ref{Stream}, options::Ref{Mt})::Cint
file_info_decoder(stream::Stream, index::Ref{Ptr{Cvoid}}, memlimit::Integer, file_size::Integer) =
    @ccall liblzma.lzma_file_info_decoder(stream::Ref{Stream}, index::Ref{Ptr{Cvoid}}, memlimit::UInt64, file_size::UInt64)::Cint

index_end(index::Ptr{Cvoid}) = @ccall liblzma.lzma_index_end(index::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Cvoid
index_iter_init(iter::Ref{IndexIter}, index::Ptr{Cvoid}) =
    @ccall liblzma.lzma_index_iter_init(iter::Ref{IndexIter}, index::Ptr{Cvoid})::Cvoid
index_iter_next(iter::Ref{IndexIter}, mode::Cint) =
    @ccall liblzma.lzma_index_iter_next(iter::Ref{IndexIter}, mode::Cint)::Bool

block_header_decode(block::Block, header::Ptr{UInt8}) =
    @ccall liblzma.lzma_block_header_decode(block::Ref{Block}, C_NULL::Ptr{Cvoid}, header::Ptr{UInt8})::Cint
block_compressed_size(block::Block, unpadded_size::Integer) =
    @ccall liblzma.lzma_block_compressed_size(block::Ref{Block}, unpadded_size::UInt64)::Cint
block_decoder(stream::Stream, block::Block) =
    @ccall liblzma.lzma_block_decoder(stream::Ref{Stream}, block::Ref{Block})::Cint

raw_decoder_memusage(filters::Ptr{Filter}) = @ccall liblzma.lzma_raw_decoder_memusage(filters::Ptr{Filter})::UInt64
filters_free(filters::Ptr{Filter}) = @ccall liblzma.lzma_filters_free(filters::Ptr{Filter}, C_NULL::Ptr{Cvoid})::Cvoid

end
