module CodecXz

export
    XzCompression,
    XzCompressionStream,
    XzDecompression,
    XzDecompressionStream

import TranscodingStreams:
    TranscodingStreams,
    TranscodingStream,
    Memory

include("liblzma.jl")
include("compression.jl")
include("decompression.jl")

end # module
