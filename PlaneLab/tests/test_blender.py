"""The Blender extension, run headless in the real Blender (SPEC.md §11). Skipped when Blender isn't installed."""

import os
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest
from conftest import FIXTURE_BUNDLE, RECORDED_BUNDLE

from planelab.synth import SynthParams, write_synthetic

PLANELAB = Path(__file__).resolve().parents[1]
BLENDER = Path(os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender"))

pytestmark = pytest.mark.skipif(not BLENDER.exists(), reason=f"Blender not found at {BLENDER}")


def blender(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(BLENDER), *args], capture_output=True, text=True, timeout=600, env=env, check=False)


def test_import_smoke(bundle_copy: Path, tmp_path: Path) -> None:
    """On a copy: the import caches the averaged cloud in ``<bundle>/lab/``, which must not land in the fixture."""
    env = {**os.environ, "PLANELAB_LOG_DIR": str(tmp_path)}
    result = blender(
        "--background",
        "--factory-startup",
        "--python-exit-code",
        "1",
        "--python",
        str(PLANELAB / "tests" / "blender" / "smoke_import.py"),
        "--",
        str(bundle_copy),
        env=env,
    )
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
    assert "SMOKE OK" in result.stdout
    # The contract fixture's X1 tracks (schema v3): none, then #1, #1 and #2, ..., #1 stale and #3, #1 after the drop.
    assert "X1 OK (3 tracks, per frame [0, 0, 0, 1, 2, 2, 2, 1, 2, 1])" in result.stdout
    # Schema v4's round rows (12.5, 1.5 and 4.75 ms) as keyed properties on the round-stats empty.
    assert "ROUNDS OK (3 rounds, ms [12.5, 1.5, 4.75])" in result.stdout
    assert not (FIXTURE_BUNDLE / "lab").exists()


def test_extension_builds_and_installs(tmp_path: Path) -> None:
    """The zip carries the real core (not the dev symlink) and installs into a throwaway Blender profile."""
    dist = tmp_path / "dist"
    env = {**os.environ, "BLENDER": str(BLENDER)}
    build = subprocess.run(
        ["bash", str(PLANELAB / "scripts" / "build_extension.sh"), str(dist)],
        capture_output=True,
        text=True,
        timeout=600,
        env=env,
        check=False,
    )
    assert build.returncode == 0, build.stdout + build.stderr
    (package,) = dist.glob("planelab_blender-*.zip")
    names = zipfile.ZipFile(package).namelist()
    assert "vendor/planelab/session.py" in names
    assert "blender_manifest.toml" in names
    assert not any("__pycache__" in n for n in names)

    profile = {**os.environ, "BLENDER_USER_RESOURCES": str(tmp_path / "profile"), "PLANELAB_LOG_DIR": str(tmp_path)}
    install = blender("--command", "extension", "install-file", "-r", "user_default", "-e", str(package), env=profile)
    assert install.returncode == 0, install.stdout + install.stderr
    probe = blender(
        "--background",
        "--python-exit-code",
        "1",
        "--python-expr",
        "import bpy; assert hasattr(bpy.ops.planelab, 'import_session'); print('INSTALLED OK')",
        env=profile,
    )
    assert "INSTALLED OK" in probe.stdout, probe.stdout[-3000:] + probe.stderr[-3000:]


def test_import_smoke_on_a_synthetic_session(tmp_path: Path) -> None:
    """Synthetic sessions (T14) have no video; the import still builds camera, trail and points."""
    bundle = tmp_path / "edges.planelab"
    write_synthetic(bundle, SynthParams(scene="edges", seconds=1, fps=10))
    env = {**os.environ, "PLANELAB_LOG_DIR": str(tmp_path)}
    result = blender(
        "--background",
        "--factory-startup",
        "--python-exit-code",
        "1",
        "--python",
        str(PLANELAB / "tests" / "blender" / "smoke_import.py"),
        "--",
        str(bundle),
        env=env,
    )
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
    assert "VIDEO OK (none)" in result.stdout and "SMOKE OK" in result.stdout
    final = re.search(r"CLOUD OK \(mac, final (\d+) points, bands", result.stdout)
    assert final is not None and int(final.group(1)) > 0, "the synthetic session must build a real cloud"


def test_import_smoke_shows_the_phones_recorded_cloud(tmp_path: Path) -> None:
    """A recording with cloud rows (written by the Swift recorder, SPEC T30) shows the phone's cloud."""
    bundle = tmp_path / "recorded.planelab"
    shutil.copytree(RECORDED_BUNDLE, bundle)
    env = {**os.environ, "PLANELAB_LOG_DIR": str(tmp_path)}
    result = blender(
        "--background",
        "--factory-startup",
        "--python-exit-code",
        "1",
        "--python",
        str(PLANELAB / "tests" / "blender" / "smoke_import.py"),
        "--",
        str(bundle),
        env=env,
    )
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
    assert "CLOUD OK (phone, final 18 points, bands" in result.stdout and "SMOKE OK" in result.stdout
    assert not (bundle / "lab").exists() or not list((bundle / "lab").glob("cloud-*.npz"))


def test_reload_scripts_loads_the_current_code(bundle_copy: Path, tmp_path: Path) -> None:
    """F3 reloads the submodules and the core, and a recording the reader refuses is logged, not silent."""
    env = {**os.environ, "PLANELAB_LOG_DIR": str(tmp_path)}
    result = blender(
        "--background",
        "--factory-startup",
        "--python-exit-code",
        "1",
        "--python",
        str(PLANELAB / "tests" / "blender" / "reload_check.py"),
        "--",
        str(bundle_copy),
        env=env,
    )
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
    assert "RELOAD OK" in result.stdout and "ERROR LISTED OK" in result.stdout
    log = (tmp_path / "planelab.log").read_text()
    assert "layer source unavailable" in log and "'99' is not supported" in log
