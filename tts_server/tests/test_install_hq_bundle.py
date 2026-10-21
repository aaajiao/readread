"""install-hq.sh as the app bundle holds it: the files build-app.sh copies into Contents/Resources/installer, laid
out under a temporary X.app, run in a clean environment. common.sh's guard refuses to run from inside an app bundle
without READREAD_BUILD_CACHE (the default build cache would be in the signed bundle), also through a symlink or
another spelling of the path; with it the script runs from there and writes nothing into the bundle. Also the
--model arguments kept for older command lines, and what an install or uninstall that stops (or is asked to stop)
leaves behind: install.json set aside as install.json.prev, an uninstall that finishes once its removal runs, and
the refusal of files the script did not create inside its own folders. None of them reaches the network (a fake
curl stands in) or runs Python."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from conftest import SERVER_DIR

REPO = SERVER_DIR.parent
INSTALLER_FILES = ["scripts/install-hq.sh", "scripts/lib/common.sh", "scripts/lib/versions.sh",
                   "tts_server/requirements-hq.in", "tts_server/requirements-hq.lock"]
GUARD_MESSAGE = "is inside an app bundle: set READREAD_BUILD_CACHE"


def test_build_app_and_the_smoke_test_name_the_same_installer_files():
    build = (REPO / "scripts" / "build-app.sh").read_text(encoding="utf-8")
    listed = re.search(r'^INSTALLER_FILES="([^"]*)"', build, re.M)
    assert listed and listed.group(1).split() == INSTALLER_FILES
    smoke = (REPO / "scripts" / "smoke-test.sh").read_text(encoding="utf-8")
    listed = re.search(r'^HQ_FILES="([^"]*)"', smoke, re.M)
    assert listed and sorted(listed.group(1).split()) == sorted(INSTALLER_FILES)


@pytest.fixture
def bundle(tmp_path):
    """<tmp>/X.app/Contents/Resources/installer with the installer files, as build-app.sh lays them out."""
    root = tmp_path / "X.app" / "Contents" / "Resources" / "installer"
    for name in INSTALLER_FILES:
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / name, root / name)
    return root


def snapshot(root) -> list[tuple[str, int, int]]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        for name in sorted(dirnames + filenames):
            path = os.path.join(dirpath, name)
            info = os.lstat(path)
            out.append((os.path.relpath(path, root), info.st_size, info.st_mtime_ns))
    return sorted(out)


def run(script, tmp_path, *args, cache: bool = True, hq_home=None, first_on_path=None, env_extra=None):
    """bash <script> <args> in a clean environment like the app's (HOME, PATH, LANG, TMPDIR, READREAD_HQ_HOME);
    `first_on_path`: a directory of stand-in commands searched first."""
    home = tmp_path / "home"
    temporary = tmp_path / "tmp"
    home.mkdir(exist_ok=True)
    temporary.mkdir(exist_ok=True)
    path = "/usr/bin:/bin:/usr/sbin:/sbin"
    env = {"HOME": str(home), "PATH": f"{first_on_path}:{path}" if first_on_path else path, "LANG": "en_US.UTF-8",
           "TMPDIR": str(temporary), "READREAD_HQ_HOME": str(hq_home or tmp_path / "hq"), **(env_extra or {})}
    if cache:
        env["READREAD_BUILD_CACHE"] = str(tmp_path / "build-cache")
    return subprocess.run(["/bin/bash", str(script), *args], env=env, capture_output=True, text=True, timeout=60,
                          stdin=subprocess.DEVNULL)


def stand_ins(tmp_path, **scripts: str) -> Path:
    """<tmp>/bin with an executable /bin/sh script per name (curl="exit 7": no network)."""
    directory = tmp_path / "bin"
    directory.mkdir(exist_ok=True)
    for name, body in scripts.items():
        (directory / name).write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        (directory / name).chmod(0o755)
    return directory


def last_event(out) -> dict:
    return json.loads(out.stdout.splitlines()[-1])


def test_the_guard_refuses_a_bundle_without_a_build_cache(bundle, tmp_path):
    before = snapshot(bundle)
    for args in (["--help"], ["--check", "--json-progress"], ["--json-progress"], ["--uninstall"]):
        out = run(bundle / "scripts" / "install-hq.sh", tmp_path, *args, cache=False)
        assert out.returncode == 1, (args, out.stderr)
        assert GUARD_MESSAGE in out.stderr, args
        assert str(bundle) in out.stderr  # it names where it runs from
        assert out.stdout == "", "nothing reaches the JSON stream: the guard runs before it is set up"
    assert snapshot(bundle) == before
    assert not (tmp_path / "hq").exists()


def test_with_a_build_cache_the_bundled_script_runs(bundle, tmp_path):
    before = snapshot(bundle)
    out = run(bundle / "scripts" / "install-hq.sh", tmp_path, "--help")
    assert out.returncode == 0, out.stderr
    assert "install-hq.sh --check" in out.stderr and out.stdout == ""

    empty = tmp_path / "empty-hq"
    empty.mkdir()
    out = run(bundle / "scripts" / "install-hq.sh", tmp_path, "--check", "--json-progress", hq_home=empty)
    assert out.returncode == 1, out.stderr
    events = [json.loads(line) for line in out.stdout.splitlines()]
    assert events and all(isinstance(e, dict) and "event" in e for e in events)
    assert [e["event"] for e in events][-1] == "error"
    assert "has problems" in events[-1]["message"] and "install.json" in events[-1]["message"]
    assert [e["index"] for e in events if e["event"] == "step"] == [1, 2, 3, 4]
    assert list(empty.iterdir()) == [], "--check writes nothing into the HQ home"
    assert snapshot(bundle) == before, "nothing written under RR_REPO_DIR (no build/cache in the bundle)"
    assert not (bundle / "build").exists()


def test_the_guard_matches_only_a_bundles_contents(tmp_path):
    # A checkout whose path merely contains ".app" is not a bundle; one under Foo.app/Contents is.
    for parts, refused in ((("work", "my.app-checkout"), False), (("Foo.app", "Contents", "Resources", "x"), True),
                           (("Foo.app", "Other"), False)):
        root = tmp_path.joinpath(*parts)
        for name in INSTALLER_FILES:
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, root / name)
        out = run(root / "scripts" / "install-hq.sh", tmp_path, "--help", cache=False)
        assert (out.returncode == 1 and GUARD_MESSAGE in out.stderr) == refused, (parts, out.returncode, out.stderr)
        if not refused:
            assert out.returncode == 0, out.stderr


def test_the_guard_sees_the_bundle_through_a_symlink_and_another_spelling(bundle, tmp_path):
    before = snapshot(bundle)
    link = tmp_path / "installer-link"
    link.symlink_to(bundle, target_is_directory=True)
    spellings = [link]
    lower = Path(str(bundle).replace("/X.app/Contents/", "/x.APP/contents/"))
    if lower.exists():  # a case-insensitive volume (the default on macOS)
        spellings.append(lower)
    for root in spellings:
        for args in (["--help"], ["--check", "--json-progress"], ["--json-progress"]):
            out = run(root / "scripts" / "install-hq.sh", tmp_path, *args, cache=False)
            assert out.returncode == 1 and GUARD_MESSAGE in out.stderr, (root, args, out.returncode, out.stderr)
            assert out.stdout == ""
    assert snapshot(bundle) == before
    assert not (bundle / "build").exists() and not (tmp_path / "hq").exists()


def fake_python(hq: Path) -> None:
    """<hq>/python as python_ok accepts it (the pinned stamp, a manifest of its one file), whose bin/python3 runs
    `-c 'import sys'` but cannot make a venv."""
    versions = (REPO / "scripts" / "lib" / "versions.sh").read_text(encoding="utf-8")
    pin = {name: re.search(rf'^{name}="([^"]*)"', versions, re.M).group(1)
           for name in ("RR_PY_VERSION", "RR_PY_RELEASE", "RR_PY_SHA256")}
    executable = hq / "python" / "bin" / "python3"
    executable.parent.mkdir(parents=True)
    executable.write_text('#!/bin/sh\ncase "$*" in *"-m venv"*) echo "no venv here" >&2; exit 1 ;; esac\n',
                          encoding="utf-8")
    executable.chmod(0o755)
    stamp = f'{pin["RR_PY_VERSION"]}+{pin["RR_PY_RELEASE"]} {pin["RR_PY_SHA256"]}\n'
    (hq / "python" / ".readread-python").write_text(stamp, encoding="utf-8")
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    (hq / "python" / ".readread-manifest").write_text(f"{digest}  ./bin/python3\n", encoding="utf-8")


def test_an_install_sets_its_record_aside_once_it_changes_the_install(tmp_path):
    # install.json says "finished". A run that stops before it changed anything (here: the Python download fails)
    # leaves it as it was. From its first change to python/, venv/ or a model file until it writes a new one, the old
    # one is install.json.prev, so a run that stops after a change (here: the venv cannot be built) leaves no record of
    # an install whose venv or model files it was replacing. The app reads that as unfinished (Repair).
    hq = tmp_path / "hq"
    (hq / "models").mkdir(parents=True)
    record = '{"version": 1, "models": {"1.7b": {"bytes": 1}}, "installed_at": "2026-10-21T03:02:19Z"}\n'
    (hq / "install.json").write_text(record, encoding="utf-8")
    fake = stand_ins(tmp_path, curl="echo 'curl: (7) no network in this test' >&2; exit 7",
                     df="echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'\n"
                        "echo '/dev/test 999999999 1 999999999 1% /'")
    script = REPO / "scripts" / "install-hq.sh"

    def install():
        out = run(script, tmp_path, "--json-progress", hq_home=hq, first_on_path=fake)
        assert out.returncode == 1, out.stderr
        assert not os.path.lexists(hq / ".lock"), "the lock is released"
        return last_event(out), [e["name"] for e in map(json.loads, out.stdout.splitlines()) if e["event"] == "step"]

    event, steps = install()
    assert event["event"] == "error" and "download failed" in event["message"], event
    assert steps == ["Standalone Python"], steps
    assert (hq / "install.json").read_text(encoding="utf-8") == record
    assert not os.path.lexists(hq / "install.json.prev")

    fake_python(hq)
    event, steps = install()
    assert event["event"] == "error" and "cannot create the venv" in event["message"], event
    assert steps == ["Standalone Python", "Virtual environment (requirements-hq.lock)"], steps
    assert not os.path.lexists(hq / "install.json")
    assert (hq / "install.json.prev").read_text(encoding="utf-8") == record

    # --check says what happened; running the install again keeps the record aside (it is not finished yet).
    out = run(script, tmp_path, "--check", "--json-progress", hq_home=hq)
    assert out.returncode == 1
    assert "an install or repair stopped before it finished: run install-hq.sh again" in last_event(out)["message"]
    event, steps = install()
    assert "cannot create the venv" in event["message"], event
    assert not os.path.lexists(hq / "install.json")
    assert (hq / "install.json.prev").read_text(encoding="utf-8") == record

    # An uninstall counts the record as the script's own.
    out = run(REPO / "scripts" / "install-hq.sh", tmp_path, "--uninstall", "--json-progress", hq_home=hq)
    assert out.returncode == 0, out.stderr
    assert last_event(out) == {"event": "done", "removed": True}
    assert not hq.exists()


@pytest.mark.parametrize("foreign", ["venv/my-notes.txt", "python/thesis.docx", "python.partial/thesis.docx",
                                     "venv/.secret"])
def test_uninstall_refuses_files_the_script_did_not_create_inside_its_own_folders(tmp_path, foreign):
    hq = tmp_path / "hq"
    (hq / "python" / "bin").mkdir(parents=True)
    (hq / "python" / ".readread-python").write_text("3.12.15+20261013 abc\n", encoding="utf-8")
    (hq / "python" / ".readread-manifest").write_text("", encoding="utf-8")
    (hq / "venv" / "bin").mkdir(parents=True)
    (hq / "venv" / "lib").mkdir()
    (hq / "venv" / "pyvenv.cfg").write_text(f"home = {hq / 'python' / 'bin'}\n", encoding="utf-8")
    (hq / "venv" / ".readread-hq-venv").write_text("stamp\n", encoding="utf-8")
    (hq / "python.partial" / "python").mkdir(parents=True)
    (hq / foreign).write_text("mine", encoding="utf-8")
    before = snapshot(hq)
    out = run(REPO / "scripts" / "install-hq.sh", tmp_path, "--uninstall", "--json-progress", hq_home=hq)
    assert out.returncode == 1, out.stderr
    message = last_event(out)["message"]
    assert f"holds files install-hq.sh did not create ({foreign}); not removing anything" in message, message
    assert snapshot(hq) == before

    (hq / foreign).unlink()
    out = run(REPO / "scripts" / "install-hq.sh", tmp_path, "--uninstall", "--json-progress", hq_home=hq)
    assert out.returncode == 0, out.stderr
    assert last_event(out) == {"event": "done", "removed": True}
    assert not hq.exists()


def test_an_uninstall_finishes_once_its_removal_runs(tmp_path):
    # The app's Cancel (SIGTERM) arriving while the tree is being removed: the removal is not resumable, so the run
    # finishes and says so. The stand-in rm signals the script (the pid its lock names), then removes for real.
    hq = tmp_path / "hq"
    (hq / "models").mkdir(parents=True)
    (hq / "install.json").write_text("{}", encoding="utf-8")
    signal_script = 'kill -TERM "$(readlink "$RR_TEST_HQ/.lock")"; sleep 0.3'
    fake = stand_ins(tmp_path, rm=f'if [ "$1" = -rf ] && [ "$2" = "$RR_TEST_HQ" ]; then {signal_script}; fi\n'
                                  'exec /bin/rm "$@"')
    out = run(REPO / "scripts" / "install-hq.sh", tmp_path, "--uninstall", "--json-progress", hq_home=hq,
              first_on_path=fake, env_extra={"RR_TEST_HQ": str(hq)})
    assert out.returncode == 0, out.stderr
    assert last_event(out) == {"event": "done", "removed": True}
    assert not hq.exists()

    # Before the removal (here while it measures the tree) a signal still stops it, with nothing removed.
    (hq / "models").mkdir(parents=True)
    fake = stand_ins(tmp_path, rm='exec /bin/rm "$@"', du=f'{signal_script}; exec /usr/bin/du "$@"')
    out = run(REPO / "scripts" / "install-hq.sh", tmp_path, "--uninstall", "--json-progress", hq_home=hq,
              first_on_path=fake, env_extra={"RR_TEST_HQ": str(hq)})
    assert out.returncode == 1, out.stderr
    assert last_event(out) == {"event": "error", "message": "interrupted by a signal (run again to resume)"}
    assert (hq / "models").is_dir() and not os.path.lexists(hq / ".lock")


def test_another_models_folder_is_refused_by_install_and_uninstall(tmp_path):
    # What an older install-hq.sh could leave: a second model's folder next to the one model. --check ignores it
    # (it verifies only 1.7b); install and uninstall refuse, saying what to do.
    hq = tmp_path / "hq"
    (hq / "models" / "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit").mkdir(parents=True)
    (hq / "models" / "Qwen3-TTS-12Hz-Older-CustomVoice-8bit").mkdir()
    (hq / "models" / "Qwen3-TTS-12Hz-Older-CustomVoice-8bit" / "model.safetensors").write_bytes(b"x")
    before = snapshot(hq)
    for args in (["--json-progress"], ["--uninstall", "--json-progress"]):
        out = run(REPO / "scripts" / "install-hq.sh", tmp_path, *args, hq_home=hq)
        assert out.returncode == 1, (args, out.stderr)
        message = json.loads(out.stdout.splitlines()[-1])["message"]
        assert "models/Qwen3-TTS-12Hz-Older-CustomVoice-8bit (a model folder this version does not use)" in message
        assert message.endswith("ReadRead uses only the 1.7b model now: delete the other model's folder (an older "
                                "version installed it), then run this again."), message
        assert snapshot(hq) == before, "nothing installed, nothing removed, the lock released"


@pytest.mark.parametrize("args, status, message", [
    (["--model", "1.7b", "--help"], 0, None),
    (["--model=1.7b", "--help"], 0, None),
    (["--model", "3b", "--help"], 2, "--model 3b: there is one model, 1.7b, and install-hq.sh always installs it"),
    (["--model=both"], 2, "--model both: there is one model, 1.7b"),
    (["--model"], 2, "--model needs a value"),
    (["--frobnicate"], 2, "unknown argument: --frobnicate"),
])
def test_the_model_argument_names_the_one_model(tmp_path, args, status, message):
    out = run(REPO / "scripts" / "install-hq.sh", tmp_path, *args)
    assert out.returncode == status, out.stderr
    if message:
        assert message in out.stderr
    json_out = run(REPO / "scripts" / "install-hq.sh", tmp_path, *args, "--json-progress")
    if status == 2:
        event = json.loads(json_out.stdout.splitlines()[-1])
        assert event["event"] == "error" and event["message"].startswith("usage: ")
