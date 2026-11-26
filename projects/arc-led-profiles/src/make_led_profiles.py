#!/usr/bin/env python3
"""ARC LED wall correction profiles.

Builds ICC v4 display profiles for the Mac's output to an LED wall when the
wall processor is locked and the Mac is the only control point.

Two correction stages, both live inside the profile:
  vcgt  - per-channel output curve loaded into the GPU (white balance, gamma,
          shadow lift, dimming). Applies to EVERY pixel, colour-managed or not.
  matrix- colorants widened by 1/sat so ColorSync pulls colour toward grey
          (saturation). Applies to colour-managed content, which on macOS is
          the whole WindowServer composite: QuickTime, Keynote, PPT, browsers.

Stdlib only so it runs on any field Mac with python3.

  python3 make_led_profiles.py                 # write all presets to ./profiles
  python3 make_led_profiles.py custom --name "My Fix" --b 0.9 --sat 0.85 ...
"""
import argparse, os, struct, sys
from datetime import datetime, timezone

# sRGB primaries, D65 (IEC 61966-2.1), and Bradford D65 -> D50
SRGB_D65 = [[0.4124564, 0.3575761, 0.1804375],
            [0.2126729, 0.7151522, 0.0721750],
            [0.0193339, 0.1191920, 0.9503041]]
BRADFORD_D65_D50 = [[1.0478112, 0.0228866, -0.0501270],
                    [0.0295424, 0.9904844, -0.0170491],
                    [-0.0092345, 0.0150436, 0.7521316]]
D50 = (0.9642, 1.0, 0.8249)
LUMA = (0.2126729, 0.7151522, 0.0721750)


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def inv3(m):
    a, b, c = m[0]; d, e, f = m[1]; g, h, i = m[2]
    A, B, C = e*i - f*h, -(d*i - f*g), d*h - e*g
    det = a*A + b*B + c*C
    return [[A/det, -(b*i - c*h)/det, (b*f - c*e)/det],
            [B/det, (a*i - c*g)/det, -(a*f - c*d)/det],
            [C/det, -(a*h - b*g)/det, (a*e - b*d)/det]]


def s15(v):
    return struct.pack(">i", int(round(v * 65536)))


def pad4(b):
    return b + b"\0" * (-len(b) % 4)


def mluc(text):
    s = text.encode("utf-16-be")
    return b"mluc" + b"\0"*4 + struct.pack(">II", 1, 12) + b"enUS" + struct.pack(">II", len(s), 28) + s


def xyz(x, y, z):
    return b"XYZ " + b"\0"*4 + s15(x) + s15(y) + s15(z)


def sf32(m):
    return b"sf32" + b"\0"*4 + b"".join(s15(v) for row in m for v in row)


def para_srgb():
    return (b"para" + b"\0"*4 + struct.pack(">HH", 3, 0) +
            s15(2.4) + s15(1/1.055) + s15(0.055/1.055) + s15(1/12.92) + s15(0.04045))


def vcgt(gain, gamma=1.0, lift=0.0, bright=1.0, n=256):
    out = b"vcgt" + b"\0"*4 + struct.pack(">IHHH", 0, 3, n, 2)
    for ch in range(3):
        top = gain[ch] * bright
        for i in range(n):
            x = i / (n - 1)
            y = lift + (top - lift) * (x ** gamma)
            out += struct.pack(">H", int(round(min(max(y, 0.0), 1.0) * 65535)))
    return out


def build(name, r=1.0, g=1.0, b=1.0, sat=1.0, gamma=1.0, lift=0.0, bright=1.0):
    m = matmul(BRADFORD_D65_D50, SRGB_D65)                      # sRGB colorants at D50
    s = [[sat * (i == j) + (1 - sat) * LUMA[j] for j in range(3)] for i in range(3)]
    m = matmul(m, inv3(s))                                       # wider claim -> less sat out
    trc = para_srgb()
    tags = [
        (b"desc", mluc(name)),
        (b"cprt", mluc("ARC Event Productions")),
        (b"wtpt", xyz(*D50)),
        (b"chad", sf32(BRADFORD_D65_D50)),
        (b"rXYZ", xyz(m[0][0], m[1][0], m[2][0])),
        (b"gXYZ", xyz(m[0][1], m[1][1], m[2][1])),
        (b"bXYZ", xyz(m[0][2], m[1][2], m[2][2])),
        (b"rTRC", trc), (b"gTRC", trc), (b"bTRC", trc),
        (b"vcgt", vcgt((r, g, b), gamma, lift, bright)),
    ]
    offset = 128 + 4 + 12 * len(tags)
    table, data, seen = b"", b"", {}
    for sig, body in tags:
        if body in seen:                                         # share identical TRCs
            o, ln = seen[body]
        else:
            o, ln = offset + len(data), len(body)
            seen[body] = (o, ln)
            data += pad4(body)
        table += sig + struct.pack(">II", o, ln)
    size = offset + len(data)
    now = datetime.now(timezone.utc)
    hdr = (struct.pack(">I", size) + b"\0"*4 + struct.pack(">I", 0x04200000) + b"mntrRGB XYZ " +
           struct.pack(">6H", now.year, now.month, now.day, now.hour, now.minute, now.second) +
           b"acspAPPL" + b"\0"*4 + b"\0"*8 + b"\0"*8 + struct.pack(">I", 0) +
           s15(D50[0]) + s15(D50[1]) + s15(D50[2]) + b"ARC " + b"\0"*16 + b"\0"*28)
    assert len(hdr) == 128
    return hdr + struct.pack(">I", len(tags)) + table + data


# name: r, g, b gains | sat | gamma (<1 opens shadows) | lift (black floor) | bright
PRESETS = [
    ("00 Neutral",            {}),
    ("01 Warm 1",             dict(g=0.98, b=0.93)),
    ("02 Warm 2",             dict(g=0.96, b=0.86)),
    ("03 Warm 3",             dict(g=0.93, b=0.78)),
    ("04 Cool 1",             dict(r=0.93, g=0.97)),
    ("05 Cool 2",             dict(r=0.86, g=0.94)),
    ("06 Less Green",         dict(g=0.94)),
    ("07 Less Magenta",       dict(r=0.95, b=0.95)),
    ("08 Shadow Lift 1",      dict(gamma=0.90, lift=0.015)),
    ("09 Shadow Lift 2",      dict(gamma=0.80, lift=0.030)),
    ("10 More Contrast",      dict(gamma=1.12)),
    ("11 Desat 85",           dict(sat=0.85)),
    ("12 Desat 70",           dict(sat=0.70)),
    ("13 Dim 85",             dict(bright=0.85)),
    ("14 Dim 70",             dict(bright=0.70)),
    ("15 Dim 55",             dict(bright=0.55)),
    ("16 LED Typical",        dict(g=0.96, b=0.86, sat=0.85, gamma=0.90, lift=0.015)),
    ("17 LED Typical Dim",    dict(g=0.96, b=0.86, sat=0.85, gamma=0.90, lift=0.015, bright=0.80)),
]


def write(outdir, name, params):
    full = f"ARC LED {name}"
    path = os.path.join(outdir, full + ".icc")
    with open(path, "wb") as f:
        f.write(build(full, **params))
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", nargs="?", default="presets", choices=["presets", "custom"])
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "profiles"))
    ap.add_argument("--name", default="Custom")
    for k, d in (("r", 1.0), ("g", 1.0), ("b", 1.0), ("sat", 1.0), ("gamma", 1.0), ("lift", 0.0), ("bright", 1.0)):
        ap.add_argument(f"--{k}", type=float, default=d)
    ap.add_argument("--install", action="store_true", help="also copy into ~/Library/ColorSync/Profiles")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    items = PRESETS if a.mode == "presets" else [(a.name, dict(r=a.r, g=a.g, b=a.b, sat=a.sat,
                                                                gamma=a.gamma, lift=a.lift, bright=a.bright))]
    paths = [write(a.out, n, p) for n, p in items]
    if a.install:
        dst = os.path.expanduser("~/Library/ColorSync/Profiles")
        os.makedirs(dst, exist_ok=True)
        for p in paths:
            with open(p, "rb") as s, open(os.path.join(dst, os.path.basename(p)), "wb") as d:
                d.write(s.read())
    for p in paths:
        print(p)


if __name__ == "__main__":
    sys.exit(main())
