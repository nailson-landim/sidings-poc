"""``planelab info`` (SPEC.md §5.5)."""

import json
import logging
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import FIXTURE_BUNDLE, REPO_ROOT

from planelab.cli import main
from planelab.log import LOGGER_NAME, setup_logging


def test_info_describes_the_fixture(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["info", str(FIXTURE_BUNDLE)]) == 0
    out = capsys.readouterr().out
    assert "tiny.planelab  (iPhone14,5" in out
    assert "10 in 0.28 s, 32.0 fps delivered; 7 with an image, 0 dropped" in out
    assert "70 % normal" in out
    assert "(36 points)" in out
    assert "2 ARKit planes: 2 add, 1 update, 1 remove" in out
    assert "-12.976562, -38.476562 (± 4.5 m)" in out


def test_info_json(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["info", "--json", str(FIXTURE_BUNDLE)]) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["frames"] == 10
    assert info["frames_with_image"] == 7
    assert info["points"]["count"] == 36
    assert info["site"]["lat"] == -12.9765625


def test_info_without_points_location_or_counters(bundle_copy: Path, capsys: pytest.CaptureFixture[str]) -> None:
    with sqlite3.connect(bundle_copy / "session.sqlite") as db:
        db.execute("UPDATE frame SET points = X'', point_ids = X'', point_count = 0")
        db.execute("DELETE FROM location")
        db.execute("DELETE FROM meta WHERE key = 'frames_dropped'")
    assert main(["info", str(bundle_copy)]) == 0
    out = capsys.readouterr().out
    assert "points    none" in out
    assert "site      no location" in out
    assert "? dropped" in out


def test_bad_path_exits_2(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["info", str(tmp_path / "nope")]) == 2
    assert "neither a .planelab folder" in capsys.readouterr().err


def test_python_dash_m_entry_point() -> None:
    result = subprocess.run(
        [sys.executable, "-m", "planelab", "info", str(FIXTURE_BUNDLE)],
        capture_output=True,
        text=True,
        check=False,
        cwd=REPO_ROOT / "PlaneLab",
        env={"PYTHONPATH": str(REPO_ROOT / "PlaneLab" / "src"), "PLANELAB_LOG_DIR": "/tmp/planelab-test-logs"},
    )
    assert result.returncode == 0, result.stderr
    assert "tiny.planelab" in result.stdout


def test_logging_writes_a_file_silently(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    logger = logging.getLogger(LOGGER_NAME)
    saved = logger.handlers[:]
    logger.handlers.clear()
    monkeypatch.setenv("PLANELAB_LOG_DIR", str(tmp_path / "logs"))
    try:
        setup_logging(console=True)
        setup_logging(console=True)  # idempotent: no duplicate handlers
        assert len(logger.handlers) == 2
        logger.info("hello from the test")
        for handler in logger.handlers:
            handler.flush()
        assert "hello from the test" in (tmp_path / "logs" / "planelab.log").read_text()
    finally:
        for handler in logger.handlers:
            handler.close()
        logger.handlers[:] = saved


def test_unwritable_log_directory_is_not_fatal(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    blocker = tmp_path / "file"
    blocker.write_text("not a directory")
    logger = logging.getLogger(LOGGER_NAME)
    saved = logger.handlers[:]
    logger.handlers.clear()
    monkeypatch.setenv("PLANELAB_LOG_DIR", str(blocker / "logs"))
    try:
        setup_logging()
        assert logger.handlers == []
    finally:
        logger.handlers[:] = saved
