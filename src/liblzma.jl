# The liblzma Interfaces
# ======================

# Return code
const LZMA_OK                = Cint(0)
const LZMA_STREAM_END        = Cint(1)
const LZMA_NO_CHECK          = Cint(2)
const LZMA_UNSUPPORTED_CHECK = Cint(3)
const LZMA_GET_CHECK         = Cint(4)
const LZMA_MEM_ERROR         = Cint(5)
const LZMA_MEMLIMIT_ERROR    = Cint(6)
const LZMA_FORMAT_ERROR      = Cint(7)
const LZMA_OPTIONS_ERROR     = Cint(8)
const LZMA_DATA_ERROR        = Cint(9)
const LZMA_BUF_ERROR         = Cint(10)
const LZMA_PROG_ERROR        = Cint(11)

# Action code
const LZMA_RUN          = Cint(0)
const LZMA_SYNC_FLUSH   = Cint(1)
const LZMA_FULL_FLUSH   = Cint(2)
const LZMA_FULL_BARRIER = Cint(4)
const LZMA_FINISH       = Cint(3)

# Flag
const LZMA_TELL_NO_CHECK          = UInt32(0x01)
const LZMA_TELL_UNSUPPORTED_CHECK = UInt32(0x02)
const LZMA_TELL_ANY_CHECK         = UInt32(0x04)
const LZMA_IGNORE_CHECK           = UInt32(0x10)
const LZMA_CONCATENATED           = UInt32(0x08)

# Check
const LZMA_CHECK_NONE     = Cint(0)
const LZMA_CHECK_CRC32    = Cint(1)
const LZMA_CHECK_CRC64    = Cint(4)
const LZMA_CHECK_SHA256   = Cint(10)

const LZMA_THREADS_MAX = 16384
const LZMA_BLOCK_SIZE_MAX = typemax(UInt64) ÷ LZMA_THREADS_MAX  # from stream_encoder_mt.c

mutable struct LZMAStream
    next_in::Ptr{UInt8}
    avail_in::Csize_t
    total_in::UInt64

    next_out::Ptr{UInt8}
    avail_out::Csize_t
    total_out::UInt64

    allocator::Ptr{Cvoid}

    internal::Ptr{Cvoid}

    reserved_ptr::NTuple{4,Ptr{Cvoid}}
    reserved_uint::NTuple{2,UInt64}
    reserved_size::NTuple{2,Csize_t}
    reserved_enum::NTuple{2,Cint}
end

function LZMAStream()
    return LZMAStream(
        C_NULL, 0, 0,
        C_NULL, 0, 0,
        C_NULL,
        C_NULL,
        (C_NULL, C_NULL, C_NULL, C_NULL),
        (0, 0), (0, 0),
        (0, 0))
end

# Options for the multithreaded encoder and decoder (lzma_mt).
mutable struct LZMAMt
    flags::UInt32
    threads::UInt32
    block_size::UInt64
    timeout::UInt32
    preset::UInt32
    filters::Ptr{Cvoid}
    check::Cint
    reserved_enum::NTuple{3,Cint}
    reserved_int::NTuple{4,UInt32}
    memlimit_threading::UInt64
    memlimit_stop::UInt64
    reserved_vli::NTuple{2,UInt64}
    reserved_ptr::NTuple{4,Ptr{Cvoid}}
end

function LZMAMt(; threads=1, block_size=0, preset=6, check=LZMA_CHECK_CRC64,
                memlimit_threading=0, memlimit_stop=0)
    return LZMAMt(
        0, threads, block_size, 0, preset, C_NULL, check, (0, 0, 0), (0, 0, 0, 0),
        memlimit_threading, memlimit_stop, (0, 0), ntuple(_ -> C_NULL, 4))
end

function lzmaerror(stream::LZMAStream, code::Cint)
    error(lzma_error_string(code))
end

function lzma_error_string(code::Cint)
    return "lzma error: code = $(code)"
end

function easy_encoder(stream::LZMAStream, preset::Integer, check::Integer)
    return ccall(
        (:lzma_easy_encoder, liblzma),
        Cint,
        (Ref{LZMAStream}, UInt32, Cint),
        stream, preset, check)
end

function stream_encoder_mt(stream::LZMAStream, options::LZMAMt)
    return ccall(
        (:lzma_stream_encoder_mt, liblzma),
        Cint,
        (Ref{LZMAStream}, Ref{LZMAMt}),
        stream, options)
end

function threadcount(threads::Integer)
    0 ≤ threads ≤ LZMA_THREADS_MAX ||
        throw(ArgumentError("threads must be within 0..$(LZMA_THREADS_MAX), with 0 picking automatically"))
    iszero(threads) || return threads
    return max(Int(ccall((:lzma_cputhreads, liblzma), UInt32, ())), 1)  # lzma_cputhreads gives 0 if unknown
end

function stream_encoder_mt_memusage(options::LZMAMt)
    return ccall((:lzma_stream_encoder_mt_memusage, liblzma), UInt64, (Ref{LZMAMt},), options)
end

function stream_decoder(stream::LZMAStream, memlimit::Integer, flags::Integer)
    return ccall(
        (:lzma_stream_decoder, liblzma),
        Cint,
        (Ref{LZMAStream}, UInt64, UInt32),
        stream, memlimit, flags)
end

function code(stream::LZMAStream, action::Integer)
    return ccall(
        (:lzma_code, liblzma),
        Cint,
        (Ref{LZMAStream}, Cint),
        stream, action)
end

function free(stream::LZMAStream)
    ccall((:lzma_end, liblzma), Cvoid, (Ref{LZMAStream},), stream)
end

