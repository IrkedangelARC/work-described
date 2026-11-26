"""Time maps pinned to numbers measured on JOB-0000 (2026-09-30). Run: python3 -m pytest tests  (or python3 tests/test_job.py)"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from arc_talk_edit import job as J

JOB = J.load(Path(__file__).resolve().parents[1] / "jobs" / "job_a.yaml")


def test_df_known_frames():
    # parked playheads read back from Resolve on V1.2 DELIVERABLE
    assert J.frame_to_df(9131) == "00:02:32;19"
    assert J.frame_to_df(14785) == "00:04:06;41"
    assert J.frame_to_df(179911) == "00:50:01;31"
    assert J.df_to_frame("00:02:48;02") == 10074
    for n in (0, 3595, 3596, 3600, 35963, 35964, 179911, 246824):
        assert J.df_to_frame(J.frame_to_df(n)) == n


def test_aja_rec():
    assert JOB.aja_rec == 14994                      # tools/overwrite_v2.py AJA_REC


def test_media_frames():
    # V1.2 first-cut head: A2 ISO item left 59042 at record 9003 -> Sumo frame 59170 at record 9131 = AJA 737.0 s
    t = JOB.convert(59170 / JOB.f, "sumo", "aja")
    assert abs(t - 737.006) < 0.01
    # AJA1/AJA2 synced left offset at record 9003 (verified by the multiview, 9/30) = 44048
    assert JOB.media_frame("AJA2", 59042 / JOB.f, clock="sumo") == 44048
    assert JOB.media_frame("ISO3", 831.33) == round((831.33 + 250.147) * JOB.f)
    # the legacy AJA_REC identity: Sumo frame - AJA frame
    assert JOB.media_frame("ISO1", 800.0) - JOB.media_frame("AJA1", 800.0) in (JOB.aja_rec, JOB.aja_rec + 1)


def test_program_map():
    assert JOB.program_to(0) == 578.7
    # first cut T1 (731.66 -> 737.64): program second just after it lands after 737.64
    pre = 731.66 - 578.7
    assert abs(JOB.program_to(pre + 1) - 738.64) < 1e-9
    assert abs(JOB.program_to(0, "sumo") - (578.7 + 250.147)) < 1e-9


JOB_B = J.load(Path(__file__).resolve().parents[1] / "jobs" / "job_b.yaml")


def test_second_job():
    assert JOB_B.aja_rec == 51741                    # legacy tools: AJA_REC, AJA_LEN = 51741, 312924
    assert JOB_B.program_clock == "sumo" and JOB_B.program_to(0) == 777.6
    assert abs(JOB_B.program_to(0, "aja") - (777.6 - 863.218)) < 1e-9   # host intro predates the AJA (AJA covers Sumo 14:23 on)
    assert abs(JOB_B.convert(0, "aja", "sumo") - 863.218) < 1e-9          # PLAN: AJA covers ATEM 14:23.218 ->
    assert abs(JOB_B.convert(100, "cam4k", "tr") - (100 + 54.2273 - 8.772)) < 1e-9
    # CUTLIST: 162.7 s removed; program 777.6 -> 6048.1 minus cuts = edl_v1.json's last piece rec_out
    import json
    E = json.load(open(Path(JOB_B.root) / "docs" / "edl_v1.json"))
    kept = sum(b - a for a, b in JOB_B.keeps())
    assert abs(kept - E["pieces"][-1]["rec_out"]) < 0.01, (kept, E["pieces"][-1]["rec_out"])


def test_job_sections():
    """Every stage's section is a TOP-LEVEL key (a botched insert once hid `scans:` under `stack:` and the scans stage
    silently skipped dropouts + screen map)."""
    import yaml
    STAGE_KEYS = {"stack": {"tracks", "program_audio", "paths", "names", "timeline"}, "scans": {"dropouts", "screen", "pauses", "cameras", "face_step_s"},
                  "v1": {"keymap", "takes", "colour", "take_windows", "joins"}, "sync": {"ref", "pairs"}, "audio": {"mix", "sections", "program_iso", "program_house", "ceiling", "sq_channels", "program", "sq_multitrack"}}
    for f in (Path(__file__).resolve().parents[1] / "jobs").glob("*.yaml"):
        d = yaml.safe_load(f.read_text())
        for k, allowed in STAGE_KEYS.items():
            if k in d and isinstance(d[k], dict):
                stray = set(d[k]) - allowed
                assert not stray, f"{f.name}: {k} has keys that belong elsewhere: {stray}"


if __name__ == "__main__":
    for k, f in list(globals().items()):
        if k.startswith("test_"): f(); print("ok", k)
