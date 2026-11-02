# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
    XzError <: Exception

Failure to `operation` .xz data (`:encode`, `:decode`, `:read`, or `:index` for
reading the Index), in Block number `block` (`0` when the failure is not
specific to one Block), because of `code`:

- `:format`: the input is not .xz data
- `:corrupt`: the compressed data is corrupt
- `:truncated`: the compressed data ends early
- `:memlimit`: decoding needs more memory than `memlimit` allows
- `:memory`: memory could not be allocated
- `:unsupported`: the data use a filter or integrity check this liblzma does not support
- `:internal`: liblzma reported misuse, which is a bug in XzLib
"""
struct XzError <: Exception
    operation::Symbol
    block::Int
    code::Symbol
end

XzError(operation::Symbol, status::Cint) = XzError(operation, 0, status)

function XzError(operation::Symbol, block::Int, status::Cint)
    code = if status == LZMA.FORMAT_ERROR
        :format
    elseif status == LZMA.DATA_ERROR
        :corrupt
    elseif status == LZMA.BUF_ERROR
        :truncated
    elseif status == LZMA.MEMLIMIT_ERROR
        :memlimit
    elseif status == LZMA.MEM_ERROR
        :memory
    elseif status in (LZMA.OPTIONS_ERROR, LZMA.UNSUPPORTED_CHECK)
        :unsupported
    else
        :internal
    end
    XzError(operation, block, code)
end

function Base.showerror(io::IO, err::XzError)
    print(io, "XzError: could not ", if err.operation === :index "read the index" else err.operation end)
    iszero(err.block) || print(io, " block ", err.block)
    reason, remedy = if err.code === :format
        "the input is not in the .xz format", "check the IO is positioned at the start of .xz data"
    elseif err.code === :corrupt
        "the compressed data is corrupt", "verify the file with `xz --test`"
    elseif err.code === :truncated
        "the compressed data is truncated", "verify the file with `xz --test`"
    elseif err.code === :memlimit
        "decoding needs more memory than `memlimit`", "raise `memlimit`"
    elseif err.code === :memory
        "memory could not be allocated", "use fewer `threads`"
    elseif err.code === :unsupported
        "the file uses a filter or check this liblzma does not support", "try a newer xz"
    else
        "liblzma reported misuse", "this is a bug in XzLib, please report it"
    end
    print(io, ": ", reason, " (", remedy, ")")
end
