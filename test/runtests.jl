using CodecXz
using Base.Test
import TranscodingStreams

@testset "Xz Codec" begin
    TranscodingStreams.test_roundtrip_read(XzCompressionStream, XzDecompressionStream)
    TranscodingStreams.test_roundtrip_write(XzCompressionStream, XzDecompressionStream)
    TranscodingStreams.test_roundtrip_transcode(XzCompression, XzDecompression)
end
