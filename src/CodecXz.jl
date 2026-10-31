module CodecXz

export
    XzCompressor,
    XzCompressorStream,
    XzDecompressor,
    XzDecompressorStream,
    XzDecodingError,
    XzSeekableStream

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
include("seekable.jl")

end # module
