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

# TODO: This method will be added in the next version of TranscodingStreams.jl.
function splitkwargs(kwargs, keys)
    hits = []
    others = []
    for kwarg in kwargs
        push!(kwarg[1] ∈ keys ? hits : others, kwarg)
    end
    return hits, others
end

include("liblzma.jl")
include("compression.jl")
include("decompression.jl")

# Deprecations
@deprecate XzCompression         XzCompressor
@deprecate XzCompressionStream   XzCompressorStream
@deprecate XzDecompression       XzDecompressor
@deprecate XzDecompressionStream XzDecompressorStream

end # module
