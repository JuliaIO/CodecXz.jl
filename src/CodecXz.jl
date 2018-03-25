__precompile__()

module CodecXz

export
    XzCompressor,
    XzCompressorStream,
    XzDecompressor,
    XzDecompressorStream

using Compat: Cvoid
using Compat.Libdl
import TranscodingStreams:
    TranscodingStreams,
    TranscodingStream,
    Memory,
    Error,
    initialize,
    finalize,
    splitkwargs

const liblzmapath = joinpath(dirname(@__FILE__), "..", "deps", "deps.jl")
if !isfile(liblzmapath)
    error("CodecXz.jl is not installed properly, run Pkg.build(\"CodecXz\") and restart Julia.")
end
include(liblzmapath)
check_deps()

include("liblzma.jl")
include("compression.jl")
include("decompression.jl")

# Deprecations
@deprecate XzCompression         XzCompressor
@deprecate XzCompressionStream   XzCompressorStream
@deprecate XzDecompression       XzDecompressor
@deprecate XzDecompressionStream XzDecompressorStream

end # module
