using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ArcSlideLog;

/// <summary>
/// Click impulses: every key press and mouse button through low-level hooks (WH_KEYBOARD_LL, WH_MOUSE_LL),
/// with the capture clock reading and the process in front. Keys are logged by name or code, never as typed
/// text. The hooks live on the UI thread's message loop; the app must not run elevated, or it would not see
/// the presenter's (non-elevated) apps' input, and the other way round.
/// </summary>
public sealed class ClickLogger : IDisposable
{
    public record Click(double Mono, string Source, string Name, string? Modifiers, string? App);
    public event Action<Click>? OnClick;
    public int Count { get; private set; }

    IntPtr _kb, _mouse;
    HookProc? _kbProc, _mouseProc;   // kept alive: the delegate must outlive the hook
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    const int WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104, WM_LBUTTONDOWN = 0x0201, WM_RBUTTONDOWN = 0x0204, WM_MBUTTONDOWN = 0x0207, WM_XBUTTONDOWN = 0x020B;

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookExW(int id, HookProc proc, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(string? name);

    [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }

    /// <summary>Virtual-key names a clicker or a presenter uses; anything else is "key N".</summary>
    public static readonly Dictionary<int, string> Names = new()
    {
        [0x25] = "left", [0x27] = "right", [0x28] = "down", [0x26] = "up", [0x21] = "pageup", [0x22] = "pagedown",
        [0x24] = "home", [0x23] = "end", [0x20] = "space", [0x0D] = "return", [0x1B] = "esc", [0x09] = "tab", [0x08] = "delete",
        [0x42] = "b", [0x57] = "w", [0x74] = "f5", [0x70] = "f1", [0x71] = "f2", [0x72] = "f3", [0x73] = "f4", [0x75] = "f6",
        [0x76] = "f7", [0x77] = "f8", [0x78] = "f9", [0x79] = "f10", [0x7A] = "f11", [0x7B] = "f12", [0x50] = "p", [0x44] = "d", [0x49] = "i",
    };
    public static string Name(int vk) => Names.TryGetValue(vk, out var n) ? n : $"key {vk}";

    public static string? Modifiers()
    {
        var m = new List<string>();
        if ((GetAsyncKeyState(0x5B) & 0x8000) != 0 || (GetAsyncKeyState(0x5C) & 0x8000) != 0) m.Add("win");
        if ((GetAsyncKeyState(0x12) & 0x8000) != 0) m.Add("alt");
        if ((GetAsyncKeyState(0x11) & 0x8000) != 0) m.Add("ctrl");
        if ((GetAsyncKeyState(0x10) & 0x8000) != 0) m.Add("shift");
        return m.Count == 0 ? null : string.Join("+", m);
    }

    public static string? ForegroundApp()
    {
        try
        {
            var h = GetForegroundWindow();
            if (h == IntPtr.Zero) return null;
            GetWindowThreadProcessId(h, out var pid);
            if (pid == 0) return null;
            using var p = Process.GetProcessById((int)pid);
            return p.ProcessName;
        }
        catch { return null; }
    }

    public void Start()
    {
        if (_kb != IntPtr.Zero) return;
        var mod = GetModuleHandleW(null);
        _kbProc = KeyboardHook; _mouseProc = MouseHook;
        _kb = SetWindowsHookExW(WH_KEYBOARD_LL, _kbProc, mod, 0);
        _mouse = SetWindowsHookExW(WH_MOUSE_LL, _mouseProc, mod, 0);
        if (_kb == IntPtr.Zero || _mouse == IntPtr.Zero) throw new InvalidOperationException($"hooks failed (error {Marshal.GetLastWin32Error()})");
        Count = 0;
    }

    IntPtr KeyboardHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN))
        {
            var mono = SlideTrack.MonotonicSeconds();
            var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            // A modifier alone is not a press worth a line; its state rides with the next key.
            if (k.vkCode is not (0x10 or 0x11 or 0x12 or 0x5B or 0x5C or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5))
            {
                Count++;
                OnClick?.Invoke(new Click(mono, "key", Name((int)k.vkCode), Modifiers(), ForegroundApp()));
            }
        }
        return CallNextHookEx(_kb, code, wParam, lParam);
    }

    IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            string? name = (int)wParam switch { WM_LBUTTONDOWN => "mouse-left", WM_RBUTTONDOWN => "mouse-right", WM_MBUTTONDOWN => "mouse-middle", WM_XBUTTONDOWN => "mouse-x", _ => null };
            if (name != null)
            {
                Count++;
                OnClick?.Invoke(new Click(SlideTrack.MonotonicSeconds(), "mouse", name, Modifiers(), ForegroundApp()));
            }
        }
        return CallNextHookEx(_mouse, code, wParam, lParam);
    }

    public void Stop()
    {
        if (_kb != IntPtr.Zero) { UnhookWindowsHookEx(_kb); _kb = IntPtr.Zero; }
        if (_mouse != IntPtr.Zero) { UnhookWindowsHookEx(_mouse); _mouse = IntPtr.Zero; }
    }

    public void Dispose() => Stop();
}
