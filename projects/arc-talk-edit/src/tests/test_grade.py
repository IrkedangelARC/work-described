"""grade + power_window pure functions on synthetic frames (no drives, no OpenCV needed). Run: python3 tests/test_grade.py"""
from pathlib import Path
import sys, tempfile
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from arc_talk_edit import grade as G, power_window as P


def test_finish_wb_neutralises_patch():
    img = np.full((200, 300, 3), 0.3)
    noise = 1 + np.random.default_rng(1).normal(0, 0.01, (100, 100, 1))                # sensor noise (a flat patch has no top 60 %)
    img[50:150, 100:200] = np.array([0.62, 0.55, 0.47]) * noise                        # warm-cast grey card
    wb = G.neutral_wb(img, (100, 50, 200, 150))
    assert abs(wb[0] / wb[1] - 0.62 / 0.55) < 1e-3 and abs(wb[2] / wb[1] - 0.47 / 0.55) < 1e-3
    out = G.apply(G.finish_lut(wb, black=0.05), np.array([[wb]]))[0, 0]
    lab = G.rgb2lab(out)
    assert abs(lab[1]) < 1.0 and abs(lab[2]) < 1.0, lab                              # card comes out neutral


def test_finish_neutrals_stay_neutral_and_black():
    lut = G.finish_lut((1.0, 1.0, 1.0), black=0.08)
    ramp = np.linspace(0, 1, 21)[:, None].repeat(3, 1)[None]
    out = G.apply(lut, ramp)[0]
    lab = G.rgb2lab(out)
    assert np.hypot(lab[:, 1], lab[:, 2]).max() < 1.0                                 # greys stay grey (< 1 dE chroma)
    blk = G.apply(lut, np.array([[[0.08, 0.08, 0.08]]]))[0, 0, 0]
    assert blk < 0.03, blk          # measured black -> 0.025 before the S, ~0.006 after it: deep, clean black
    assert np.all(np.diff(out[:, 1]) >= -1e-6)                                         # monotonic


def test_backlight_exposure_only_when_needed():
    _, s_dark = G.backlight_lut(black=0.03, median=0.20)
    _, s_ok = G.backlight_lut(black=0.03, median=0.45)
    assert 0.9 < s_dark <= 1.5 and s_ok == 0.0


def test_window_lifts_face_not_bright_background():
    g1 = np.full((400, 400, 3), 0.80)                                                 # bright print / window wall
    g1[150:230, 170:230] = 0.25                                                       # dark face inside the ellipse
    box = (170, 150, 60, 80)
    sk = float(np.median(G.luma(G.core(g1, box))))
    g2 = G.apply_windows(g1, [box], [G.lift_for(sk)], [sk])
    assert g2[190, 200, 1] > g1[190, 200, 1] + 0.08                                   # face lifted
    assert abs(g2[140, 200, 1] - 0.80) < 0.01                                         # bright background right above: no halo


def test_tracks_link_and_smooth():
    samples = []
    for k in range(10):                                                               # two people, one moving; one flicker
        boxes = [(400 + 10 * k, 300, 80, 100), (1200, 320, 70, 90)]
        if k == 4:
            boxes.append((900, 700, 60, 70))
        samples.append((30 * k, boxes))
    trk = P.link(samples)
    assert len(trk) == 2
    path = P.per_frame(trk[0], 300)
    assert path.shape == (300, 4) and abs(path[150, 0] - 450) < 6                     # glides between samples


def test_cube_roundtrip():
    lut = G.finish_lut((0.9, 1.0, 1.1), black=0.05, n=9)
    p = Path(tempfile.mkdtemp()) / "t.cube"; G.write_cube(p, lut, "t")
    assert np.allclose(G.read_cube(p), lut, atol=1e-6)


if __name__ == "__main__":
    for f in (test_finish_wb_neutralises_patch, test_finish_neutrals_stay_neutral_and_black, test_backlight_exposure_only_when_needed,
              test_window_lifts_face_not_bright_background, test_tracks_link_and_smooth, test_cube_roundtrip):
        f(); print("ok", f.__name__)
