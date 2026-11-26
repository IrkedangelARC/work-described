using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace ArcSlideLog;

/// <summary>A WAV whose RIFF and data sizes are rewritten every few seconds, so a crash leaves a readable file.</summary>
public sealed class WavWriter : IDisposable
{
    readonly FileStream _fs;
    readonly int _rate, _channels;
    long _dataBytes;
    DateTime _lastHeader = DateTime.UtcNow;
    public TimeSpan HeaderInterval { get; init; } = TimeSpan.FromSeconds(5);
    public long DataBytes => _dataBytes;

    public WavWriter(string path, int rate, int channels)
    {
        _rate = rate; _channels = channels;
        _fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.Read);
        _fs.Write(Header(0, rate, channels));
    }

    public static byte[] Header(long dataBytes, int rate, int channels)
    {
        using var ms = new MemoryStream(44);
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write((uint)(36 + dataBytes)); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)channels); w.Write(rate);
        w.Write(rate * channels * 2); w.Write((short)(channels * 2)); w.Write((short)16);
        w.Write("data"u8); w.Write((uint)dataBytes);
        return ms.ToArray();
    }

    public void Append(ReadOnlySpan<byte> pcm16)
    {
        _fs.Write(pcm16);
        _dataBytes += pcm16.Length;
        if (DateTime.UtcNow - _lastHeader >= HeaderInterval) UpdateHeader();
    }

    public void UpdateHeader()
    {
        var end = _fs.Position;
        _fs.Position = 0; _fs.Write(Header(_dataBytes, _rate, _channels)); _fs.Position = end;
        _fs.Flush(true);
        _lastHeader = DateTime.UtcNow;
    }

    public void Dispose() { try { UpdateHeader(); } catch { } _fs.Dispose(); }
}

/// <summary>
/// The scratch track: the chosen capture device (WASAPI shared mode) resampled to 16 kHz mono, as Opus
/// 24 kb/s in Ogg (OggOpusWriter: a page a second, crash safe), about 11 MB an hour. Sync is its only job. If the device goes away the capture stops with an error; the session restarts it
/// on the default device and marks the track.
/// </summary>
public sealed class ScratchAudio : IDisposable
{
    public record Device(string Id, string Name);

    WasapiCapture? _capture;
    OggOpusWriter? _wav;
    BufferedWaveProvider? _buffer;
    ISampleProvider? _chain;
    readonly object _lock = new();
    public double? StartMono { get; private set; }
    public long FramesWritten { get; private set; }
    public float LevelDB { get; private set; } = -160;
    public bool IsRunning { get; private set; }
    public string? LastError { get; private set; }
    public event Action<string>? Stopped;
    const int TargetRate = 16_000;

    public static List<Device> InputDevices()
    {
        using var e = new MMDeviceEnumerator();
        return e.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).Select(d => new Device(d.ID, d.FriendlyName)).ToList();
    }

    public static string? DefaultInputId()
    {
        try { using var e = new MMDeviceEnumerator(); return e.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID; } catch { return null; }
    }

    public void Start(string? deviceId, string path)
    {
        Stop();
        using var e = new MMDeviceEnumerator();
        MMDevice dev;
        try { dev = deviceId != null ? e.GetDevice(deviceId) : e.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications); }
        catch { dev = e.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications); }
        _wav ??= new OggOpusWriter(path, TargetRate, 1, 24_000);
        _capture = new WasapiCapture(dev, true, 50);
        var fmt = _capture.WaveFormat;
        // ReadFully off: a BufferedWaveProvider otherwise pads with silence for ever (the first drill wrote 450 MB of it in 45 s).
        _buffer = new BufferedWaveProvider(fmt) { DiscardOnBufferOverflow = true, BufferDuration = TimeSpan.FromSeconds(4), ReadFully = false };
        ISampleProvider s = _buffer.ToSampleProvider();
        if (fmt.Channels > 1) s = new StereoToMonoSampleProvider(s) { LeftVolume = 0.5f, RightVolume = 0.5f };
        _chain = new WdlResamplingSampleProvider(s, TargetRate);
        _capture.DataAvailable += OnData;
        _capture.RecordingStopped += (_, a) => { IsRunning = false; LastError = a.Exception?.Message; Stopped?.Invoke(LastError ?? "the scratch input stopped"); };
        _capture.StartRecording();
        IsRunning = true;
    }

    readonly float[] _tmp = new float[8192];
    readonly short[] _out = new short[8192];

    void OnData(object? sender, WaveInEventArgs a)
    {
        lock (_lock)
        {
            if (_buffer == null || _chain == null || _wav == null) return;
            var fmt = _buffer.WaveFormat;
            StartMono ??= SlideTrack.MonotonicSeconds() - (double)a.BytesRecorded / fmt.AverageBytesPerSecond;
            // Level from the raw float buffer (first channel).
            if (fmt.Encoding == WaveFormatEncoding.IeeeFloat && a.BytesRecorded >= 4)
            {
                double sum = 0; int n = 0;
                for (int i = 0; i + 4 <= a.BytesRecorded; i += 4 * fmt.Channels) { float v = BitConverter.ToSingle(a.Buffer, i); sum += v * v; n++; }
                var rms = n > 0 ? Math.Sqrt(sum / n) : 0;
                LevelDB = rms > 0 ? (float)Math.Max(-160, 20 * Math.Log10(rms)) : -160;
            }
            _buffer.AddSamples(a.Buffer, 0, a.BytesRecorded);
            int read;
            while ((read = _chain.Read(_tmp, 0, _tmp.Length)) > 0)
            {
                for (int i = 0; i < read; i++)
                {
                    _out[i] = (short)Math.Clamp(_tmp[i] * 32767f, -32768f, 32767f);
                }
                try { _wav.Append(_out.AsSpan(0, read)); FramesWritten += read; } catch (Exception ex) { LastError = ex.Message; }
                if (read < _tmp.Length / 2) break;
            }
        }
    }

    public double Seconds => (double)FramesWritten / TargetRate;

    /// <summary>Stop capturing; the file stays open for a restart on another device.</summary>
    public void Stop()
    {
        var c = _capture; _capture = null;
        if (c != null) { try { c.DataAvailable -= OnData; c.StopRecording(); } catch { } c.Dispose(); }
        IsRunning = false;
    }

    public void Dispose()
    {
        Stop();
        lock (_lock) { _wav?.Dispose(); _wav = null; }
    }
}
