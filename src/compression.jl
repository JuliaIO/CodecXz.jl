# Compressor Codec
# ================

struct XzCompressor <: TranscodingStreams.Codec
    stream::LZMAStream
    options::LZMAMt
end

function Base.show(io::IO, codec::XzCompressor)
    print(io, summary(codec), "(level=$(codec.options.preset), check=$(codec.options.check), threads=$(codec.options.threads))")
end

const DEFAULT_COMPRESSION_LEVEL = 6
const DEFAULT_CHECK = LZMA_CHECK_CRC64

"""
    XzCompressor(;level=$(DEFAULT_COMPRESSION_LEVEL), check=LZMA_CHECK_CRC64, threads=1, blocksize=0)

Create an xz compression codec.

Arguments
---------
- `level`: compression level (0..9)
- `check`: integrity check type (`LZMA_CHECK_{NONE,CRC32,CRC64,SHA256}`)
- `threads`: number of threads, or `0` to pick automatically like `xz -T0`: one per
  available CPU, reduced as needed to keep memory usage within a quarter of RAM
- `blocksize`: uncompressed bytes per Block, or `0` for liblzma's default (three times
  the dictionary size, 24 MiB at level 6). Smaller Blocks compress slightly worse but
  bound the work a seek must redo in `XzSeekableStream`.

With one thread and no `blocksize`, the output is a single Block, written as input
arrives. Otherwise input is split into Blocks, each written once it is complete.
"""
function XzCompressor(;level::Integer=DEFAULT_COMPRESSION_LEVEL, check::Cint=DEFAULT_CHECK, threads::Integer=1, blocksize::Integer=0)
    if !(0 ≤ level ≤ 9)
        throw(ArgumentError("compression level must be within 0..9"))
    elseif check ∉ (LZMA_CHECK_NONE, LZMA_CHECK_CRC32, LZMA_CHECK_CRC64, LZMA_CHECK_SHA256)
        throw(ArgumentError("invalid integrity check"))
    elseif !(0 ≤ blocksize ≤ LZMA_BLOCK_SIZE_MAX)
        throw(ArgumentError("blocksize must be within 0..$(LZMA_BLOCK_SIZE_MAX)"))
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
    return XzCompressor(LZMAStream(), options)
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
    ret = if options.threads == 1 && iszero(options.block_size)
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
        error[] = ErrorException(lzma_error_string(ret))
        return Δin, Δout, :error
    end
end
