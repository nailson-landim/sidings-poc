"""LabConfig and its TOML presets (SPEC.md §18 T15)."""

from dataclasses import replace
from pathlib import Path

import pytest

from planelab.config import (
    AccumulateConfig,
    ConfigError,
    FitConfig,
    GateConfig,
    LabConfig,
    config_from_dict,
    config_rows,
    config_to_toml,
    load_config,
    save_config,
)

CONFIGS = Path(__file__).resolve().parents[1] / "configs"


def test_default_preset_equals_the_code_defaults() -> None:
    assert load_config(CONFIGS / "default.toml") == LabConfig()


def test_recall_preset_changes_only_what_it_lists() -> None:
    recall = load_config(CONFIGS / "recall.toml")
    assert recall.accumulate.min_samples == 3
    assert (recall.fit.tau0_m, recall.fit.min_inliers, recall.fit.min_spread_m) == (0.05, 15, 0.15)
    assert recall.track.confirm_hits == 2
    assert recall.filter == LabConfig().filter
    assert recall.accumulate.max_samples == 100


def test_save_then_load_round_trips(tmp_path: Path) -> None:
    config = LabConfig(
        gate=GateConfig(mode="parallax", parallax_deg=0.5),
        fit=replace(FitConfig(), tau_range_k=0.002, free=True),
    )
    path = tmp_path / "mine.toml"
    save_config(config, path, header="my run\nsecond line")
    assert path.read_text().startswith("# my run\n# second line\n")
    assert load_config(path) == config


@pytest.mark.parametrize(
    ("data", "message"),
    [
        ({"nonsense": {}}, "unknown section [nonsense]"),
        ({"fit": {"tau": 0.1}}, "unknown setting fit.tau"),
        ({"fit": 3}, "[fit] must be a table"),
        ({"fit": {"min_inliers": 3.5}}, "fit.min_inliers = 3.5: must be int"),
        ({"fit": {"min_inliers": True}}, "fit.min_inliers = True: must be int"),
        ({"fit": {"vertical": 1}}, "fit.vertical = 1: must be bool"),
        ({"gate": {"mode": "sometimes"}}, "gate.mode = 'sometimes': must be one of off, intended, upstream, parallax"),
        ({"accumulate": {"min_samples": 200}}, "accumulate.min_samples = 200: must be in [1, max_samples]"),
        ({"fit": {"vertical": False, "horizontal": False}}, "at least one of vertical, horizontal, free"),
        ({"filter": {"near_cut_m": 1.0, "far_cut_m": 0.5}}, "filter.far_cut_m = 0.5"),
        ({"track": {"merge_overlap": 1.5}}, "track.merge_overlap = 1.5: must be in [0, 1]"),
        ({"gate": {"parallax_deg": 0}}, "gate.parallax_deg = 0.0"),
    ],
)
def test_bad_settings_name_their_key(data: dict[str, object], message: str) -> None:
    with pytest.raises(ConfigError) as caught:
        config_from_dict(data)  # type: ignore[arg-type]
    assert message in str(caught.value)


def test_integers_are_accepted_for_floats() -> None:
    config = config_from_dict({"fit": {"tau0_m": 1}})
    assert config.fit.tau0_m == 1.0 and isinstance(config.fit.tau0_m, float)


def test_programmatic_configs_are_checked_too() -> None:
    with pytest.raises(ConfigError, match=r"accumulate\.zscore"):
        AccumulateConfig(zscore=0)


def test_broken_toml_is_a_config_error(tmp_path: Path) -> None:
    path = tmp_path / "broken.toml"
    path.write_text("[fit\n")
    with pytest.raises(ConfigError, match=r"broken\.toml"):
        load_config(path)


def test_rows_cover_every_setting() -> None:
    rows = dict(config_rows(LabConfig()))
    assert rows["fit.tau0_m"] == "0.03"
    assert rows["gate.mode"] == "off"
    assert rows["fit.vertical"] == "true"
    assert rows["accumulate.max_ids"] == "100000"
    toml_keys = [line.split(" = ")[0] for line in config_to_toml(LabConfig()).splitlines() if " = " in line]
    assert len(rows) == len(toml_keys) == 29  # filter 3, gate 4, accumulate 4, fit 12, track 6
