"""P1.1 stage runner: runs, skips when unchanged, re-runs on input/job.yaml change, --force. Run: python3 tests/test_stages.py"""
from pathlib import Path
import sys, tempfile, shutil, json, time
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from arc_talk_edit import stages, job as J

CALLS = []
TMP = Path(tempfile.mkdtemp())
INP = TMP / "in.txt"; INP.write_text("a")


@stages.stage("unit", inputs=lambda job: [INP])
def _unit(job, work):
    CALLS.append(1); return {"n": len(CALLS)}


def _job():
    y = TMP / "job.yaml"
    if not y.exists():
        y.write_text("arc: UNITTEST\ndate: 2026-09-30\nclocks: {ref: 0}\n")
    return J.load(y)


def test_runner():
    old_order = stages.ORDER
    stages.ORDER = ["unit"]
    try:
        w = stages.workdir(_job()); shutil.rmtree(w, ignore_errors=True)
        assert stages.run(_job(), "unit") == {"unit": "ran"}
        assert stages.run(_job(), "unit") == {"unit": "skipped"}
        time.sleep(1.1); INP.write_text("bb")                       # input changed (size + mtime)
        assert stages.run(_job(), "unit") == {"unit": "ran"}
        (TMP / "job.yaml").write_text("arc: UNITTEST\ndate: 2026-09-30\nclocks: {ref: 0}\n# edit\n")
        assert stages.run(_job(), "unit") == {"unit": "ran"}
        assert stages.run(_job(), "unit", force=True) == {"unit": "ran"}
        assert len(CALLS) == 4
        assert json.loads((w / "unit.json").read_text())["_provenance"]["code_md5"]
        shutil.rmtree(w, ignore_errors=True)
    finally:
        stages.ORDER = old_order


if __name__ == "__main__":
    test_runner(); print("ok test_runner")
