using Random

xz(data; kwargs...) = transcode(XzCompressor(; kwargs...), data)

# lzma_easy_encoder writes a single Block whose header omits its sizes,
# which forces the threaded decoder into its single-threaded direct mode.
function xz_singleblock(data::Vector{UInt8})
    stream = CodecXz.LZMAStream()
    @assert CodecXz.easy_encoder(stream, 6, CodecXz.LZMA_CHECK_CRC64) == CodecXz.LZMA_OK
    out = Vector{UInt8}(undef, length(data) + 1024)
    GC.@preserve data out begin
        stream.next_in, stream.avail_in = pointer(data), length(data)
        stream.next_out, stream.avail_out = pointer(out), length(out)
        @assert CodecXz.code(stream, CodecXz.LZMA_FINISH) == CodecXz.LZMA_STREAM_END
    end
    CodecXz.free(stream)
    resize!(out, stream.total_out)
end

# Replay random seeks/reads/skips against an IOBuffer of the plain data,
# returning the first divergence (or nothing).
function divergence(compressed::Vector{UInt8}, data::Vector{UInt8}; steps = 300, seed = 1, threads = 2, bufsize = 16 * 1024)
    rng = Xoshiro(seed)
    stream = XzSeekableStream(IOBuffer(compressed); threads, bufsize)
    oracle = IOBuffer(data)
    for step in 1:steps
        op = rand(rng, (:seek, :seek, :hop, :hop, :read, :read, :skip, :readall))
        if op === :seek
            pos = rand(rng, 0:length(data))
            seek(stream, pos)
            seek(oracle, pos)
        elseif op === :hop
            pos = min(position(oracle) + rand(rng, 0:6000), length(data))
            seek(stream, pos)
            seek(oracle, pos)
        elseif op === :read
            n = rand(rng, (0, 1, 17, 1000, 9000))
            got, want = read(stream, n), read(oracle, n)
            got == want || return (; step, op, n, position = position(oracle))
        elseif op === :skip
            n = rand(rng, 0:5000)
            skip(stream, n)
            skip(oracle, n)
        else
            read(stream) == read(oracle) || return (; step, op)
        end
        position(stream) == position(oracle) || return (; step, op, got = position(stream), want = position(oracle))
        eof(stream) == eof(oracle) || return (; step, op, eof = eof(oracle))
    end
    close(stream)
    nothing
end

const SAMPLE = let rng = Xoshiro(42)
    words = [randstring(rng, rand(rng, 2:8)) for _ in 1:300]
    Vector{UInt8}(join(rand(rng, words, 40_000), ' '))
end

@testset "XzSeekableStream" begin
    multiblock = xz(SAMPLE; blocksize = 16 * 1024, threads = 4)
    layouts = [
        "multi-block" => (multiblock, SAMPLE),
        "single block, sizes unknown" => (xz_singleblock(SAMPLE), SAMPLE),
        "multi-stream with padding and an empty stream" => (
            vcat(xz(SAMPLE[1:50_000]; blocksize = 8192), zeros(UInt8, 8),
                 xz(UInt8[]), xz(SAMPLE[50_001:end]; blocksize = 20_000)),
            SAMPLE),
        "multi-stream with differing checks" => (
            vcat(xz(SAMPLE[1:80_000]; check = CodecXz.LZMA_CHECK_CRC32),
                 xz(SAMPLE[80_001:160_000]; check = CodecXz.LZMA_CHECK_SHA256, blocksize = 16 * 1024, threads = 4),
                 xz(SAMPLE[160_001:end]; check = CodecXz.LZMA_CHECK_NONE, blocksize = 32 * 1024, threads = 4)),
            SAMPLE),
        "empty" => (xz(UInt8[]), UInt8[]),
    ]

    @testset "sequential read: $name" for (name, (compressed, data)) in layouts
        stream = XzSeekableStream(IOBuffer(compressed))
        @test position(stream) == 0
        @test read(stream) == data
        @test eof(stream)
        @test position(stream) == length(data)
        close(stream)
    end

    @testset "random access matches IOBuffer: $name" for (name, (compressed, data)) in layouts
        @test divergence(compressed, data) === nothing
    end

    @testset "decoder threads" begin
        @test divergence(multiblock, SAMPLE; threads = 1, seed = 2) === nothing
        @test divergence(multiblock, SAMPLE; threads = 8, seed = 3) === nothing
    end

    @testset "sequential reading within large Blocks: $name, threads=$threads" for
            (name, compressed) in ["multi-block" => xz(repeat(SAMPLE, 6); blocksize = 512 * 1024, threads = 4),
                                   "single block, sizes unknown" => xz_singleblock(repeat(SAMPLE, 6))],
            threads in (1, 4)
        data = repeat(SAMPLE, 6)
        stream = XzSeekableStream(IOBuffer(compressed); threads)
        chunks = Vector{UInt8}[]
        while !eof(stream)
            push!(chunks, read(stream, 1000))
        end
        @test reduce(vcat, chunks) == data
        seek(stream, 100_000)
        @test read(stream, 900_000) == data[100_001:1_000_000]
        seek(stream, 300_000)
        @test [read(stream, UInt8) for _ in 1:400_000] == data[300_001:700_000]
        close(stream)
    end

    @testset "decoder choice" begin
        data = repeat(SAMPLE, 8)
        stream = XzSeekableStream(IOBuffer(xz(data; blocksize = 1024 * 1024, threads = 4)); threads = 4)
        isthreaded() = stream.codec.decoder === stream.codec.threaded
        @test read(stream, 64) == data[1:64]
        @test !isthreaded()
        seek(stream, 700_000)  # far forward, though within the same Block
        @test read(stream, 64) == data[700_001:700_064]
        @test read(stream, 1000) == data[700_065:701_064]
        @test !isthreaded()
        for _ in 1:40  # short hops forward read on sequentially
            seek(stream, position(stream) + 10_000)
            read(stream, 64)
        end
        @test isthreaded()
        seek(stream, 100)
        @test read(stream, 1_500_000) == data[101:1_500_100]
        @test isthreaded()
    end

    @testset "marks survive seeks" begin
        stream = XzSeekableStream(IOBuffer(multiblock))
        @test !ismarked(stream)
        @test_throws ArgumentError reset(stream)
        seek(stream, 30_000)
        @test mark(stream) == 30_000
        read(stream, 100)
        seek(stream, 200_000)
        read(stream, 100)
        @test ismarked(stream)
        @test reset(stream) == 30_000
        @test !ismarked(stream)
        @test read(stream, 5) == SAMPLE[30_001:30_005]
        mark(stream)
        @test unmark(stream)
        @test !unmark(stream)
        @test peek(stream, Char) == Char(SAMPLE[30_006])
        @test position(stream) == 30_005
    end

    @testset "byte-oriented reading" begin
        stream = XzSeekableStream(IOBuffer(multiblock))
        oracle = IOBuffer(SAMPLE)
        @test peek(stream, UInt8) == peek(oracle, UInt8)
        @test [readuntil(stream, UInt8(' ')) for _ in 1:2000] == [readuntil(oracle, UInt8(' ')) for _ in 1:2000]
        @test position(stream) == position(oracle)
        @test bytesavailable(stream) > 0
    end

    @testset "block boundaries" begin
        stream = XzSeekableStream(IOBuffer(multiblock))
        for boundary in 16 * 1024 .* (1, 2, 5), pos in boundary .+ (-1, 0, 1)
            seek(stream, pos)
            @test read(stream, 3) == SAMPLE[pos+1:pos+3]
        end
        close(stream)
    end

    @testset "xz data after a prefix" begin
        io = IOBuffer(vcat(b"not xz data", multiblock))
        skip(io, 11)
        stream = XzSeekableStream(io)
        @test read(stream, 5) == SAMPLE[1:5]
        seek(stream, 30_000)
        @test read(stream, 5) == SAMPLE[30_001:30_005]
        seekstart(stream)
        @test read(stream) == SAMPLE
    end

    @testset "seekstart, seekend, and seeking after EOF" begin
        stream = XzSeekableStream(IOBuffer(multiblock))
        seekend(stream)
        @test eof(stream)
        @test position(stream) == length(SAMPLE)
        seekstart(stream)
        @test read(stream, 4) == SAMPLE[1:4]
        read(stream)
        seek(stream, 100)
        @test read(stream, 4) == SAMPLE[101:104]
    end

    @testset "invalid seeks" begin
        stream = XzSeekableStream(IOBuffer(multiblock))
        @test_throws ArgumentError seek(stream, -1)
        @test_throws ArgumentError seek(stream, length(SAMPLE) + 1)
        @test read(stream, 3) == SAMPLE[1:3]
    end

    @testset "tiny buffers" begin
        @test divergence(multiblock, SAMPLE; bufsize = 7, steps = 60, seed = 4) === nothing
    end

    @testset "single-Block files keep no replay input" begin
        stream = XzSeekableStream(IOBuffer(xz(repeat(SAMPLE, 4))); threads = 4)
        while !eof(stream)
            read(stream, 1000)
        end
        @test isempty(stream.codec.replay)
    end

    @testset "malformed input" begin
        @test_throws XzDecodingError XzSeekableStream(IOBuffer(b"definitely not an xz file"))
        @test_throws XzDecodingError XzSeekableStream(IOBuffer(multiblock[1:end-10]))
        @test_throws ArgumentError XzSeekableStream(IOBuffer(multiblock); threads = -1)
        @test_throws ArgumentError XzSeekableStream(IOBuffer(multiblock); threads = CodecXz.LZMA_THREADS_MAX + 1)
        @test_throws MethodError XzSeekableStream(IOBuffer(multiblock); stop_on_end = true)
        corrupt = copy(multiblock)
        corrupt[length(corrupt) ÷ 2] ⊻= 0xff
        stream = XzSeekableStream(IOBuffer(corrupt))
        err = try
            read(stream)
        catch err
            err
        end
        @test err isa XzDecodingError
        @test occursin("corrupt", sprint(showerror, err))
        @test_throws ArgumentError seek(stream, 0)
    end
end
