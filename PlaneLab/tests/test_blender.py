"""The Blender extension, run headless in the real Blender (SPEC.md §11). Skipped when Blender isn't installed."""

import os
import subprocess
import zipfile
from pathlib import Path

import pytest
from conftest import FIXTURE_BUNDLE

from planelab.synth import SynthParams, write_synthetic

PLANELAB = Path(__file__).resolve().parents[1]
BLENDER = Path(os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender"))

pytestmark = pytest.mark.skipif(not BLENDER.exists(), reason=f"Blender not found at {BLENDER}")


def blender(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(BLENDER), *args], capture_output=True, text=True, timeout=600, env=env, check=False)


def test_import_smoke(tmp_path: Path) -> None:
    env = {**os.environ, "PLANELAB_LOG_DIR": str(tmp_path)}
    result = blender(
        "--background",
        "--factory-startup",
        "--python-exit-code",
        "1",
        "--python",
        str(PLANELAB / "tests" / "blender" / "smoke_import.py"),
        "--",
        str(FIXTURE_BUNDLE),
        env=env,
    )
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
    assert "SMOKE OK" in result.stdout


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
