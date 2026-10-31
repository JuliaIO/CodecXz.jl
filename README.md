CodecXz.jl
==========

## Installation

```julia
Pkg.add("CodecXz")
```

## Usage

```julia
using CodecXz

# Some text.
text = """
Lorem ipsum dolor sit amet, consectetur adipiscing elit. Aenean sollicitudin
mauris non nisi consectetur, a dapibus urna pretium. Vestibulum non posuere
erat. Donec luctus a turpis eget aliquet. Cras tristique iaculis ex, eu
malesuada sem interdum sed. Vestibulum ante ipsum primis in faucibus orci luctus
et ultrices posuere cubilia Curae; Etiam volutpat, risus nec gravida ultricies,
erat ex bibendum ipsum, sed varius ipsum ipsum vitae dui.
"""

# Streaming API.
stream = XzCompressorStream(IOBuffer(text))
for line in eachline(XzDecompressorStream(stream))
    println(line)
end
close(stream)

# Array API.
compressed = transcode(XzCompressor, text)
@assert sizeof(compressed) < sizeof(text)
@assert transcode(XzDecompressor, compressed) == Vector{UInt8}(text)
```

This package exports following codecs and streams:

| Codec            | Stream                 |
| ---------------- | ---------------------- |
| `XzCompressor`   | `XzCompressorStream`   |
| `XzDecompressor` | `XzDecompressorStream` |
|                  | `XzSeekableStream`     |

## Random access

`XzSeekableStream` decompresses a seekable `.xz` source with random access:
`seek`, `skip`, and `position` work in uncompressed offsets, and a read decodes
from the start of the Block holding its first byte. Files written with smaller
Blocks seek faster, and multi-Block files decode on several threads.

```julia
compressed = transcode(XzCompressor(threads=0, blocksize=1_000_000), data)
stream = XzSeekableStream(IOBuffer(compressed))
seek(stream, 5_000_000)
read(stream, 100)
```

See docstrings and [TranscodingStreams.jl](https://github.com/bicycle1885/TranscodingStreams.jl) for details.
