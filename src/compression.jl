# Compressor Codec
# ================

mutable struct XzCompressor <: TranscodingStreams.Codec
    const stream::LZMAStream
    const options::LZMAMt
    blockleft::Int
end

function Base.show(io::IO, codec::XzCompressor)
    print(io, summary(codec), "(level=$(codec.options.preset), check=$(codec.options.check), threads=$(codec.options.threads))")
end

const DEFAULT_COMPRESSION_LEVEL = 6
const DEFAULT_CHECK = LZMA_CHECK_CRC64
const PRESET_DICT_POW2 = (18, 20, 21, 22, 22, 23, 23, 24, 25, 26)  # from lzma_lzma_preset

"""
    XzCompressor(;level=$(DEFAULT_COMPRESSION_LEVEL), check=LZMA_CHECK_CRC64, threads=1, blocksize=nothing)

Create an xz compression codec.

Arguments
---------
- `level`: compression level (0..9)
- `check`: integrity check type (`LZMA_CHECK_{NONE,CRC32,CRC64,SHA256}`)
- `threads`: number of threads, or `0` to pick automatically like `xz -T0`: one per
  available CPU, reduced as needed to keep memory usage within a quarter of RAM
- `blocksize`: uncompressed bytes per Block, by default `xz`'s: three times the
  dictionary size, and at least 1 MiB (24 MiB at level 6). Smaller Blocks compress
  slightly worse but make seeking in `XzSeekableStream` cheaper. `0` writes a single
  Block, with one thread only.

With one thread, output is written as input arrives, and Blocks don't record their
sizes, so they can be read with random access but not decoded in parallel. With more
threads, each Block is written once it is complete.
"""
function XzCompressor(;level::Integer=DEFAULT_COMPRESSION_LEVEL, check::Cint=DEFAULT_CHECK, threads::Integer=1, blocksize::Union{Integer,Nothing}=nothing)
    if !(0 ≤ level ≤ 9)
        throw(ArgumentError("compression level must be within 0..9"))
    elseif check ∉ (LZMA_CHECK_NONE, LZMA_CHECK_CRC32, LZMA_CHECK_CRC64, LZMA_CHECK_SHA256)
        throw(ArgumentError("invalid integrity check"))
    end
    blocksize = something(blocksize, max(3 << PRESET_DICT_POW2[level + 1], 1 << 20))
    if !(0 ≤ blocksize ≤ LZMA_BLOCK_SIZE_MAX)
        throw(ArgumentError("blocksize must be within 0..$(LZMA_BLOCK_SIZE_MAX)"))
    elseif iszero(blocksize) && threads != 1
        throw(ArgumentError("a single Block (blocksize=0) needs threads=1"))
    end
    options = LZMAMt(;
        threads = threadcount(threads),
        block_size = blocksize,
        preset = level,
        check)
    if iszero(threads)
        budget = Sys.total_memory() ÷ 4
        while options.threads > 1 && stream_encoder_mt_memusage(options) > budget
            options.threads -= 1
        end
    end
    return XzCompressor(LZMAStream(), options, 0)
end

const XzCompressorStream{S} = TranscodingStream{XzCompressor,S} where S<:IO

"""
    XzCompressorStream(stream::IO; kwargs...)

Create an xz compression stream (see `XzCompressor` for `kwargs`).
"""
function XzCompressorStream(stream::IO; kwargs...)
    x, y = splitkwargs(kwargs, (:level, :check, :threads, :blocksize))
    return TranscodingStream(XzCompressor(;x...), stream; y...)
end


# Methods
# -------

function TranscodingStreams.finalize(codec::XzCompressor)
    free(codec.stream)
end

function TranscodingStreams.startproc(codec::XzCompressor, mode::Symbol, error::Error)
    options = codec.options
    codec.blockleft = if options.threads == 1 && options.block_size > 0 options.block_size else typemax(Int) end
    ret = if options.threads == 1
        easy_encoder(codec.stream, options.preset, options.check)
    else
        stream_encoder_mt(codec.stream, options)
    end
    if ret != LZMA_OK
        error[] = ErrorException(lzma_error_string(ret))
        return :error
    end
    return :ok
end

function TranscodingStreams.process(codec::XzCompressor, input::Memory, output::Memory, error::Error)
    stream = codec.stream
    isflushing = iszero(codec.blockleft)  # a flush must finish first
    avail_in = min(Int(input.size), codec.blockleft)
    stream.next_in = input.ptr
    stream.avail_in = avail_in
    stream.next_out = output.ptr
    stream.avail_out = output.size
    ret = code(stream, if isflushing LZMA_FULL_FLUSH elseif input.size > 0 LZMA_RUN else LZMA_FINISH end)
    Δin = avail_in - Int(stream.avail_in)
    Δout = Int(output.size - stream.avail_out)
    codec.blockleft -= Δin
    if ret == LZMA_OK
        return Δin, Δout, :ok
    elseif ret == LZMA_STREAM_END && isflushing
        codec.blockleft = codec.options.block_size
        return Δin, Δout, :ok
    elseif ret == LZMA_STREAM_END
        return Δin, Δout, :end
    else
        error[] = ErrorException(lzma_error_string(ret))
        return Δin, Δout, :error
    end
end
