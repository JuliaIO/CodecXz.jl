using CodecXz
using TranscodingStreams: TranscodingStreams
using TestsForCodecPackages
using Test

@testset "Xz Codec" begin
    codec = XzCompressor()
    @test codec isa XzCompressor
    @test occursin(r"^(CodecXz\.)?XzCompressor\(level=\d, check=\d+\)$", sprint(show, codec))
    @test CodecXz.initialize(codec) === nothing
    @test CodecXz.finalize(codec) === nothing

    codec = XzDecompressor()
    @test codec isa XzDecompressor
    @test occursin(r"^(CodecXz\.)?XzDecompressor\(memlimit=\d+, flags=\d+\)$", sprint(show, codec))
    @test CodecXz.initialize(codec) === nothing
    @test CodecXz.finalize(codec) === nothing

    # Generated by `lzma.compress(b"foo")` on CPython 3.5.2.
    data = Vector(b"\xfd7zXZ\x00\x00\x04\xe6\xd6\xb4F\x02\x00!\x01\x16\x00\x00\x00t/\xe5\xa3\x01\x00\x02foo\x00\x00X\x15\xa9{,\xe6,\x98\x00\x01\x1b\x03\x0b/\xb9\x10\x1f\xb6\xf3}\x01\x00\x00\x00\x00\x04YZ")
    @test read(XzDecompressorStream(IOBuffer(data))) == b"foo"
    @test read(XzDecompressorStream(IOBuffer(vcat(data, data)))) == b"foofoo"
    # corrupt data
    data[[1,3,5]] = b"bug"
    @test_throws ErrorException read(XzDecompressorStream(IOBuffer(data)))

    @test XzCompressorStream <: TranscodingStreams.TranscodingStream
    @test XzDecompressorStream <: TranscodingStreams.TranscodingStream

    test_roundtrip_read(XzCompressorStream, XzDecompressorStream)
    test_roundtrip_write(XzCompressorStream, XzDecompressorStream)
    test_roundtrip_lines(XzCompressorStream, XzDecompressorStream)
    test_roundtrip_seekstart(XzCompressorStream, XzDecompressorStream)
    test_roundtrip_transcode(XzCompressor, XzDecompressor)

    @test_throws ArgumentError XzCompressor(level=10)
    @test_throws ArgumentError XzDecompressor(memlimit=0)
end
