"""Check this Mac is ready: Python, ffmpeg, Resolve Studio scripting. Read-only.

Usage: python3 tools/check_setup.py"""
import shutil
import subprocess
import sys

ok = True


def line(good: bool, what: str, fix: str = "") -> None:
    global ok
    ok &= good
    print(f"[{'OK ' if good else 'FIX'}] {what}" + ("" if good else f"\n      -> {fix}"))


line(sys.version_info >= (3, 10), f"Python {sys.version.split()[0]}", "install Python 3.10+ (brew install python)")
ff = shutil.which("ffmpeg")
line(bool(ff), f"ffmpeg {ff or 'missing'}", "brew install ffmpeg")
if ff:
    out = subprocess.run([ff, "-hide_banner", "-filters"], capture_output=True, text=True).stdout
    line("ebur128" in out, "ffmpeg has the ebur128 loudness meter", "reinstall ffmpeg from Homebrew")

sys.path.insert(0, __file__.rsplit("/", 1)[0])
try:
    from resolve_common import connect
    r, p = connect()
    line(bool(r.IsStudio()) if hasattr(r, "IsStudio") else True, f"{r.GetProductName()} {r.GetVersionString()}",
         "scripting and the AI assistant connection need Resolve STUDIO")
    print(f"      project: {p.GetName()}")
    for i in range(1, p.GetTimelineCount() + 1):
        tl = p.GetTimelineByIndex(i)
        print(f"      timeline {i}: {tl.GetName()}  ({tl.GetSetting('timelineFrameRate')} fps)")
except SystemExit:
    line(False, "Resolve scripting connection", "see the ERROR above, then 06_TROUBLESHOOTING.txt")

print("\nREADY" if ok else "\nNOT READY: fix the lines marked FIX")
sys.exit(0 if ok else 1)
