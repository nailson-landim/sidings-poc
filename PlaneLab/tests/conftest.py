"""Shared test fixtures. The contract fixture is written by the Swift recorder (session-format/README.md)."""

import json
import shutil
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / "session-format" / "fixtures" / "v2"
FIXTURE_BUNDLE = FIXTURES / "tiny.planelab"
EXPECTED_FILE = FIXTURES / "expected.json"
SCHEMA_FILE = REPO_ROOT / "session-format" / "schema_v2.sql"
V1_FIXTURES = REPO_ROOT / "session-format" / "fixtures" / "v1"
"""The version 1 fixture, kept to prove recordings made before L12 stay readable."""


@pytest.fixture(autouse=True)
def _log_to_tmp(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep test runs out of ~/PlaneLab/logs."""
    monkeypatch.setenv("PLANELAB_LOG_DIR", str(tmp_path / "logs"))


@pytest.fixture(scope="session")
def expected() -> dict[str, Any]:
    return json.loads(EXPECTED_FILE.read_text())


@pytest.fixture
def bundle_copy(tmp_path: Path) -> Path:
    """A writable copy of the fixture bundle."""
    target = tmp_path / "copy.planelab"
    shutil.copytree(FIXTURE_BUNDLE, target)
    return target
