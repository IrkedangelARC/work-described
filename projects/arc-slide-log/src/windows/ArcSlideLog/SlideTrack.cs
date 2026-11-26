using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ArcSlideLog;

/// <summary>
/// The SLIDE TRACK session format, the same bytes the Mac app and ARC Presenter write (arc-show-format
/// SlideTrack.swift): header.json beside track.jsonl, snake_case keys, nil keys omitted, one event per line
/// appended live. t_mono is seconds since the session start on the monotonic clock; t_wall is ISO 8601
/// with milliseconds and the local offset.
/// </summary>
public static class SlideTrack
{
    public const int FormatVersion = 1;
    public const string TrackFile = "track.jsonl";
    public const string HeaderFile = "header.json";

    /// <summary>Seconds on a clock that only goes forward (QueryPerformanceCounter).</summary>
    public static double MonotonicSeconds() => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;

    public static string SessionName(string? show, DateTime? at = null)
    {
        var stamp = (at ?? DateTime.Now).ToString("yyyy-MM-dd_HHmmss");
        if (string.IsNullOrWhiteSpace(show)) return stamp;
        var safe = new StringBuilder();
        foreach (var ch in show) safe.Append(char.IsLetterOrDigit(ch) || ch is '-' or '_' or '.' ? ch : '-');
        return safe.ToString().Trim('-') + "_" + stamp;
    }

    public sealed class Header
    {
        public int Format { get; set; } = FormatVersion;
        public string App { get; set; } = "ARC Slide Log";
        public string AppVersion { get; set; } = "?";
        public string Path { get; set; } = "C";
        public string? Show { get; set; }
        public string Session { get; set; } = "";
        public string Machine { get; set; } = Environment.MachineName;
        public string System { get; set; } = "";
        public string? Display { get; set; }
        public string? Device { get; set; }
        public int? Width { get; set; }
        public int? Height { get; set; }
        public double? Rate { get; set; }
        public DateTimeOffset StartWall { get; set; }
        public double StartMono { get; set; }
        public string TimeZone { get; set; } = TimeZoneInfo.Local.Id;
        public int UtcOffsetSeconds { get; set; }
        public double? NtpOffsetMsStart { get; set; }
        public double? NtpOffsetMsEnd { get; set; }
        public string SyncMethod { get; set; } = "none";
        public string? ScratchAudio { get; set; }
        public double? ScratchAudioStartMono { get; set; }
        public string? Proxy { get; set; }
        /// <summary>Windows: the proxy's sound in its own file next to proxy.mp4, same timeline (starts at proxy_start_mono).</summary>
        public string? ProxyAudio { get; set; }
        public int? ProxyWidth { get; set; }
        public int? ProxyHeight { get; set; }
        public double? ProxyRate { get; set; }
        public double? ProxyStartMono { get; set; }
        public string? AgendaFile { get; set; }
        public DateTimeOffset? EndWall { get; set; }
        public double? EndMono { get; set; }
        public int? Events { get; set; }
    }

    public sealed class Event
    {
        public DateTimeOffset TWall { get; set; }
        public double TMono { get; set; }
        public string Kind { get; set; } = "OTHER";
        public string? Still { get; set; }
        public string? Clip { get; set; }
        public double? ClipPosition { get; set; }
        public string? Deck { get; set; }
        public string? DeckFile { get; set; }
        public int? DeckVersion { get; set; }
        public string? DeckHash { get; set; }
        public int? Page { get; set; }
        public int? Pages { get; set; }
        public int? Segment { get; set; }
        public int? Segments { get; set; }
        public int? Build { get; set; }
        public int? Builds { get; set; }
        public bool? Black { get; set; }
        public bool? IsVideo { get; set; }
        public string? Source { get; set; }
        public string? App { get; set; }
        public string? Url { get; set; }
        public string? Program { get; set; }
        public double? Score { get; set; }
        public string? Note { get; set; }
    }

    public static class Kinds
    {
        public const string SessionStart = "SESSION_START", SessionEnd = "SESSION_END", Click = "CLICK", Mark = "MARK",
            Talk = "TALK", SignalLost = "SIGNAL_LOST", SignalBack = "SIGNAL_BACK";
    }

    sealed class WallConverter : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => DateTimeOffset.Parse(r.GetString()!);
        public override void Write(Utf8JsonWriter w, DateTimeOffset v, JsonSerializerOptions o) => w.WriteStringValue(v.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz"));
    }

    static readonly JsonSerializerOptions LineOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new WallConverter() },
    };
    static readonly JsonSerializerOptions HeaderOptions = new(LineOptions) { WriteIndented = true };

    public static string Line(Event e) => JsonSerializer.Serialize(e, LineOptions);
    public static string HeaderJson(Header h) => JsonSerializer.Serialize(h, HeaderOptions);

    /// <summary>One session: creates the folder and header.json, appends events as they come, ends with SESSION_END.</summary>
    public sealed class Writer : IDisposable
    {
        public string Folder { get; }
        public Header Header { get; }
        readonly object _lock = new();
        FileStream? _track;
        int _count;
        bool _ended;
        public int Count { get { lock (_lock) return _count; } }

        public Writer(string folder, Header header)
        {
            Folder = folder; Header = header;
            Directory.CreateDirectory(folder);
            File.WriteAllText(System.IO.Path.Combine(folder, HeaderFile), HeaderJson(header));
            _track = new FileStream(System.IO.Path.Combine(folder, TrackFile), FileMode.Append, FileAccess.Write, FileShare.Read);
            Append(NewEvent(Kinds.SessionStart));
        }

        public Event NewEvent(string kind) => new() { TWall = DateTimeOffset.Now, TMono = MonotonicSeconds() - Header.StartMono, Kind = kind };

        /// <summary>An event stamped at a capture clock reading taken earlier.</summary>
        public Event NewEvent(string kind, double mono)
        {
            var now = MonotonicSeconds();
            return new Event { TWall = DateTimeOffset.Now.AddSeconds(mono - now), TMono = mono - Header.StartMono, Kind = kind };
        }

        public void Append(Event e)
        {
            var bytes = Encoding.UTF8.GetBytes(Line(e) + "\n");
            lock (_lock)
            {
                if (_ended || _track == null) return;
                _track.Write(bytes); _track.Flush(true);
                _count++;
            }
        }

        public void UpdateHeader(Action<Header> change)
        {
            lock (_lock)
            {
                change(Header);
                File.WriteAllText(System.IO.Path.Combine(Folder, HeaderFile), HeaderJson(Header));
            }
        }

        public void End()
        {
            Append(NewEvent(Kinds.SessionEnd));
            lock (_lock)
            {
                if (_ended) return;
                _ended = true;
                Header.EndWall = DateTimeOffset.Now;
                Header.EndMono = MonotonicSeconds() - Header.StartMono;
                Header.Events = _count;
                File.WriteAllText(System.IO.Path.Combine(Folder, HeaderFile), HeaderJson(Header));
                _track?.Dispose(); _track = null;
            }
        }

        public void Dispose() => End();
    }
}
