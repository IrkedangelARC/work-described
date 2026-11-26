"""Stage runner (P1.1). Each stage writes work/<ARC>/<stage>.json with provenance and is skipped when its inputs and the
job.yaml are unchanged. Stages read media only; `stack` (P1.7) is the only one that may touch Resolve, and only by
creating a new timeline.

Profiles: `run all` = the talk chain (ORDER); `run classroom` = the classroom-capture chain (PROFILES). A stage may
declare `config=` (the part of the job it depends on: only that is hashed, so editing an unrelated job.yaml key does not
re-run a 15 min scan) and `code=` (extra modules whose source also invalidates it)."""
from __future__ import annotations
import hashlib, json, time
from pathlib import Path
from . import __version__

ORDER = ["ingest", "sync", "transcribe", "scans", "audio", "stack"]
PROFILES = {"classroom": ["ingest", "sync", "transcribe", "classroom_track", "classroom_people", "classroom_pose", "classroom_slides", "classroom_plan",
                          "classroom_column", "audio_repair"]}
REGISTRY: dict[str, tuple] = {}          # name -> (fn(job, work) -> dict, inputs(job) -> list[Path], config, code)


def stage(name: str, inputs=None, config=None, code=()):
    """config(job) -> JSON-able: hashed instead of the whole job.yaml. code: modules hashed with the stage's own file."""
    def deco(fn):
        REGISTRY[name] = (fn, inputs or (lambda job: []), config, tuple(code))
        return fn
    return deco


def _stat(p: Path) -> dict:
    try:
        st = p.stat(); return {"path": str(p), "size": st.st_size, "mtime": int(st.st_mtime)}
    except FileNotFoundError:
        return {"path": str(p), "missing": True}


def provenance(job, name: str) -> dict:
    import inspect
    fn, inputs, config, extra = REGISTRY[name]
    yml = Path(job.raw["__path__"])
    # a code change re-runs the stage: its whole file, or (config= stages, which name their modules in code=) only the
    # stage function itself, so editing a neighbour stage in the same file does not re-run a 19 min pose pass
    code = Path(inspect.getsourcefile(fn)).read_bytes() if config is None else inspect.getsource(fn).encode()
    for m in extra:
        code += Path(inspect.getsourcefile(m)).read_bytes()
    cfg = yml.read_bytes() if config is None else json.dumps(config(job), sort_keys=True, default=str).encode()
    return {"stage": name, "tool_version": __version__, "code_md5": hashlib.md5(code).hexdigest(),
            "job_yaml_md5": hashlib.md5(cfg).hexdigest(),
            "inputs": [_stat(Path(p)) for p in inputs(job)]}


def workdir(job) -> Path:
    w = Path(__file__).resolve().parents[1] / "work" / job.arc
    w.mkdir(parents=True, exist_ok=True)
    return w


def run(job, which: str = "all", start: str | None = None, force: bool = False) -> dict:
    from . import ingest, sync, transcribe, scan_stage, audio_stage, stack  # noqa: F401  (registers stages)
    if which in PROFILES or which.startswith("classroom") or which == "audio_repair":
        from . import audio_repair  # noqa: F401
        from .classroom import pipeline  # noqa: F401
    chain = ORDER if which == "all" else PROFILES.get(which)
    names = chain or [which]
    if start:
        chain = chain or next((c for c in [ORDER, *PROFILES.values()] if start in c), ORDER)
        names = chain[chain.index(start):]
    work = workdir(job); done = {}
    cascade = False
    for n in names:
        if n not in REGISTRY:
            print(f"[{n}] not implemented yet, stopping"); break
        fn = REGISTRY[n][0]
        out = work / f"{n}.json"; prov = provenance(job, n)
        # a stage that declares config= lists what it depends on (its inputs include upstream work files), so an
        # upstream run only re-runs it when those actually changed; the others keep the re-run-after-upstream rule
        if not (force or (cascade and REGISTRY[n][2] is None)) and out.exists():
            old = json.loads(out.read_text()).get("_provenance")
            if old and {k: v for k, v in old.items() if k not in ("started", "seconds")} == prov:
                print(f"[{n}] unchanged, skipped"); done[n] = "skipped"; continue
        t0 = time.time(); print(f"[{n}] running")
        res = fn(job, work)
        res["_provenance"] = {**prov, "started": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t0)),
                              "seconds": round(time.time() - t0, 1)}
        out.write_text(json.dumps(res, indent=1, default=str))
        print(f"[{n}] done in {res['_provenance']['seconds']} s -> {out}"); done[n] = "ran"
        cascade = True                    # downstream stages re-run after an upstream run
    return done
