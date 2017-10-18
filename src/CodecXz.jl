__precompile__()

module CodecXz

export
    XzCompressor,
    XzCompressorStream,
    XzDecompressor,
    XzDecompressorStream

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

# Deprecations
@deprecate XzCompression         XzCompressor
@deprecate XzCompressionStream   XzCompressorStream
@deprecate XzDecompression       XzDecompressor
@deprecate XzDecompressionStream XzDecompressorStream

end # module
