__precompile__()

module CodecXz

export
    XzCompression,
    XzCompressionStream,
    XzDecompression,
    XzDecompressionStream

import TranscodingStreams:
    TranscodingStreams,
    TranscodingStream,
    Memory,
    Error,
    initialize,
    finalize

include("liblzma.jl")
include("compression.jl")
include("decompression.jl")

end # module
