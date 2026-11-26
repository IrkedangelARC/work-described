"""job.yaml loader + the time maps every stage shares.

Replaces the per-script copies found in two earlier jobs' tools: inline FPS, OFF (Sumo - AJA; the tools say ATEM), AJA_REC,
SQ offsets, the 59.94 drop-frame df() helpers and the program keep-list rec() maps.

Clocks (JOB-0000 naming, generalised):
  aja   seconds in the AJA recorder files (= the transcript clock)
  sumo  seconds in the Atomos Shogun Sumo ISO files: the reference clock (JOB-0000 docs call it "ATEM")
  aja   AJA recorder files (= the JOB-0000 transcript clock)      sumo = aja + clocks.aja
  sq    SQ multitrack; tr = field audio recorder; cam4k = a camera's own card, ...  sumo = t + clocks.<name>
  frame timeline frames at fps (59.94): media frame = round(t on the source's own clock * fps)
"""
from __future__ import annotations
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path
import yaml


@dataclass
class Source:
    key: str
    path: str
    clock: str                      # "sumo" | "aja" | "sq" | "own"
    role: str = ""
    lut: str | None = None
    rotation: float = 0.0           # measured roll correction (deg, Resolve sign)
    level_zoom: float = 1.045       # zoom that covers the corners after `rotation` (JOB-0000 AJA2 9/30; 1.040 = exact cover)
    notes: str = ""

    def level(self) -> dict:
        """Timeline-item transform that levels this source (empty when it isn't rolled)."""
        return level_props(self.rotation, self.level_zoom)


def level_props(rotation: float, zoom: float = 1.045) -> dict:
    return {"RotationAngle": float(rotation), "ZoomX": zoom, "ZoomY": zoom} if rotation else {}


@dataclass
class Job:
    root: Path
    arc: str
    title: str
    fps: Fraction
    offsets: dict
    sources: dict[str, Source]
    program: dict = field(default_factory=dict)
    delivery: dict = field(default_factory=dict)
    raw: dict = field(default_factory=dict)

    def path(self, key: str) -> Path:
        """Absolute media path of a source: absolute as written, SQ multitrack under sq_root, else under media_root."""
        p = Path(self.sources[key].path).expanduser()
        if p.is_absolute():
            return p
        if self.sources[key].clock == "sq" and self.raw.get("sq_root"):
            return Path(self.raw["sq_root"]).expanduser() / p
        return Path(self.raw.get("media_root", "")).expanduser() / p

    # ---- clocks: every clock is an offset from the reference (the Sumo ISO record deck) -------------------------
    # job.yaml `clocks: {sumo: 0, aja: 250.147, sq: 243.63035}` means  sumo_t = clock_t + offset
    @property
    def f(self) -> float:
        return float(self.fps)

    @property
    def ref(self) -> str:
        return next(k for k, v in self.offsets.items() if v == 0)

    def to_ref(self, t: float, clock: str) -> float:
        return t + self.offsets[clock]

    def convert(self, t: float, src: str, dst: str) -> float:
        return t + self.offsets[src] - self.offsets[dst]

    @property
    def aja_rec(self) -> int:
        """Sumo ISO media frame - AJA media frame (JOB-0000: 14994 = round(250.147 * 59.94))."""
        return round(self.offsets["aja"] * self.f)

    def media_frame(self, source: str, t: float, clock: str = "aja") -> int:
        """Media-relative frame (timeline fps) of a source at time t on `clock`, as Resolve's startFrame/LeftOffset.
        Media starts at its own clock's zero, so the frame is just t converted to the source's clock."""
        return round(self.convert(t, clock, self.sources[source].clock) * self.f)

    # ---- program keep-list (cuts in AJA seconds) ----------------------------------------------------------------
    @property
    def program_clock(self) -> str:
        return self.program.get("clock", "aja" if "aja" in self.offsets else self.ref)   # Pearl-only jobs have no aja clock

    def keeps(self) -> list[tuple[float, float]]:
        """Kept spans in the program clock."""
        p = self.program
        cuts = sorted((c["in"], c["out"]) for c in p.get("cuts", []))
        out, t = [], p["in"]
        for a, b in cuts:
            out.append((t, a)); t = b
        out.append((t, p["out"]))
        return out

    def program_to(self, prog_s: float, clock: str | None = None) -> float | None:
        """Program second -> time on `clock` (default: the program's own clock)."""
        for a, b in self.keeps():
            if prog_s <= b - a:
                t = a + prog_s
                return t if clock is None else self.convert(t, self.program_clock, clock)
            prog_s -= b - a
        return None


# ---- 59.94 / 29.97 drop-frame timecode (verified on JOB-0000 V1.2 DELIVERABLE, 9/30) --------------------------------
def frame_to_df(n: int, fps: int = 60) -> str:
    drop = 2 * fps // 30                                   # 4 at 59.94, 2 at 29.97
    per_min = fps * 60 - drop
    per_10 = per_min * 10 + drop
    q, r = divmod(n, per_10)
    n += drop * 9 * q + (drop * ((r - drop) // per_min) if r > drop else 0)
    return f"{n // (fps * 3600):02d}:{n // (fps * 60) % 60:02d}:{n // fps % 60:02d};{n % fps:02d}"


def df_to_frame(tc: str, fps: int = 60) -> int:
    drop = 2 * fps // 30
    h, m, rest = tc.split(":")
    s, ff = rest.replace(";", ":").split(":")
    h, m, s, ff = int(h), int(m), int(s), int(ff)
    total_min = h * 60 + m
    return ((total_min * 60 + s) * fps + ff) - drop * (total_min - total_min // 10)


def load(path: str | Path) -> Job:
    path = Path(path)
    d = yaml.safe_load(path.read_text())
    d["__path__"] = str(path.resolve())
    fps = Fraction(d.get("fps", "60000/1001"))
    sources = {k: Source(key=k, **v) for k, v in (d.get("sources") or {}).items()}
    return Job(root=Path(d.get("root", path.parent)).expanduser(), arc=d["arc"], title=d.get("title", ""), fps=fps,
               offsets=d.get("clocks", {}), sources=sources, program=d.get("program", {}),
               delivery=d.get("delivery", {}), raw=d)
