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
    finalize,
    splitkwargs
using XZ_jll

include("liblzma.jl")
include("compression.jl")
include("decompression.jl")

end # module
