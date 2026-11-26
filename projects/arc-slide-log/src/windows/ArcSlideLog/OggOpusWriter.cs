using Concentus;
using Concentus.Enums;

namespace ArcSlideLog;

/// <summary>
/// Sync-grade sound: Opus in an Ogg file (RFC 7845), written as it comes. A page goes to disk about every
/// second and is flushed, so a crash or a kill leaves a file every decoder reads to the last page. The track is
/// a plain sample count from its first sample (no time stamps to drift): Append in order, silence included.
/// Media Foundation's AAC encoder cannot do this (44.1 or 48 kHz at 96 kb/s or more only).
/// </summary>
public sealed class OggOpusWriter : IDisposable
{
    readonly FileStream _fs;
    readonly IOpusEncoder _enc;
    readonly int _rate, _channels, _frame;      // frame: samples per channel in 20 ms at the input rate
    readonly short[] _pending;
    int _pendingCount;                          // interleaved values in _pending
    readonly byte[] _packet = new byte[4000];
    readonly List<byte[]> _pagePackets = new();
    int _pageSegments;
    long _granule48;                            // 48 kHz samples through the last packet encoded (pre-skip included)
    int _sequence;
    readonly uint _serial;
    readonly int _preSkip;                      // 48 kHz samples
    public long SamplesIn { get; private set; } // per channel, at the input rate
    long _finalBytes;
    public long Bytes => _closed ? _finalBytes : _fs.Length;
    public string Path { get; }
    const int PacketsPerPage = 50;              // one second of 20 ms packets

    public OggOpusWriter(string path, int sampleRate, int channels, int bitsPerSecond)
    {
        if (sampleRate is not (8000 or 12000 or 16000 or 24000 or 48000)) throw new ArgumentException("Opus takes 8, 12, 16, 24 or 48 kHz");
        Path = path; _rate = sampleRate; _channels = channels; _frame = sampleRate / 50;
        _enc = OpusCodecFactory.CreateEncoder(sampleRate, channels, OpusApplication.OPUS_APPLICATION_AUDIO);
        _enc.Bitrate = bitsPerSecond;
        _enc.UseVBR = true;
        _enc.Complexity = 5;                    // plenty for sync; keeps the CPU near nothing
        _pending = new short[_frame * channels];
        _preSkip = _enc.Lookahead * 48000 / sampleRate;
        _serial = (uint)Random.Shared.Next();
        _fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        WritePage(new List<byte[]> { OpusHead() }, 0x02, 0);
        WritePage(new List<byte[]> { OpusTags() }, 0x00, 0);
    }

    byte[] OpusHead()
    {
        var b = new byte[19];
        "OpusHead"u8.CopyTo(b); b[8] = 1; b[9] = (byte)_channels;
        BitConverter.TryWriteBytes(b.AsSpan(10), (ushort)_preSkip);
        BitConverter.TryWriteBytes(b.AsSpan(12), (uint)_rate);
        // output gain 0, mapping family 0
        return b;
    }

    static byte[] OpusTags()
    {
        var vendor = "ARC Slide Log"u8;
        var b = new byte[8 + 4 + vendor.Length + 4];
        "OpusTags"u8.CopyTo(b);
        BitConverter.TryWriteBytes(b.AsSpan(8), (uint)vendor.Length);
        vendor.CopyTo(b.AsSpan(12));
        return b;                               // user comment count 0
    }

    /// <summary>Interleaved 16-bit samples at the writer's rate and channel count.</summary>
    public void Append(ReadOnlySpan<short> samples)
    {
        int i = 0;
        while (i < samples.Length)
        {
            int n = Math.Min(samples.Length - i, _pending.Length - _pendingCount);
            samples.Slice(i, n).CopyTo(_pending.AsSpan(_pendingCount));
            _pendingCount += n; i += n;
            if (_pendingCount == _pending.Length) EncodePending();
        }
        SamplesIn += samples.Length / _channels;
    }

    /// <summary>Silence, without allocating it.</summary>
    public void AppendSilence(long frames)
    {
        Span<short> zero = stackalloc short[960];
        long values = frames * _channels;
        while (values > 0) { int n = (int)Math.Min(values, zero.Length - zero.Length % _channels); Append(zero[..n]); values -= n; }
    }

    void EncodePending()
    {
        int len = _enc.Encode(_pending, _frame, _packet, _packet.Length);
        _pendingCount = 0;
        _granule48 += 960;
        int segs = len / 255 + 1;
        if (_pageSegments + segs > 255) FlushPage(0);
        _pagePackets.Add(_packet.AsSpan(0, len).ToArray());
        _pageSegments += segs;
        if (_pagePackets.Count >= PacketsPerPage) FlushPage(0);
    }

    void FlushPage(byte flags, long? granule = null)
    {
        if (_pagePackets.Count == 0 && flags == 0) return;
        WritePage(_pagePackets, flags, granule ?? _granule48);
        _pagePackets.Clear(); _pageSegments = 0;
    }

    void WritePage(List<byte[]> packets, byte flags, long granule)
    {
        var lacing = new List<byte>();
        foreach (var p in packets) { int n = p.Length; while (n >= 255) { lacing.Add(255); n -= 255; } lacing.Add((byte)n); }
        int body = packets.Sum(p => p.Length);
        var page = new byte[27 + lacing.Count + body];
        "OggS"u8.CopyTo(page); page[4] = 0; page[5] = flags;
        BitConverter.TryWriteBytes(page.AsSpan(6), granule);
        BitConverter.TryWriteBytes(page.AsSpan(14), _serial);
        BitConverter.TryWriteBytes(page.AsSpan(18), (uint)_sequence++);
        page[26] = (byte)lacing.Count;
        lacing.CopyTo(page, 27);
        int o = 27 + lacing.Count;
        foreach (var p in packets) { p.CopyTo(page, o); o += p.Length; }
        BitConverter.TryWriteBytes(page.AsSpan(22), Crc(page));
        _fs.Write(page);
        _fs.Flush(true);
    }

    static readonly uint[] CrcTable = MakeTable();
    static uint[] MakeTable()
    {
        var t = new uint[256];
        for (uint i = 0; i < 256; i++) { uint r = i << 24; for (int k = 0; k < 8; k++) r = (r & 0x80000000) != 0 ? (r << 1) ^ 0x04C11DB7 : r << 1; t[i] = r; }
        return t;
    }
    static uint Crc(ReadOnlySpan<byte> d) { uint c = 0; foreach (var b in d) c = (c << 8) ^ CrcTable[((c >> 24) & 0xFF) ^ b]; return c; }

    bool _closed;
    /// <summary>The last partial frame is padded and encoded; the end-of-stream page carries the true length.</summary>
    public void Dispose()
    {
        if (_closed) return; _closed = true;
        try
        {
            if (_pendingCount > 0) { Array.Clear(_pending, _pendingCount, _pending.Length - _pendingCount); EncodePending(); }
            FlushPage(0x04, _preSkip + SamplesIn * 48000 / _rate);
        }
        catch { }
        try { _finalBytes = _fs.Length; } catch { }
        _fs.Dispose();
    }
}
