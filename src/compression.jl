# Compression Codec
# =================

struct XzCompression <: TranscodingStreams.Codec
    stream::LZMAStream
    preset::UInt32
    check::Cint
end

const DEFAULT_COMPRESSION_LEVEL = 6
const DEFAULT_CHECK = LZMA_CHECK_CRC64

"""
    XzCompression(;level=$(DEFAULT_COMPRESSION_LEVEL), check=LZMA_CHECK_CRC64)

Create an xz compression codec.

Arguments
---------
- `level`: compression level (0..9)
- `check`: integrity check type (`LZMA_CHECK_{NONE,CRC32,CRC64,SHA256}`)
"""
function XzCompression(;level::Integer=DEFAULT_COMPRESSION_LEVEL, check::Cint=DEFAULT_CHECK)
    if !(0 ≤ level ≤ 9)
        throw(ArgumentError("compression level must be within 0..9"))
    elseif check ∉ (LZMA_CHECK_NONE, LZMA_CHECK_CRC32, LZMA_CHECK_CRC64, LZMA_CHECK_SHA256)
        throw(ArgumentError("invalid integrity check"))
    end
    return XzCompression(LZMAStream(), level, check)
end

const XzCompressionStream{S} = TranscodingStream{XzCompression,S}

"""
    XzCompressionStream(stream::IO; kwargs...)

Create an xz compression stream (see `XzCompression` for `kwargs`).
"""
function XzCompressionStream(stream::IO; kwargs...)
    return TranscodingStream(XzCompression(;kwargs...), stream)
end


# Methods
# -------

function TranscodingStreams.initialize(codec::XzCompression)
    ret = easy_encoder(codec.stream, codec.preset, codec.check)
    if ret != LZMA_OK
        lzmaerror(codec.stream, ret)
    end
    finalizer(codec.stream, free)
    return
end

function TranscodingStreams.finalize(codec::XzCompression)
    free(codec.stream)
end

function TranscodingStreams.process(codec::XzCompression, input::Memory, output::Memory)
    stream = codec.stream
    stream.next_in = input.ptr
    stream.avail_in = input.size
    stream.next_out = output.ptr
    stream.avail_out = output.size
    ret = code(stream, input.size > 0 ? LZMA_RUN : LZMA_FINISH)
    Δin = Int(input.size - stream.avail_in)
    Δout = Int(output.size - stream.avail_out)
    if ret == LZMA_OK
        return Δin, Δout, :ok
    elseif ret == LZMA_STREAM_END
        return Δin, Δout, :end
    else
        lzmaerror(stream, ret)
    end
end
