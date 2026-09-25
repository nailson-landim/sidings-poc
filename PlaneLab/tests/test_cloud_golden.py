"""The committed cloud golden (session-format/fixtures/cloud/golden.json) is what the Python accumulator gives today.

The Swift port (PlaneKit FeatureAccumulator, SPEC.md §18 T27) is checked against the same file, so both sides agree.
Rewrite it with ``python scripts/cloud_golden.py`` after a deliberate change to the accumulator.
"""

import importlib.util
import json
from pathlib import Path
from types import ModuleType

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "cloud_golden.py"


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location("cloud_golden", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_committed_golden_matches_the_accumulator() -> None:
    script = load_script()
    assert script.GOLDEN.read_text() == script.render(), "run: python scripts/cloud_golden.py"


def test_every_case_has_points_to_compare() -> None:
    golden = json.loads(load_script().GOLDEN.read_text())
    for case in golden["cases"]:
        assert case["checkpoints"][-1]["ids"], case["name"]
    wrapped = next(c for c in golden["cases"] if c["name"] == "evict_and_wrap")
    assert max(wrapped["checkpoints"][-1]["samples"]) == wrapped["accumulate"]["max_samples"]
