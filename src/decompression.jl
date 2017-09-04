# Decompression Codec
# ===================

struct XzDecompression <: TranscodingStreams.Codec
    stream::LZMAStream
    memlimit::Integer
    flags::UInt32
end

function Base.show(io::IO, codec::XzDecompression)
    print(io, summary(codec), "(memlimit=$(codec.memlimit), flags=$(codec.flags))")
end

const DEFAULT_MEM_LIMIT = typemax(UInt64)

"""
    XzDecompression(;memlimit=$(DEFAULT_MEM_LIMIT), flags=LZMA_CONCATENATED)

Create an xz decompression codec.

Arguments
---------
- `memlimit`: memory usage limit as bytes
- `flags`: decoder flags
"""
function XzDecompression(;memlimit::Integer=DEFAULT_MEM_LIMIT, flags::UInt32=LZMA_CONCATENATED)
    if memlimit ≤ 0
        throw(ArgumentError("memlimit must be positive"))
    end
    # NOTE: flags are checked in liblzma
    return XzDecompression(LZMAStream(), memlimit, flags)
end

const XzDecompressionStream{S} = TranscodingStream{XzDecompression,S} where S<:IO

"""
    XzDecompressionStream(stream::IO; kwargs...)

Create an xz decompression stream (see `XzDecompression` for `kwargs`).
"""
function XzDecompressionStream(stream::IO; kwargs...)
    return TranscodingStream(XzDecompression(;kwargs...), stream)
end


# Methods
# -------

function TranscodingStreams.initialize(codec::XzDecompression)
    ret = stream_decoder(codec.stream, codec.memlimit, codec.flags)
    if ret != LZMA_OK
        lzmaerror(codec.stream, ret)
    end
    return
end

function TranscodingStreams.finalize(codec::XzDecompression)
    free(codec.stream)
end

function TranscodingStreams.process(codec::XzDecompression, input::Memory, output::Memory, error::Error)
    stream = codec.stream
    stream.next_in = input.ptr
    stream.avail_in = input.size
    stream.next_out = output.ptr
    stream.avail_out = output.size
    if codec.flags & LZMA_CONCATENATED != 0
        action = stream.avail_in > 0 ? LZMA_RUN : LZMA_FINISH
    else
        action = LZMA_RUN
    end
    ret = code(stream, action)
    Δin = Int(input.size - stream.avail_in)
    Δout = Int(output.size - stream.avail_out)
    if ret == LZMA_OK
        return Δin, Δout, :ok
    elseif ret == LZMA_STREAM_END
        return Δin, Δout, :end
    else
        error[] = ErrorException(lzma_error_string(ret))
        return Δin, Δout, :error
    end
end
