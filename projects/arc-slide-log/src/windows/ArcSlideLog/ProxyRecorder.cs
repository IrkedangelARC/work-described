using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace ArcSlideLog;

/// <summary>
/// The very low resolution recording of a monitor with the presentation's sound: Windows.Graphics.Capture
/// frames read back from Direct3D 11, box-downscaled on the CPU to 320 wide, into a Media Foundation sink
/// writer (H.264 at most 150 kb/s) as fragmented MP4 so a crash keeps the file; the system's mixed output
/// (WASAPI loopback) as sync-grade sound in its own file, Opus mono 24 kb/s (OggOpusWriter). Only a frame that differs from the last one written goes in, at
/// most ten a second, so the file is variable rate: a frame's time is the time the picture changed.
/// </summary>
public sealed class ProxyRecorder : IDisposable
{
    public record MonitorInfo(IntPtr Handle, string Name, int Width, int Height, bool Primary);

    public int LongSide { get; init; } = 320;
    public int Fps { get; init; } = 10;
    public int BitsPerSecond { get; init; } = 150_000;
    public int AudioBitsPerSecond { get; init; } = 24_000;
    public int Frames { get; private set; }
    public int AudioSamples { get; private set; }
    public int Dropped { get; private set; }
    public double? StartMono { get; private set; }
    public double? LastFrameMono { get; private set; }
    public int PixelWidth { get; private set; }
    public int PixelHeight { get; private set; }
    public string? LastError { get; private set; }
    public event Action<string>? Stopped;
    /// <summary>--trace-frames: one log line per video sample written, with its presentation time, to compare with the file's timeline.</summary>
    public bool TraceFrames { get; set; }

    ID3D11Device? _device;
    ID3D11DeviceContext? _context;
    IDirect3DDevice? _winrtDevice;
    GraphicsCaptureItem? _item;
    Direct3D11CaptureFramePool? _pool;
    GraphicsCaptureSession? _session;
    ID3D11Texture2D? _staging;
    IMFSinkWriter? _writer;
    // The sound goes to its own file. In one file the fragmented MP4 sink holds the sound back behind the picture
    // (measured after a kill: picture to 28.6 s, sound to 19.8 s, 15 AAC frames per fragment whatever the timing),
    // and a crash would lose it. An audio-only writer kept 29.7 s of 30 after a kill.
    OggOpusWriter? _audioWriter;
    public string? AudioPath { get; private set; }
    int _videoIndex = -1, _audioIndex = -1;
    WasapiLoopbackCapture? _loopback;
    readonly object _lock = new();
    bool _writing;
    long _firstPts = -1;
    double _startMono;
    byte[]? _scaled, _lastScaled;
    double _lastWrittenMono = -1;
    // The frame on screen now, not yet in the file: it goes in when the next change arrives, with the hold as its
    // duration (the fragmented MP4 sink lays samples end to end by duration and drops any gap in the time stamps:
    // measured, a 45 s drill came out 27 s long). A hold longer than MaxHold is written in MaxHold pieces so a
    // crash loses at most that much picture.
    byte[]? _pending;
    double _pendingMono = -1;
    const double MaxHold = 2.0;
    System.Threading.Timer? _pump;

    // MARK: monitors

    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr hMonitor, ref MONITORINFOEX info);

    public static List<MonitorInfo> Monitors()
    {
        var list = new List<MonitorInfo>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr _, ref RECT r, IntPtr _) =>
        {
            var info = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
            GetMonitorInfoW(h, ref info);
            var name = Screen.AllScreens.FirstOrDefault(s => s.DeviceName == info.szDevice)?.DeviceName ?? info.szDevice;
            list.Add(new MonitorInfo(h, name.TrimStart('\\', '.'), r.right - r.left, r.bottom - r.top, (info.dwFlags & 1) != 0));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // MARK: WinRT interop

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow(IntPtr window, ref Guid iid);
        IntPtr CreateForMonitor(IntPtr monitor, ref Guid iid);
    }

    [ComImport, Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDirect3DDxgiInterfaceAccess { IntPtr GetInterface(ref Guid iid); }

    [DllImport("d3d11.dll")] static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr inspectable);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int WindowsCreateString(string source, int length, out IntPtr hstring);
    [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr hstring);
    [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr classId, ref Guid iid, out IntPtr factory);

    /// <summary>The WinRT activation factory of a class as a COM interface, without depending on a CsWinRT helper's name.</summary>
    static T Factory<T>(string runtimeClass) where T : class
    {
        Marshal.ThrowExceptionForHR(WindowsCreateString(runtimeClass, runtimeClass.Length, out var h));
        try
        {
            var iid = typeof(T).GUID;
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(h, ref iid, out var p));
            try { return (T)Marshal.GetObjectForIUnknown(p); } finally { Marshal.Release(p); }
        }
        finally { WindowsDeleteString(h); }
    }

    static readonly Guid IID_IGraphicsCaptureItem = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    static readonly Guid IID_ID3D11Texture2D = new("6F15AAF2-D208-4E89-9AB4-489535D34F9C");

    public void Start(MonitorInfo monitor, string path)
    {
        // Direct3D
        D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, null, out _device, out _context).CheckError();
        using var dxgi = _device!.QueryInterface<IDXGIDevice>();
        Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var insp));
        _winrtDevice = MarshalInterface<IDirect3DDevice>.FromAbi(insp);
        Marshal.Release(insp);

        // The monitor as a capture item
        var factory = Factory<IGraphicsCaptureItemInterop>("Windows.Graphics.Capture.GraphicsCaptureItem");
        var iid = IID_IGraphicsCaptureItem;
        var itemPtr = factory.CreateForMonitor(monitor.Handle, ref iid);
        _item = GraphicsCaptureItem.FromAbi(itemPtr);
        Marshal.Release(itemPtr);
        var size = _item.Size;

        // Proxy size: an integer box factor keeps the downscale cheap and exact.
        int f = Math.Max(1, (int)Math.Ceiling(Math.Max(size.Width, size.Height) / (double)LongSide));
        PixelWidth = (size.Width / f) & ~1; PixelHeight = (size.Height / f) & ~1;
        _factor = f;
        _staging = _device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)size.Width, Height = (uint)size.Height, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging, CPUAccessFlags = CpuAccessFlags.Read, BindFlags = BindFlags.None,
        });

        // The writer: fragmented MP4, hardware transforms welcome.
        MediaFactory.MFStartup(true).CheckError();   // the "light" startup, no sockets
        Trace?.Invoke($"proxy types: item {size.Width}x{size.Height}, factor {f}, proxy {PixelWidth}x{PixelHeight}, {Fps} fps, {BitsPerSecond} b/s, path {path}");
        Stage = "writer"; _writer = CreateWriter(path, fmp4: true, throttleOff: true);
        Stage = "video output type"; _videoIndex = AddVideoOut(_writer, PixelWidth, PixelHeight, Fps, BitsPerSecond);
        Exception? last = null;
        foreach (var variant in new[] { "nv12", "nv12-min", "rgb32" })
        {
            try { Stage = $"video input type ({variant})"; SetVideoIn(_writer, _videoIndex, PixelWidth, PixelHeight, Fps, variant); VideoInput = variant; last = null; break; }
            catch (Exception ex) { last = ex; Trace?.Invoke($"proxy: {Stage} refused: {ex.Message.Split('\n')[0]}"); }
        }
        if (last != null) throw last;

        // System audio: whatever the mixer runs at, 16-bit PCM in, AAC out.
        _loopback = new WasapiLoopbackCapture();
        var lf = _loopback.WaveFormat;
        int rate = lf.SampleRate is 44100 or 48000 ? lf.SampleRate : 48000, ch = Math.Min(2, lf.Channels);
        _loopRate = lf.SampleRate; _loopChannels = lf.Channels; _loopFloat = lf.Encoding == WaveFormatEncoding.IeeeFloat;
        LoopbackFormat = $"{lf.SampleRate} Hz, {lf.Channels} ch, {lf.Encoding}, {lf.BitsPerSample} bit";
        // Sound: Opus mono 24 kb/s at 48 kHz (the loopback's rate, or resampled to it). Its only job is sync and
        // finding when the deck played media; Media Foundation's AAC encoder will not go below 96 kb/s.
        AudioPath = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path) ?? "", System.IO.Path.GetFileNameWithoutExtension(path) + "-audio.opus");
        try
        {
            Stage = "audio writer"; _audioWriter = new OggOpusWriter(AudioPath, 48000, 1, AudioBitsPerSecond);
            _audioIndex = 0; _audioOutChannels = 1; _audioOutRate = 48000; HasAudio = true;
            AudioChoice = $"Opus 48 kHz mono {AudioBitsPerSecond / 1000} kb/s";
        }
        catch (Exception ex)
        {
            _audioIndex = -1; _audioWriter = null; AudioPath = null;
            LastError = "proxy audio could not start; recording video only: " + ex.Message;
        }
        Stage = "begin writing"; _writer.BeginWriting();
        Stage = "running";
        _writing = true;

        // Frames
        _pool = Direct3D11CaptureFramePool.CreateFreeThreaded(_winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
        _pool.FrameArrived += OnFrame;
        _session = _pool.CreateCaptureSession(_item);
        try { _session.IsCursorCaptureEnabled = false; } catch { }
        // Windows 11 draws a yellow border round a captured monitor unless the app is allowed borderless capture.
        try
        {
            if (Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired"))
            {
                var access = GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless).AsTask();
                if (access.Wait(3000) && access.Result == Windows.Security.Authorization.AppCapabilityAccess.AppCapabilityAccessStatus.Allowed) _session.IsBorderRequired = false;
                else LastError = "borderless capture not allowed: a yellow border may show on the program display";
            }
        }
        catch (Exception ex) { LastError = "borderless capture: " + ex.Message; }
        _item.Closed += (_, _) => Fail("the display went away");
        if (HasAudio)
        {
            _loopback.DataAvailable += OnAudio;
            _loopback.RecordingStopped += (_, a) => { if (_writing && a.Exception != null) Fail("system audio stopped: " + a.Exception.Message); };
            _loopback.StartRecording();
        }
        else { _loopback.Dispose(); _loopback = null; }
        _session.StartCapture();
        _pump = new System.Threading.Timer(Pump, null, 250, 250);
    }

    /// <summary>Which step of Start a failure came from (the HRESULT alone does not say).</summary>
    public string Stage { get; private set; } = "";
    public string LoopbackFormat { get; private set; } = "";
    public string AudioChoice { get; private set; } = "";
    /// <summary>nv12, nv12-min or rgb32: what the encoder took; the downscale emits the matching layout.</summary>
    public string VideoInput { get; private set; } = "nv12";
    public bool HasAudio { get; private set; }
    int _audioOutRate = 48000;
    public event Action<string>? Trace;
    int _factor = 1, _loopRate = 48000, _loopChannels = 2, _audioOutChannels = 2;
    bool _loopFloat = true;

    static ulong Pack(int hi, int lo) => ((ulong)(uint)hi << 32) | (uint)lo;

    // THE TRAP (cost the afternoon of 2026-10-23): Vortice's IMFAttributes.Set has overloads for uint, ulong,
    // double, Guid, string. An int LITERAL converts to uint and lands as UINT32; an int VARIABLE cannot, so the
    // compiler picks double, the attribute is stored as VT_R8, and the encoder answers MF_E_INVALIDMEDIATYPE.
    // Every integer handed to Set below is cast to uint on purpose.

    static IMFSinkWriter CreateWriter(string path, bool fmp4, bool throttleOff)
    {
        var attrs = MediaFactory.MFCreateAttributes(4);
        attrs.Set(TranscodeAttributeKeys.TranscodeContainertype, fmp4 ? TranscodeContainerTypeGuids.Fmpeg4 : TranscodeContainerTypeGuids.Mpeg4);
        attrs.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, false);
        if (throttleOff) attrs.Set(SinkWriterAttributeKeys.DisableThrottling, true);
        // Low latency: samples go through the encoders and into the file as they come, not from a queue; a crash
        // drill without it lost the last 9 s of picture and 16 s of sound even though the fragments on disk were
        // a third of a second apart.
        attrs.Set(SinkWriterAttributeKeys.LowLatency, true);
        return MediaFactory.MFCreateSinkWriterFromURL(path, null, attrs);
    }

    static int AddVideoOut(IMFSinkWriter wr, int w, int h, int fps, int bps)
    {
        var vOut = MediaFactory.MFCreateMediaType();
        vOut.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        vOut.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.H264);
        vOut.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)bps);
        vOut.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
        vOut.Set(MediaTypeAttributeKeys.FrameSize, Pack(w, h));
        vOut.Set(MediaTypeAttributeKeys.FrameRate, Pack(fps, 1));
        vOut.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
        return wr.AddStream(vOut);
    }

    static void SetVideoIn(IMFSinkWriter wr, int index, int w, int h, int fps, string variant)
    {
        var vIn = MediaFactory.MFCreateMediaType();
        vIn.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        vIn.Set(MediaTypeAttributeKeys.Subtype, variant.StartsWith("nv12") ? VideoFormatGuids.NV12 : VideoFormatGuids.Rgb32);
        vIn.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
        vIn.Set(MediaTypeAttributeKeys.FrameSize, Pack(w, h));
        vIn.Set(MediaTypeAttributeKeys.FrameRate, Pack(fps, 1));
        vIn.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
        if (variant == "nv12") { vIn.Set(MediaTypeAttributeKeys.DefaultStride, (uint)w); vIn.Set(MediaTypeAttributeKeys.AllSamplesIndependent, true); }
        wr.SetInputMediaType(index, vIn, null);
    }

    void Fail(string reason)
    {
        lock (_lock) { if (!_writing) return; LastError = reason; }
        Stopped?.Invoke(reason);
    }

    void OnFrame(Direct3D11CaptureFramePool sender, object args)
    {
        using var frame = sender.TryGetNextFrame();
        if (frame == null) return;
        var mono = SlideTrack.MonotonicSeconds();
        lock (_lock)
        {
            if (!_writing || _context == null || _staging == null) return;
            if (_lastWrittenMono >= 0 && mono - _lastWrittenMono < 1.0 / Fps) return;   // at most Fps a second
            // Readback
            var access = WinRT.CastExtensions.As<IDirect3DDxgiInterfaceAccess>(frame.Surface);
            var iid = IID_ID3D11Texture2D;
            var texPtr = access.GetInterface(ref iid);
            using var tex = new ID3D11Texture2D(texPtr);
            _context.CopyResource(_staging, tex);
            var map = _context.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
            try { Downscale(map.DataPointer, (int)map.RowPitch); }
            finally { _context.Unmap(_staging, 0); }
            // Only a changed picture is a frame.
            if (_lastScaled != null && _scaled!.AsSpan().SequenceEqual(_lastScaled)) return;
            if (_firstPts < 0) _ = Pts100ns(mono);   // the timeline starts at the first picture, sound included
            if (_pending != null) WriteVideo(_pending, _pendingMono, mono - _pendingMono);
            _pending ??= new byte[_scaled!.Length];
            Buffer.BlockCopy(_scaled!, 0, _pending, 0, _scaled!.Length);
            _pendingMono = mono;
            (_lastScaled, _scaled) = (_scaled, _lastScaled ?? new byte[_scaled!.Length]);
            _lastWrittenMono = mono;
            LastFrameMono = mono;
        }
    }

    /// <summary>Box-downscale the BGRA readback by the integer factor straight into NV12 (BT.601 limited range), or RGB32 when that is what the encoder took.</summary>
    unsafe void Downscale(IntPtr src, int pitch)
    {
        int w = PixelWidth, h = PixelHeight, f = _factor, n = f * f;
        bool rgb = VideoInput == "rgb32";
        _scaled ??= new byte[rgb ? w * h * 4 : w * h * 3 / 2];
        byte* s = (byte*)src;
        fixed (byte* d = _scaled)
        {
            byte* yPlane = d, uv = d + w * h;
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    int b = 0, g = 0, r = 0;
                    for (int yy = 0; yy < f; yy++)
                    {
                        byte* p = s + (y * f + yy) * pitch + x * f * 4;
                        for (int xx = 0; xx < f; xx++) { b += p[0]; g += p[1]; r += p[2]; p += 4; }
                    }
                    b /= n; g /= n; r /= n;
                    if (rgb) { byte* o = d + ((h - 1 - y) * w + x) * 4; o[0] = (byte)b; o[1] = (byte)g; o[2] = (byte)r; o[3] = 255; continue; }   // RGB32 is bottom-up in MF
                    yPlane[y * w + x] = (byte)Math.Clamp(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16, 16, 235);
                    if ((y & 1) == 0 && (x & 1) == 0)
                    {
                        int o = (y / 2) * w + x;
                        uv[o] = (byte)Math.Clamp(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128, 16, 240);
                        uv[o + 1] = (byte)Math.Clamp(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128, 16, 240);
                    }
                }
            }
        }
    }

    long Pts100ns(double mono)
    {
        var t = (long)(mono * 10_000_000);
        if (_firstPts < 0) { _firstPts = t; StartMono = mono; _startMono = mono; }
        return t - _firstPts;
    }

    void WriteVideo(byte[] nv12, double mono, double seconds)
    {
        if (_writer == null) return;
        var sample = MediaFactory.MFCreateSample();
        var buffer = MediaFactory.MFCreateMemoryBuffer(nv12.Length);
        buffer.Lock(out var p, out _, out _);
        Marshal.Copy(nv12, 0, p, nv12.Length);
        buffer.Unlock();
        buffer.CurrentLength = nv12.Length;
        sample.AddBuffer(buffer);
        sample.SampleTime = Pts100ns(mono);
        sample.SampleDuration = Math.Max(1, (long)(seconds * 10_000_000));
        if (TraceFrames) Trace?.Invoke($"frame {Frames} pts {sample.SampleTime / 1e7:F3} dur {seconds:F3}");
        try { _writer.WriteSample(_videoIndex, sample); Frames++; }
        catch (Exception ex) { Dropped++; LastError = ex.Message; }
        finally { buffer.Dispose(); sample.Dispose(); }
    }

    byte[]? _pcm;
    void OnAudio(object? sender, WaveInEventArgs a)
    {
        var mono = SlideTrack.MonotonicSeconds();
        lock (_lock)
        {
            if (!_writing || _writer == null || _audioIndex < 0 || a.BytesRecorded == 0) return;
            // Float (or 16-bit) at the mixer's channel count -> 16-bit at the output channel count.
            int inCh = _loopChannels, outCh = _audioOutChannels;
            int frames = a.BytesRecorded / (inCh * (_loopFloat ? 4 : 2));
            int outLen = frames * outCh * 2;
            if (_pcm == null || _pcm.Length < outLen) _pcm = new byte[outLen];
            for (int i = 0; i < frames; i++)
                for (int c = 0; c < outCh; c++)
                {
                    int sc = Math.Min(c, inCh - 1);
                    short v = _loopFloat ? (short)Math.Clamp(BitConverter.ToSingle(a.Buffer, (i * inCh + sc) * 4) * 32767f, -32768f, 32767f)
                                         : BitConverter.ToInt16(a.Buffer, (i * inCh + sc) * 2);
                    _pcm[(i * outCh + c) * 2] = (byte)v; _pcm[(i * outCh + c) * 2 + 1] = (byte)(v >> 8);
                }
            double bufferStart = mono - (double)frames / _loopRate;
            if (_loopRate != _audioOutRate) { Resample(ref frames, outCh); }
            // The loopback is silent when nothing renders (no buffers at all, measured), so the track is built as a
            // continuous timeline: silence fills every gap, and each buffer lands where the clock says it began.
            if (_firstPts < 0) return;   // the proxy timeline starts with the first video frame
            FillSilenceTo(bufferStart);
            WriteAudio(_pcm, frames * outCh * 2, frames);
        }
    }

    long _audioFramesWritten;
    byte[]? _silence;
    double _lastAudioMono = -1;

    /// <summary>Silence from the frames written so far up to `mono` (the proxy clock), in chunks of a second at most.</summary>
    void FillSilenceTo(double mono)
    {
        if (_audioWriter == null || _audioIndex < 0 || _firstPts < 0) return;
        long expected = (long)((mono - _startMono) * _audioOutRate);
        long gap = expected - _audioFramesWritten;
        if (gap < _audioOutRate / 33) return;   // under 30 ms: the loopback's own jitter, not a hole
        int chunk = _audioOutRate;
        _silence ??= new byte[chunk * _audioOutChannels * 2];
        while (gap > 0)
        {
            int n = (int)Math.Min(gap, chunk);
            WriteAudio(_silence, n * _audioOutChannels * 2, n);
            gap -= n;
        }
    }

    void WriteAudio(byte[] pcm, int bytes, int frames)
    {
        if (_audioWriter == null || _audioIndex < 0 || frames <= 0) return;
        if (TraceFrames) Trace?.Invoke($"audio {AudioSamples} pts {(double)_audioFramesWritten / _audioOutRate:F3} frames {frames} {(ReferenceEquals(pcm, _silence) ? "silence" : "loopback")}");
        try { _audioWriter.Append(MemoryMarshal.Cast<byte, short>(pcm.AsSpan(0, bytes))); AudioSamples++; _audioFramesWritten += frames; _lastAudioMono = SlideTrack.MonotonicSeconds(); }
        catch (Exception ex) { LastError = ex.Message; }
    }

    /// <summary>Every quarter second: a long hold goes in piecewise, and silence keeps the sound track up to date.</summary>
    void Pump(object? _)
    {
        lock (_lock)
        {
            if (!_writing || _writer == null) return;
            var mono = SlideTrack.MonotonicSeconds();
            if (_pending != null && mono - _pendingMono >= MaxHold)
            {
                WriteVideo(_pending, _pendingMono, MaxHold);
                _pendingMono += MaxHold;
            }
            PumpAudio(mono);
        }
    }

    /// <summary>When nothing has rendered for a while, the silence is written anyway so the track never lags the picture.</summary>
    void PumpAudio(double mono)
    {
        if (_audioIndex < 0 || _firstPts < 0) return;
        if (mono - Math.Max(_lastAudioMono, _startMono) < 0.5) return;
        FillSilenceTo(mono - 0.2);   // leave room for a loopback buffer still in flight
    }

    byte[]? _rs;
    /// <summary>Linear resample of the 16-bit interleaved _pcm from the loopback rate to the output rate (rare: a mixer not at 44.1 or 48 k).</summary>
    void Resample(ref int frames, int ch)
    {
        int outFrames = (int)((long)frames * _audioOutRate / _loopRate);
        int need = outFrames * ch * 2;
        if (_rs == null || _rs.Length < need) _rs = new byte[need];
        for (int i = 0; i < outFrames; i++)
        {
            double src = (double)i * _loopRate / _audioOutRate; int i0 = (int)src; int i1 = Math.Min(i0 + 1, frames - 1); double t = src - i0;
            for (int c = 0; c < ch; c++)
            {
                short a = BitConverter.ToInt16(_pcm!, (i0 * ch + c) * 2), b = BitConverter.ToInt16(_pcm!, (i1 * ch + c) * 2);
                short v = (short)(a + (b - a) * t);
                _rs[(i * ch + c) * 2] = (byte)v; _rs[(i * ch + c) * 2 + 1] = (byte)(v >> 8);
            }
        }
        (_pcm, _rs) = (_rs, _pcm); frames = outFrames;
    }

    /// <summary>Stop everything and finish the file. Returns the file size. Each step is traced: a hang here is invisible otherwise.</summary>
    public long Stop(string path)
    {
        lock (_lock) { _writing = false; }
        try { _pump?.Dispose(); } catch { } _pump = null;
        lock (_lock)
        {
            // The picture on screen at the end holds to the end; the sound runs to the same instant.
            var end = SlideTrack.MonotonicSeconds();
            if (_pending != null && _writer != null) { WriteVideo(_pending, _pendingMono, Math.Max(0.001, end - _pendingMono)); _pending = null; }
            try { FillSilenceTo(end); } catch { }
        }
        Trace?.Invoke("stop: capture session");
        try { _session?.Dispose(); } catch { }
        Trace?.Invoke("stop: frame pool");
        try { if (_pool != null) { _pool.FrameArrived -= OnFrame; _pool.Dispose(); } } catch { }
        Trace?.Invoke("stop: loopback");
        try { _loopback?.StopRecording(); _loopback?.Dispose(); } catch { }
        _session = null; _pool = null; _loopback = null;
        lock (_lock)
        {
            Trace?.Invoke("stop: finalize");
            // Bounded: a sink that never drained would hang here for ever; the fragments on disk are what we keep.
            var w = _writer;
            try { _audioWriter?.Dispose(); } catch (Exception ex) { LastError = ex.Message; }   // the last page; quick
            _audioWriter = null;
            if (w != null)
            {
                var t = new Thread(() => { try { w.Finalize(); } catch (Exception ex) { LastError = ex.Message; } }) { IsBackground = true };
                t.Start();
                if (!t.Join(10_000)) { LastError = "the proxy writer did not finish in 10 s; the file keeps its fragments"; Trace?.Invoke("stop: finalize TIMED OUT"); }
            }
            Trace?.Invoke("stop: finalized");
            _writer?.Dispose(); _writer = null;
            _staging?.Dispose(); _staging = null;
            _context?.Dispose(); _context = null;
            _device?.Dispose(); _device = null;
        }
        try { MediaFactory.MFShutdown(); } catch { }
        try { return new FileInfo(path).Length; } catch { return 0; }
    }

    public void Dispose() { if (_writer != null) Stop(""); }

    /// <summary>
    /// Audio latency probe: 30 s of tone written as fast as the writer takes it, then the process is killed without
    /// Finalize, so the file shows how much sound the encoder and sink were holding. Variant "c1024-ll1-v1-t1":
    /// chunk frames per sample, low latency on/off, a 1 fps video stream present or not, throttling off or on.
    /// </summary>
    public static string AudioProbe(string variant, string folder)
    {
        var parts = variant.Split('-');
        int chunk = int.Parse(parts[0][1..]); bool ll = parts[1] == "ll1", withVideo = parts[2] != "v0", throttleOff = parts[3] == "t1";
        MediaFactory.MFStartup(true).CheckError();
        var path = System.IO.Path.Combine(folder, $"audioprobe-{variant}.mp4");
        var attrs = MediaFactory.MFCreateAttributes(4);
        attrs.Set(TranscodeAttributeKeys.TranscodeContainertype, TranscodeContainerTypeGuids.Fmpeg4);
        attrs.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, false);
        if (throttleOff) attrs.Set(SinkWriterAttributeKeys.DisableThrottling, true);
        if (ll) attrs.Set(SinkWriterAttributeKeys.LowLatency, true);
        var wr = MediaFactory.MFCreateSinkWriterFromURL(path, null, attrs);
        int vi = -1, w = 640, h = 360;
        if (withVideo) { vi = AddVideoOut(wr, w, h, 10, 300_000); SetVideoIn(wr, vi, w, h, 10, "nv12"); }
        int rate = 48000, ch = 2;
        var aOut = MediaFactory.MFCreateMediaType();
        aOut.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio); aOut.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Aac);
        aOut.Set(MediaTypeAttributeKeys.AudioNumChannels, (uint)ch); aOut.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)rate);
        aOut.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16); aOut.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)12_000);
        int ai = wr.AddStream(aOut);
        var aIn = MediaFactory.MFCreateMediaType();
        aIn.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio); aIn.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Pcm);
        aIn.Set(MediaTypeAttributeKeys.AudioNumChannels, (uint)ch); aIn.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)rate);
        aIn.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16); aIn.Set(MediaTypeAttributeKeys.AudioBlockAlignment, (uint)(ch * 2));
        aIn.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)(rate * ch * 2)); aIn.Set(MediaTypeAttributeKeys.AllSamplesIndependent, true);
        wr.SetInputMediaType(ai, aIn, null);
        wr.BeginWriting();
        var pcm = new byte[chunk * ch * 2];
        var nv12 = new byte[w * h * 3 / 2]; Array.Fill(nv12, (byte)128);
        // Video schedule: v1 = 1 fps with 1 s durations; v2 = 2 fps, 0.5 s; v3 = the app's shape (holds 0.1 to 2 s,
        // each frame written when the next change arrives, as in the recorder).
        var sched = new List<(double pts, double dur)>();
        if (withVideo)
        {
            double[] pattern = parts[2] == "v3" ? new[] { 0.5, 0.5, 0.1, 0.1, 0.1, 2.0, 1.3, 0.53, 0.53, 0.12, 0.25, 2.0, 2.0, 0.4 } : parts[2] == "v2" ? new[] { 0.5 } : new[] { 1.0 };
            double t = 0; int k = 0;
            while (t < 30) { var d = pattern[k++ % pattern.Length]; sched.Add((t, d)); t += d; }
        }
        long written = 0; int vIdx = 0; int n = 0;
        while (written < 30L * rate)
        {
            double t = (double)written / rate;
            // The frame at sched[vIdx] is written once the clock passes its end (the next change).
            while (vIdx < sched.Count && t >= sched[vIdx].pts + sched[vIdx].dur)
            {
                var (vpts, vdur) = sched[vIdx++];
                var vs = MediaFactory.MFCreateSample(); var vb = MediaFactory.MFCreateMemoryBuffer(nv12.Length);
                nv12[0] = (byte)(vIdx * 7);   // every frame differs a little
                vb.Lock(out var vp, out _, out _); Marshal.Copy(nv12, 0, vp, nv12.Length); vb.Unlock(); vb.CurrentLength = nv12.Length; vs.AddBuffer(vb);
                vs.SampleTime = (long)(vpts * 10_000_000); vs.SampleDuration = (long)(vdur * 10_000_000); wr.WriteSample(vi, vs); vb.Dispose(); vs.Dispose();
            }
            for (int i = 0; i < chunk; i++) { short v = (short)(8000 * Math.Sin(2 * Math.PI * 440 * (written + i) / rate)); for (int c = 0; c < ch; c++) { pcm[(i * ch + c) * 2] = (byte)v; pcm[(i * ch + c) * 2 + 1] = (byte)(v >> 8); } }
            var s = MediaFactory.MFCreateSample(); var b = MediaFactory.MFCreateMemoryBuffer(pcm.Length);
            b.Lock(out var p, out _, out _); Marshal.Copy(pcm, 0, p, pcm.Length); b.Unlock(); b.CurrentLength = pcm.Length; s.AddBuffer(b);
            s.SampleTime = written * 10_000_000 / rate; s.SampleDuration = (long)chunk * 10_000_000 / rate;
            wr.WriteSample(ai, s); b.Dispose(); s.Dispose();
            written += chunk; n++;
        }
        Thread.Sleep(500);   // let any asynchronous work land before the kill
        return $"{variant}: {n} audio samples, {written / rate} s written, file {new FileInfo(path).Length} bytes before the kill";
    }

    /// <summary>
    /// Sink timing probe: synthetic NV12 frames with chosen presentation times into each container, to see what
    /// timeline the sink keeps. Pattern: 11 frames at 0..1 s, 11 at 6..7 s, 11 at 20..21 s (the picture changes at
    /// each block), so an honoured timeline runs 21.1 s. Variants: fixed 0.1 s durations, durations to the next
    /// frame, and a constant-rate stream that repeats the picture every 0.1 s.
    /// </summary>
    public static IEnumerable<string> SinkTimingProbe(string folder)
    {
        var lines = new List<string>();
        try { MediaFactory.MFStartup(true).CheckError(); } catch (Exception ex) { lines.Add("MFStartup: " + ex.Message); }
        int w = 640, h = 360;
        var blocks = new[] { 0.0, 6.0, 20.0 };
        foreach (var fmp4 in new[] { true, false })
        foreach (var pattern in new[] { "sparse-fixdur", "sparse-nextdur", "cfr" })
        {
            var path = System.IO.Path.Combine(folder, $"sinkprobe-{(fmp4 ? "fmp4" : "mp4")}-{pattern}.mp4");
            try
            {
                var wr = CreateWriter(path, fmp4, true);
                int vi = AddVideoOut(wr, w, h, 10, 300_000);
                SetVideoIn(wr, vi, w, h, 10, "nv12");
                wr.BeginWriting();
                var times = new List<(double t, int block)>();
                if (pattern == "cfr") for (int i = 0; i <= 210; i++) { double t = i / 10.0; times.Add((t, t >= 20 ? 2 : t >= 6 ? 1 : 0)); }
                else for (int b = 0; b < blocks.Length; b++) for (int i = 0; i <= 10; i++) times.Add((blocks[b] + i / 10.0, b));
                var nv12 = new byte[w * h * 3 / 2];
                int n = 0;
                for (int k = 0; k < times.Count; k++)
                {
                    var (t, block) = times[k];
                    byte y = (byte)(40 + block * 80);
                    Array.Fill(nv12, y, 0, w * h); Array.Fill(nv12, (byte)128, w * h, w * h / 2);
                    // A moving bar so every frame differs a little (a real screen is never identical two frames running, when it moves).
                    int bar = (int)(t * 10) % w; for (int row = 0; row < 20; row++) Array.Fill(nv12, (byte)235, row * w + bar, Math.Min(16, w - bar));
                    var sample = MediaFactory.MFCreateSample();
                    var buffer = MediaFactory.MFCreateMemoryBuffer(nv12.Length);
                    buffer.Lock(out var p, out _, out _); Marshal.Copy(nv12, 0, p, nv12.Length); buffer.Unlock();
                    buffer.CurrentLength = nv12.Length; sample.AddBuffer(buffer);
                    sample.SampleTime = (long)(t * 10_000_000);
                    long dur = 1_000_000;
                    if (pattern == "sparse-nextdur" && k + 1 < times.Count) dur = (long)((times[k + 1].t - t) * 10_000_000);
                    sample.SampleDuration = dur;
                    wr.WriteSample(vi, sample); n++;
                    buffer.Dispose(); sample.Dispose();
                }
                wr.Finalize(); wr.Dispose();
                lines.Add($"{System.IO.Path.GetFileName(path)}: {n} frames written, last pts {times[^1].t:F1} s, {new FileInfo(path).Length} bytes");
            }
            catch (Exception ex) { lines.Add($"{System.IO.Path.GetFileName(path)}: FAIL {ex.Message.Split('\n')[0]}"); }
        }
        return lines;
    }


    /// <summary>
    /// Run the writer setup the way Start does, at the size Start would use for `monitor`, in this very process,
    /// and report each variant: the same binary, so Application Control cannot tell the two apart.
    /// </summary>
    public static IEnumerable<string> SelfProbe(MonitorInfo monitor, bool captureFirst, string folder)
    {
        var lines = new List<string>();
        ID3D11Device? dev = null; ID3D11DeviceContext? ctx = null; GraphicsCaptureItem? item = null;
        int w = 640, h = 360;
        if (captureFirst)
        {
            try
            {
                D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, null, out dev, out ctx).CheckError();
                using var dxgi = dev!.QueryInterface<IDXGIDevice>();
                Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var insp));
                var wd = MarshalInterface<IDirect3DDevice>.FromAbi(insp); Marshal.Release(insp);
                var factory = Factory<IGraphicsCaptureItemInterop>("Windows.Graphics.Capture.GraphicsCaptureItem");
                var iid = IID_IGraphicsCaptureItem;
                var itemPtr = factory.CreateForMonitor(monitor.Handle, ref iid);
                item = GraphicsCaptureItem.FromAbi(itemPtr); Marshal.Release(itemPtr);
                var size = item.Size;
                int f = Math.Max(1, (int)Math.Ceiling(Math.Max(size.Width, size.Height) / 640.0));
                w = (size.Width / f) & ~1; h = (size.Height / f) & ~1;
                lines.Add($"capture init ok: item {size.Width}x{size.Height} -> {w}x{h}");
            }
            catch (Exception ex) { lines.Add("capture init FAILED: " + ex.Message); }
        }
        try { MediaFactory.MFStartup(true).CheckError(); } catch (Exception ex) { lines.Add("MFStartup: " + ex.Message); }
        foreach (var fmp4 in new[] { true, false })
        foreach (var throttleOff in new[] { true, false })
        foreach (var vin in new[] { "nv12", "rgb32" })
        {
            string stage = "attrs";
            try
            {
                var path = System.IO.Path.Combine(folder, $"selfprobe-{(fmp4 ? "f" : "m")}-{(throttleOff ? "t" : "n")}-{vin}.mp4");
                stage = "writer"; var wr = CreateWriter(path, fmp4, throttleOff);
                stage = "video out"; int vi = AddVideoOut(wr, w, h, 10, 300_000);
                stage = "video in"; SetVideoIn(wr, vi, w, h, 10, vin);
                stage = "begin"; wr.BeginWriting();
                wr.Dispose();
                lines.Add($"{(fmp4 ? "fmp4" : "mp4 ")} throttleOff={throttleOff,-5} {vin,-5} {w}x{h} OK");
            }
            catch (Exception ex) { lines.Add($"{(fmp4 ? "fmp4" : "mp4 ")} throttleOff={throttleOff,-5} {vin,-5} {w}x{h} FAIL at {stage}: {ex.Message.Split('\n')[0]}"); }
        }
        item = null; ctx?.Dispose(); dev?.Dispose();
        return lines;
    }
}
