# Seekable Decompressor Codec
# ===========================
#
# Reading every Index up front lets a read start at the Block holding its first
# byte. Blocks are decoded in runs by a Stream decoder primed with the Stream's
# header, stopping before the Index, which would not match a partial run.
#
# Seeking only sets a target. Reads within a Block use a reused single-threaded
# decoder, which restarts in microseconds; reads reaching well past a Block, and
# sequential reading, use the threaded decoder, which takes milliseconds to
# start. A single-threaded run keeps its input so the threaded decoder can take
# it over mid-Block by replaying it.

"""
    XzDecodingError <: Exception

Failure to decode .xz data while attempting `operation`, with the liblzma
status `code` that caused it.
"""
struct XzDecodingError <: Exception
    operation::String
    code::Cint
end

function Base.showerror(io::IO, err::XzDecodingError)
    reason, remedy = if err.code == LZMA_FORMAT_ERROR
        "the input is not in the .xz format", "check the IO is positioned at the start of .xz data"
    elseif err.code == LZMA_DATA_ERROR
        "the compressed data is corrupt", "verify the file with `xz --test`"
    elseif err.code == LZMA_BUF_ERROR
        "the compressed data is truncated", "verify the file with `xz --test`"
    elseif err.code == LZMA_MEM_ERROR
        "memory could not be allocated", "decode with fewer `threads`"
    elseif err.code == LZMA_MEMLIMIT_ERROR
        "decoding needs more memory than `memlimit`", "raise `memlimit`"
    elseif err.code == LZMA_OPTIONS_ERROR || err.code == LZMA_UNSUPPORTED_CHECK
        "the file uses a filter or check this liblzma does not support", "try a newer xz"
    else
        "liblzma returned status $(err.code)", nothing
    end
    print(io, "XzDecodingError: could not ", err.operation, ": ", reason)
    isnothing(remedy) || print(io, " (", remedy, ")")
end

# The Blocks of one Stream, contiguous in the file.
struct XzSpan
    header::Vector{UInt8}
    blocks::UnitRange{Int}
    compressed_stop::Int64
    uncompressed_stop::Int64
end

struct XzBlock
    compressed_offset::Int64
    uncompressed_offset::Int64
    span::Int
end

# All offsets are relative to `origin`, where the .xz data starts in its IO.
struct XzIndex
    origin::Int64
    compressed_size::Int64
    uncompressed_size::Int64
    spans::Vector{XzSpan}
    blocks::Vector{XzBlock}
end

const FIRST_OUTPUT_WINDOW = 256  # so a small first read need not wait for a full buffer
const LONG_READ = 256 * 1024     # worth the threaded decoder's start-up

mutable struct XzSeekableDecompressor <: TranscodingStreams.Codec
    const index::XzIndex
    const options::LZMAMt
    const single::LZMAStream
    const threaded::LZMAStream  # `single` itself when decoding with one thread
    const replay::Vector{UInt8} # input of the current single-threaded run
    decoder::LZMAStream
    span::Int      # 0 when no run is under way
    limit::Int     # first Block after the run, or where the next one starts
    inpos::Int64
    outpos::Int64
    target::Int64
    readstart::Int64
    wanted::Int64  # where the read under way ends, as far as is known
    replayed::Int
    window::Int
    mark::Int64    # -1 when unmarked
end

function XzSeekableDecompressor(io::IO; threads::Integer=0, memlimit::Integer=DEFAULT_MEM_LIMIT)
    memlimit > 0 || throw(ArgumentError("memlimit must be positive"))
    options = LZMAMt(;
        threads = threadcount(threads),
        memlimit_threading = Sys.total_memory() ÷ 4,  # as xz does
        memlimit_stop = memlimit)
    single = LZMAStream()
    threaded = if options.threads > 1 LZMAStream() else single end
    codec = XzSeekableDecompressor(
        readindex(io), options, single, threaded, UInt8[], single,
        0, 1, 0, 0, 0, 0, 0, 0, FIRST_OUTPUT_WINDOW, -1)
    return finalizer(TranscodingStreams.finalize, codec)
end

function Base.show(io::IO, codec::XzSeekableDecompressor)
    (; index) = codec
    print(io, summary(codec), "(", length(index.blocks), " blocks, ",
          index.uncompressed_size, " bytes, threads=", codec.options.threads, ")")
end

const XzSeekableStream{S} = TranscodingStream{XzSeekableDecompressor,S} where S<:IO

"""
    XzSeekableStream(stream::IO; threads=0, memlimit=$(DEFAULT_MEM_LIMIT), bufsize=$(TranscodingStreams.DEFAULT_BUFFER_SIZE))

Create a seekable xz decompression stream over the .xz data that `stream` is
positioned at the start of, which must extend to the end of `stream`.

`seek`, `seekstart`, `seekend`, `skip`, and `position` all work in uncompressed
offsets. Seeking itself is cheap: the next read decodes from the start of the
Block holding its first byte, so its cost is bounded by the file's Block size
(see `blocksize` in [`XzCompressor`](@ref)), and forward seeks within reach of
the current Block decode on rather than restart. Reads spanning several
Blocks, and sequential reading, decode on up to `threads` threads.

Arguments
---------
- `stream`: seekable IO holding .xz data
- `threads`: maximum number of decoding threads, or `0` for one per available CPU
- `memlimit`: memory usage limit as bytes
- `bufsize`: size of the stream's buffers as bytes

Throws `XzDecodingError` if the .xz Index cannot be read.

Example
-------
```julia
using CodecXz
data = rand(UInt8, 1_000_000)
compressed = transcode(XzCompressor(blocksize=100_000), data)
stream = XzSeekableStream(IOBuffer(compressed))
seek(stream, 654_321)
read(stream, 4) == data[654_322:654_325]  # true
```
"""
function XzSeekableStream(stream::IO; bufsize::Integer=TranscodingStreams.DEFAULT_BUFFER_SIZE, kwargs...)
    return TranscodingStream(XzSeekableDecompressor(stream; kwargs...), stream; bufsize)
end


# Methods
# -------

function TranscodingStreams.finalize(codec::XzSeekableDecompressor)
    free(codec.single)
    free(codec.threaded)
end

# Output is capped per call regardless, so this need not scale with buffered input.
TranscodingStreams.minoutsize(::XzSeekableDecompressor, ::Memory) = 1

function TranscodingStreams.process(codec::XzSeekableDecompressor, input::Memory, output::Memory, error::Error)
    try
        return decode!(codec, input, output)
    catch err
        err isa XzDecodingError || rethrow()
        error[] = err
        return 0, 0, :error
    end
end

Base.position(stream::XzSeekableStream) =
    max(stream.codec.outpos, stream.codec.target) - TranscodingStreams.buffersize(stream.state.buffer1)

function Base.seek(stream::XzSeekableStream, pos::Integer)
    (; codec, state) = stream
    (; index) = codec
    0 ≤ pos ≤ index.uncompressed_size ||
        throw(ArgumentError("cannot seek to $pos, outside the decompressed data (0:$(index.uncompressed_size))"))
    codec.wanted = pos
    here = position(stream)
    here ≤ pos ≤ max(codec.outpos, codec.target) && return skip(stream, pos - here)
    TranscodingStreams.changemode!(stream, :read)
    TranscodingStreams.initbuffer!(state.buffer1)
    state.code = :ok
    k = if pos == index.uncompressed_size length(index.blocks) + 1 else blockat(index, pos) end
    # Decoding on is cheaper than restarting once the decoder holds the target Block.
    isheld = pos > here && k ≤ length(index.blocks) && index.blocks[k].compressed_offset < codec.inpos
    if !isheld
        codec.decoder === codec.threaded !== codec.single && free(codec.threaded)  # stop its read-ahead
        TranscodingStreams.initbuffer!(state.buffer2)
        codec.span, codec.limit = 0, k
        codec.inpos, codec.outpos = if k > length(index.blocks)
            index.compressed_size, index.uncompressed_size
        else
            index.blocks[k].compressed_offset, index.blocks[k].uncompressed_offset
        end
        seek(stream.stream, index.origin + codec.inpos)
        codec.window = FIRST_OUTPUT_WINDOW
    end
    0 < pos - here ≤ LONG_READ || (codec.readstart = pos)  # a short hop forward reads on
    codec.target = pos
    return stream
end

Base.seekstart(stream::XzSeekableStream) = seek(stream, 0)
Base.seekend(stream::XzSeekableStream) = seek(stream, stream.codec.index.uncompressed_size)

# A mark is a position, so it survives seeks and keeps nothing buffered.
Base.mark(stream::XzSeekableStream) = stream.codec.mark = position(stream)
Base.ismarked(stream::XzSeekableStream) = stream.codec.mark ≥ 0

function Base.unmark(stream::XzSeekableStream)
    wasmarked = ismarked(stream)
    stream.codec.mark = -1
    return wasmarked
end

function Base.reset(stream::XzSeekableStream)
    pos = stream.codec.mark
    pos ≥ 0 || throw(ArgumentError("$(typeof(stream)) not marked"))
    stream.codec.mark = -1
    seek(stream, pos)
    return pos
end

# Tell `plan` how far a read reaches.
function Base.unsafe_read(stream::XzSeekableStream, p::Ptr{UInt8}, n::UInt)
    (; codec) = stream
    pos = position(stream)
    codec.wanted = max(codec.wanted, pos + Int(min(n, UInt(codec.index.uncompressed_size - pos))))
    invoke(Base.unsafe_read, Tuple{TranscodingStream,Ptr{UInt8},UInt}, stream, p, n)
end


# Helpers
# -------

function readindex(io::IO)
    origin = position(io)
    size = position(seekend(io)) - origin
    seek(io, origin)
    stream = LZMAStream()
    index = Ref(C_NULL)
    buffer = Vector{UInt8}(undef, 64 * 1024)
    try
        ret = file_info_decoder(stream, index, typemax(UInt64), size)
        GC.@preserve buffer while ret == LZMA_OK
            if iszero(stream.avail_in)
                stream.next_in = pointer(buffer)
                stream.avail_in = readbytes!(io, buffer)
            end
            ret = code(stream, LZMA_RUN)
            if ret == LZMA_SEEK_NEEDED
                seek(io, origin + stream.seek_pos)
                stream.avail_in = 0
                ret = LZMA_OK
            end
        end
        ret == LZMA_STREAM_END || throw(XzDecodingError("read the index", ret))
        return XzIndex(index[], origin, size)
    finally
        free(stream)
        index[] == C_NULL || index_end(index[])
        seek(io, origin)
    end
end

function XzIndex(index::Ptr{Cvoid}, origin::Integer, compressed_size::Integer)
    iter = Ref{LZMAIndexIter}()
    index_iter_init(iter, index)
    spans = XzSpan[]
    blocks = XzBlock[]
    while !index_iter_next(iter, LZMA_INDEX_ITER_BLOCK)
        (; stream, block) = iter[]
        push!(blocks, XzBlock(block.compressed_file_offset, block.uncompressed_file_offset, length(spans) + 1))
        block.number_in_stream == stream.block_count || continue
        header = Vector{UInt8}(undef, LZMA_STREAM_HEADER_SIZE)
        ret = GC.@preserve header stream_header_encode(stream.flags, pointer(header))
        ret == LZMA_OK || throw(XzDecodingError("re-encode a stream header", ret))
        push!(spans, XzSpan(
            header,
            length(blocks)-stream.block_count+1:length(blocks),
            block.compressed_file_offset + block.total_size,
            stream.uncompressed_offset + stream.uncompressed_size))
    end
    uncompressed_size = if isempty(spans) 0 else last(spans).uncompressed_stop end
    return XzIndex(origin, compressed_size, uncompressed_size, spans, blocks)
end

# Decode into `output`, first discarding what falls short of a seek's target.
function decode!(codec::XzSeekableDecompressor, input::Memory, output::Memory)
    insize = Int(input.size)
    Δin, status = advance!(codec, insize)
    isnothing(status) || return Δin, 0, status
    (; index, decoder, replay) = codec
    instop, outstop = runstops(codec)
    iskeeping = decoder === codec.single !== codec.threaded && codec.limit ≤ last(index.spans[codec.span].blocks)
    GC.@preserve replay while true
        isdiscarding = codec.outpos < codec.target
        room = min(Int(output.size), outstop - codec.outpos,
                   if isdiscarding codec.target - codec.outpos else codec.window end)
        isreplaying = codec.replayed < length(replay)
        avail_in = if isreplaying length(replay) - codec.replayed else min(insize - Δin, instop - codec.inpos) end
        decoder.next_in = if isreplaying pointer(replay, codec.replayed + 1) else input.ptr + Δin end
        decoder.avail_in = avail_in
        decoder.next_out = output.ptr
        decoder.avail_out = room
        ret = code(decoder, LZMA_RUN)
        used = avail_in - Int(decoder.avail_in)
        made = room - Int(decoder.avail_out)
        if isreplaying
            codec.replayed += used
        else
            if iskeeping
                kept = length(replay)
                resize!(replay, kept + used)
                unsafe_copyto!(pointer(replay, kept + 1), input.ptr + Δin, used)
                codec.replayed += used
            end
            Δin += used
            codec.inpos += used
        end
        codec.outpos += made
        ret == LZMA_OK || throw(XzDecodingError("decode block $(blockat(index, codec.outpos))", ret))
        if used == made == 0
            # With all its input, the threaded decoder can still report no
            # progress once before it waits on its workers.
            !isreplaying && codec.inpos == instop && continue
            return Δin, 0, :ok
        end
        if !isdiscarding
            codec.window < output.size && (codec.window *= 2)
            return Δin, made, :ok
        end
        # Discard in one call, but return for more input while the run has it,
        # or the threaded decoder waits on its workers instead of feeding them.
        !isreplaying && Δin == insize > 0 && codec.inpos < instop && return Δin, 0, :ok
    end
end

# Start a run once none is under way, or promote one that has proved sequential.
# Returns the input consumed, and a status if decoding must wait or has ended.
function advance!(codec::XzSeekableDecompressor, insize::Int)
    (; index) = codec
    instop, outstop = runstops(codec)
    if iszero(codec.span) || (codec.outpos == outstop && codec.inpos == instop)
        codec.limit > length(index.blocks) && return insize, :end
        k = codec.limit
        start = index.blocks[k].compressed_offset  # past any Index, footer, and padding
        Δin = min(insize, start - codec.inpos)
        codec.inpos += Δin
        if codec.inpos < start
            iszero(insize) && throw(XzDecodingError("read the next stream", LZMA_BUF_ERROR))
            return Δin, :ok
        end
        decoder, limit = plan(codec, k)
        startrun!(codec, decoder, k, limit)
        return Δin, nothing
    end
    if codec.decoder === codec.single !== codec.threaded
        decoder, limit = plan(codec, codec.limit - 1)
        decoder === codec.threaded && codec.outpos < outstop && promote!(codec, limit)
    end
    return 0, nothing
end

# Compressed and uncompressed offsets where the current run ends.
function runstops((; index, span, limit)::XzSeekableDecompressor)
    iszero(span) && return 0, 0
    (; blocks, compressed_stop, uncompressed_stop) = index.spans[span]
    limit in blocks || return compressed_stop, uncompressed_stop
    block = index.blocks[limit]
    return block.compressed_offset, block.uncompressed_offset
end

blockat(index::XzIndex, pos::Integer) =
    searchsortedlast(index.blocks, XzBlock(0, pos, 0), by = b -> b.uncompressed_offset)

# The decoder for a run from Block `k`, and the Block after the run.
function plan(codec::XzSeekableDecompressor, k::Int)
    (; index, single, threaded) = codec
    (; blocks) = index.spans[index.blocks[k].span]
    k == last(blocks) && return single, k + 1
    codec.outpos - codec.readstart ≥ LONG_READ && return threaded, last(blocks) + 1
    codec.wanted - index.blocks[k + 1].uncompressed_offset ≥ LONG_READ || return single, k + 1
    return threaded, min(blockat(index, codec.wanted - 1), last(blocks)) + 1
end

function startrun!(codec::XzSeekableDecompressor, decoder::LZMAStream, k::Int, limit::Int)
    (; span) = codec.index.blocks[k]
    (; header) = codec.index.spans[span]
    ret = if decoder === codec.single
        stream_decoder(decoder, codec.options.memlimit_stop, 0)
    else
        stream_decoder_mt(decoder, codec.options)
    end
    if ret == LZMA_OK
        ret = GC.@preserve header begin
            decoder.next_in = pointer(header)
            decoder.avail_in = length(header)
            decoder.next_out = C_NULL
            decoder.avail_out = 0
            code(decoder, LZMA_RUN)
        end
    end
    ret == LZMA_OK || throw(XzDecodingError("start decoding block $k", ret))
    decoder === codec.single && empty!(codec.replay)
    codec.replayed = length(codec.replay)
    codec.decoder, codec.span, codec.limit = decoder, span, limit
end

# Hand the run to the threaded decoder, replaying its input from the Block start.
function promote!(codec::XzSeekableDecompressor, limit::Int)
    k = codec.limit - 1
    codec.target = max(codec.target, codec.outpos)
    codec.outpos = codec.index.blocks[k].uncompressed_offset
    startrun!(codec, codec.threaded, k, limit)
    codec.replayed = 0
end
