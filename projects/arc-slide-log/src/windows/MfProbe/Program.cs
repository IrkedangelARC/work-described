// Media Foundation sink-writer probe: which type combinations does this machine accept? Runs over SSH.
using Vortice.MediaFoundation;

static ulong Pack(int hi, int lo) => ((ulong)(uint)hi << 32) | (uint)lo;

// --sta: run the whole probe on a single-threaded apartment, as a WinForms UI thread would.
if (args.Contains("--sta"))
{
    var t = new Thread(() => Run(new[] { "mp4", "fmp4" })); t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join(); return;
}
Run(new[] { "fmp4" });

static void Run(string[] containers)
{
int W = int.Parse(Environment.GetEnvironmentVariable("PROBE_W") ?? "640"), H = int.Parse(Environment.GetEnvironmentVariable("PROBE_H") ?? "360");
bool throttleOff = Environment.GetEnvironmentVariable("PROBE_THROTTLE") == "off";
Console.WriteLine($"size {W}x{H}, throttling {(throttleOff ? "disabled" : "default")}");
Console.WriteLine("apartment: " + Thread.CurrentThread.GetApartmentState());
MediaFactory.MFStartup(true).CheckError();
var path = Path.Combine(Path.GetTempPath(), "mfprobe.mp4");
Console.WriteLine($"Vortice MF probe on {Environment.MachineName}, {Environment.OSVersion}");
Console.WriteLine("key types: " + string.Join(", ", new[] { "FrameSize", "FrameRate", "InterlaceMode", "AvgBitrate", "AllSamplesIndependent", "DefaultStride" }.Select(n => n + "=" + typeof(MediaTypeAttributeKeys).GetField(n)!.FieldType.GenericTypeArguments.FirstOrDefault()?.Name)));

foreach (var container in containers)
foreach (var hw in new[] { false })
foreach (var vin in new[] { "nv12", "rgb32" })
{
    string stage = "attrs";
    try
    {
        var attrs = MediaFactory.MFCreateAttributes(4);
        if (container == "fmp4") attrs.Set(TranscodeAttributeKeys.TranscodeContainertype, TranscodeContainerTypeGuids.Fmpeg4);
        else attrs.Set(TranscodeAttributeKeys.TranscodeContainertype, TranscodeContainerTypeGuids.Mpeg4);
        attrs.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, hw);
        if (throttleOff) attrs.Set(SinkWriterAttributeKeys.DisableThrottling, true);
        stage = "writer"; File.Delete(path);
        var w = MediaFactory.MFCreateSinkWriterFromURL(path, null, attrs);
        var vOut = MediaFactory.MFCreateMediaType();
        vOut.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        vOut.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.H264);
        vOut.Set(MediaTypeAttributeKeys.AvgBitrate, 300_000);
        vOut.Set(MediaTypeAttributeKeys.InterlaceMode, (int)VideoInterlaceMode.Progressive);
        vOut.Set(MediaTypeAttributeKeys.FrameSize, Pack(W, H));
        vOut.Set(MediaTypeAttributeKeys.FrameRate, Pack(10, 1));
        vOut.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
        stage = "video out"; int vi = w.AddStream(vOut);
        var vIn = MediaFactory.MFCreateMediaType();
        vIn.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        vIn.Set(MediaTypeAttributeKeys.Subtype, vin.StartsWith("nv12") ? VideoFormatGuids.NV12 : VideoFormatGuids.Rgb32);
        vIn.Set(MediaTypeAttributeKeys.InterlaceMode, (int)VideoInterlaceMode.Progressive);
        vIn.Set(MediaTypeAttributeKeys.FrameSize, Pack(W, H));
        vIn.Set(MediaTypeAttributeKeys.FrameRate, Pack(10, 1));
        vIn.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
        if (!vin.EndsWith("-min")) { vIn.Set(MediaTypeAttributeKeys.DefaultStride, vin.StartsWith("nv12") ? W : W * 4); vIn.Set(MediaTypeAttributeKeys.AllSamplesIndependent, true); }
        stage = "video in"; w.SetInputMediaType(vi, vIn, null);
        // audio
        string aud;
        try
        {
            var aOut = MediaFactory.MFCreateMediaType();
            aOut.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
            aOut.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Aac);
            aOut.Set(MediaTypeAttributeKeys.AudioNumChannels, 2);
            aOut.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, 48000);
            aOut.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16);
            aOut.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, 12000);
            stage = "audio out"; int ai = w.AddStream(aOut);
            var aIn = MediaFactory.MFCreateMediaType();
            aIn.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
            aIn.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Pcm);
            aIn.Set(MediaTypeAttributeKeys.AudioNumChannels, 2);
            aIn.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, 48000);
            aIn.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16);
            aIn.Set(MediaTypeAttributeKeys.AudioBlockAlignment, 4);
            aIn.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, 192000);
            aIn.Set(MediaTypeAttributeKeys.AllSamplesIndependent, true);
            stage = "audio in"; w.SetInputMediaType(ai, aIn, null);
            aud = "audio OK";
        }
        catch (Exception ex) { aud = $"audio FAIL at {stage}: {ex.Message.Split('\n')[0][..Math.Min(60, ex.Message.Split('\n')[0].Length)]}"; }
        stage = "begin"; w.BeginWriting();
        // one black NV12/RGB32 frame, then finalize, then the size
        var len = vin.StartsWith("nv12") ? W * H * 3 / 2 : W * H * 4;
        var s = MediaFactory.MFCreateSample(); var b = MediaFactory.MFCreateMemoryBuffer(len); b.Lock(out var p, out _, out _); b.Unlock(); b.CurrentLength = len; s.AddBuffer(b);
        s.SampleTime = 0; s.SampleDuration = 1_000_000; w.WriteSample(vi, s);
        s.SampleTime = 1_000_000; w.WriteSample(vi, s);
        stage = "finalize"; var fin = new Thread(() => { try { w.Finalize(); } catch (Exception ex) { Console.WriteLine("   finalize error: " + ex.Message); } }) { IsBackground = true }; fin.Start();
        var done = fin.Join(8000);
        Console.WriteLine($"{container,-5} hw={hw,-5} {vin,-9} VIDEO OK, {aud}, finalize {(done ? "ok" : "HUNG")}, file {new FileInfo(path).Length} bytes");
    }
    catch (Exception ex) { Console.WriteLine($"{container,-5} hw={hw,-5} {vin,-9} FAIL at {stage}: {ex.Message.Split('\n')[0]}"); }
}

}
