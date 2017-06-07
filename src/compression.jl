# Compression Codec
# =================

struct XzCompression <: TranscodingStreams.Codec
    stream::LZMAStream
    preset::UInt32
    check::Cint
end

const DEFAULT_COMPRESSION_LEVEL = 6

"""
    XzCompression(;level=$(DEFAULT_COMPRESSION_LEVEL))

Create an xz compression codec.
"""
function XzCompression(;level::Integer=DEFAULT_COMPRESSION_LEVEL)
    if !(0 ≤ level ≤ 9)
        throw(ArgumentError("compression level must be within 0..9"))
    end
    return XzCompression(LZMAStream(), level, LZMA_CHECK_CRC64)
end

const XzCompressionStream{S} = TranscodingStream{XzCompression,S}

"""
    XzCompressionStream(stream::IO)

Create an xz compression stream.
"""
function XzCompressionStream(stream::IO)
    return TranscodingStream(XzCompression(), stream)
end


# Methods
# -------

function TranscodingStreams.initialize(codec::XzCompression)
    ret = easy_encoder(codec.stream, codec.preset, codec.check)
    if ret != LZMA_OK
        lzmaerror(codec.stream, ret)
    end
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
