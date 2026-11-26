using System.Diagnostics;

namespace ArcSlideLog;

/// <summary>
/// ARC Slide Log for Windows: a tray app that records three things during a live session so ARC Edit can
/// rebuild the click-through from the deck files: a very low resolution recording of the program display
/// with the presentation's sound, every click impulse with its time, and a scratch track from the laptop.
/// Launch arguments for drills: --display main|&lt;name part&gt;, --show NAME, --out FOLDER, --no-scratch,
/// --start, --stop-after SECONDS.
/// </summary>
static class Program
{
    public static void ProbeAt(string where)
    {
        try
        {
            var mon = ProxyRecorder.Monitors().FirstOrDefault(m => m.Primary) ?? ProxyRecorder.Monitors().First();
            var folder = Path.Combine(Path.GetTempPath(), "arc-slide-log-probe"); Directory.CreateDirectory(folder);
            var line = ProxyRecorder.SelfProbe(mon, false, folder).FirstOrDefault(l => l.Contains("nv12")) ?? "no result";
            Session.Log($"probe {where}: {(line.Contains(" OK") ? "OK" : line)}");
        }
        catch (Exception ex) { Session.Log($"probe {where} threw: {ex.Message.Split('\n')[0]}"); }
    }

    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (Array.IndexOf(args, "--audio-probe") is int api && api >= 0 && api + 1 < args.Length)
        {
            var folder = Path.Combine(Path.GetTempPath(), "arc-slide-log-probe"); Directory.CreateDirectory(folder);
            try { Session.Log("AUDIO PROBE " + ProxyRecorder.AudioProbe(args[api + 1], folder)); }
            catch (Exception ex) { Session.Log("AUDIO PROBE " + args[api + 1] + " FAILED: " + ex.Message); }
            Process.GetCurrentProcess().Kill();   // no Finalize: what is on disk is what a crash would leave
            return;
        }
        if (args.Contains("--sink-probe"))
        {
            var folder = Path.Combine(Path.GetTempPath(), "arc-slide-log-probe"); Directory.CreateDirectory(folder);
            Session.Log("SINK TIMING PROBE into " + folder);
            foreach (var l in ProxyRecorder.SinkTimingProbe(folder)) Session.Log("  " + l);
            return;
        }
        if (args.Contains("--probe"))
        {
            // The writer-type probe inside the app's own process and apartment: results go to the show log.
            var mon = ProxyRecorder.Monitors().FirstOrDefault(m => m.Primary) ?? ProxyRecorder.Monitors().First();
            var folder = Path.Combine(Path.GetTempPath(), "arc-slide-log-probe"); Directory.CreateDirectory(folder);
            Session.Log("PROBE pure (no capture first):");
            foreach (var l in ProxyRecorder.SelfProbe(mon, false, folder)) Session.Log("  " + l);
            Session.Log("PROBE after capture init:");
            foreach (var l in ProxyRecorder.SelfProbe(mon, true, folder)) Session.Log("  " + l);
            // The session starts scratch audio and the hooks before the proxy: does either poison the encoder?
            using (var scratch = new ScratchAudio())
            {
                try { scratch.Start(null, Path.Combine(folder, "probe.wav")); Session.Log("PROBE with scratch audio running:"); }
                catch (Exception ex) { Session.Log("PROBE scratch start failed: " + ex.Message); }
                foreach (var l in ProxyRecorder.SelfProbe(mon, false, folder)) Session.Log("  " + l);
            }
            using (var clicks = new ClickLogger())
            {
                try { clicks.Start(); Session.Log("PROBE with hooks installed:"); } catch (Exception ex) { Session.Log("PROBE hooks failed: " + ex.Message); }
                foreach (var l in ProxyRecorder.SelfProbe(mon, false, folder)) Session.Log("  " + l);
            }
            Session.Log("PROBE from a pool thread:");
            foreach (var l in Task.Run(() => ProxyRecorder.SelfProbe(mon, false, folder).ToList()).GetAwaiter().GetResult()) Session.Log("  " + l);
            return;
        }
        using var mutex = new Mutex(true, "ARC Slide Log", out bool first);
        if (!first) return;   // one instance
        Application.Run(new TrayApp(args));
    }
}

sealed class TrayApp : ApplicationContext
{
    readonly Session _session = new();
    readonly NotifyIcon _icon;
    readonly ContextMenuStrip _menu = new();
    readonly bool _unattended;

    public TrayApp(string[] args)
    {
        _unattended = args.Contains("--stop-after");
        _icon = new NotifyIcon { Icon = LoadIcon(), Visible = true, Text = "ARC Slide Log", ContextMenuStrip = _menu };
        _menu.Opening += (_, _) => Rebuild();
        Rebuild();
        Application.ApplicationExit += (_, _) => { _session.Stop(); _icon.Visible = false; };
        Apply(args);
    }

    static Icon LoadIcon()
    {
        try { return Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application; } catch { return SystemIcons.Application; }
    }

    static string? Value(string[] a, string flag) { var i = Array.IndexOf(a, flag); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }

    void Apply(string[] a)
    {
        if (Value(a, "--display") is string d)
        {
            var m = d == "main" ? _session.Monitors.FirstOrDefault(x => x.Primary) : _session.Monitors.FirstOrDefault(x => x.Name.Contains(d, StringComparison.OrdinalIgnoreCase));
            if (m != null) _session.SelectedMonitor = m.Name;
        }
        if (Value(a, "--show") is string s) _session.ShowName = s;
        if (Value(a, "--out") is string o) _session.OutputBase = o;
        if (a.Contains("--no-scratch")) _session.RecordScratch = false;
        if (a.Contains("--start")) _session.Start();
        if (Value(a, "--stop-after") is string t && double.TryParse(t, out var secs))
        {
            var timer = new System.Windows.Forms.Timer { Interval = (int)(secs * 1000) };
            timer.Tick += (_, _) => { timer.Stop(); _session.Stop(); Exit(); };
            timer.Start();
        }
    }

    void Rebuild()
    {
        _menu.Items.Clear();
        _session.UpdateDiskFree();
        if (_session.IsRunning)
        {
            Add($"LOGGING {_session.Elapsed:hh\\:mm\\:ss} · {_session.Clicks} clicks · {_session.ProxyFrames} frames · {_session.ProxyBytes / 1_000_000} MB", false);
            Add($"scratch {(_session.RecordScratch ? $"{_session.AudioSeconds:F0} s at {Math.Max(-60, _session.AudioLevelDB):F0} dB" : "off")} · disk {_session.DiskFreeGB:F0} GB free", false);
            Add("Stop logging", true, (_, _) => _session.Stop());
        }
        else
        {
            Add($"Not logging · disk {_session.DiskFreeGB:F0} GB free", false);
            Add("Start logging", _session.Selected != null, (_, _) => _session.Start());
        }
        if (_session.LastError != null) Add(_session.LastError, false);
        _menu.Items.Add(new ToolStripSeparator());
        var displays = new ToolStripMenuItem("Program display") { Enabled = !_session.IsRunning };
        foreach (var m in _session.Monitors)
            displays.DropDownItems.Add(new ToolStripMenuItem($"{m.Name} {m.Width}x{m.Height}{(m.Primary ? " (main)" : "")}", null, (_, _) => _session.SelectedMonitor = m.Name) { Checked = m.Name == _session.SelectedMonitor });
        _menu.Items.Add(displays);
        var inputs = new ToolStripMenuItem("Scratch input") { Enabled = !_session.IsRunning };
        foreach (var d in _session.AudioDevices)
            inputs.DropDownItems.Add(new ToolStripMenuItem(d.Name, null, (_, _) => _session.SelectedAudioId = d.Id) { Checked = d.Id == _session.SelectedAudioId });
        _menu.Items.Add(inputs);
        _menu.Items.Add(new ToolStripMenuItem("Record scratch audio", null, (_, _) => _session.RecordScratch = !_session.RecordScratch) { Checked = _session.RecordScratch, Enabled = !_session.IsRunning });
        Add("Rescan displays and inputs", true, (_, _) => _session.Refresh());
        _menu.Items.Add(new ToolStripSeparator());
        Add($"Sessions: {_session.OutputBase}", false);
        Add("Open sessions folder", true, (_, _) => { Directory.CreateDirectory(_session.Folder ?? _session.OutputBase); Process.Start("explorer.exe", _session.Folder ?? _session.OutputBase); });
        Add("Choose sessions folder…", !_session.IsRunning, (_, _) => ChooseFolder());
        _menu.Items.Add(new ToolStripMenuItem("Launch at login", null, (_, _) => _session.LaunchAtLogin = !_session.LaunchAtLogin) { Checked = _session.LaunchAtLogin });
        _menu.Items.Add(new ToolStripSeparator());
        Add($"ARC Slide Log {Session.Version}", false);
        Add("Quit ARC Slide Log", true, (_, _) => Quit());
    }

    void Add(string text, bool enabled, EventHandler? click = null) => _menu.Items.Add(new ToolStripMenuItem(text, null, click) { Enabled = enabled });

    void ChooseFolder()
    {
        using var d = new FolderBrowserDialog { Description = "Sessions are written as subfolders here", InitialDirectory = _session.OutputBase, UseDescriptionForTitle = true };
        if (d.ShowDialog() == DialogResult.OK) _session.OutputBase = d.SelectedPath;
    }

    void Quit()
    {
        if (_session.IsRunning && !_unattended)
        {
            var r = MessageBox.Show("ARC Slide Log is logging. Quitting ends the session; the files written so far stay readable.", "ARC Slide Log", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
            if (r != DialogResult.OK) return;
        }
        Exit();
    }

    void Exit() { _session.Stop(); _icon.Visible = false; Application.Exit(); }
}
