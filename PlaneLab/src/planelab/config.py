"""Every lab setting in one frozen ``LabConfig``, loaded from and saved to TOML (SPEC.md §5, L8).

A TOML file may set only some keys; the rest keep their defaults, so a preset like ``configs/recall.toml`` lists only
what it changes. Each section checks its own values when it's built, so a bad value fails early with its
``section.key`` in the message. ``config_rows`` gives the ``key = value`` rows each run stores in ``results.sqlite``.
"""

import json
import tomllib
from collections.abc import Callable
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import Any

GATE_MODES = ("off", "intended", "upstream", "parallax")


class ConfigError(ValueError):
    """A setting is unknown, of the wrong type, or out of range."""


def _require(section: str, key: str, value: object, ok: bool, requirement: str) -> None:
    if not ok:
        raise ConfigError(f"{section}.{key} = {value!r}: {requirement}")


@dataclass(slots=True, frozen=True)
class FilterConfig:
    """Stage 2: which raw points are used at all."""

    near_cut_m: float = 0.25
    """Points closer to the camera are dropped (CurvSurf: 0.25 m)."""
    far_cut_m: float = 0.0
    """Points farther are dropped; 0 keeps every distance."""
    normal_tracking_only: bool = False
    """Skip frames whose tracking isn't ``normal``."""

    def __post_init__(self) -> None:
        _require("filter", "near_cut_m", self.near_cut_m, self.near_cut_m >= 0, "must be >= 0")
        _require(
            "filter",
            "far_cut_m",
            self.far_cut_m,
            self.far_cut_m == 0 or self.far_cut_m > self.near_cut_m,
            "must be 0 (off) or beyond near_cut_m",
        )


@dataclass(slots=True, frozen=True)
class GateConfig:
    """Stage 3: which samples reach the accumulator (SPEC.md §5.1, *Why gate at all*)."""

    mode: str = "off"
    """``off`` (every frame), ``intended`` (CurvSurf as documented), ``upstream`` (CurvSurf as coded), ``parallax``."""
    move_m: float = 0.03
    turn_deg: float = 3.0
    parallax_deg: float = 1.0
    """``parallax``: a feature's new sample counts once its view direction has turned this far."""

    def __post_init__(self) -> None:
        _require("gate", "mode", self.mode, self.mode in GATE_MODES, f"must be one of {', '.join(GATE_MODES)}")
        _require("gate", "move_m", self.move_m, self.move_m >= 0, "must be >= 0")
        _require("gate", "turn_deg", self.turn_deg, 0 <= self.turn_deg <= 180, "must be in [0, 180]")
        _require("gate", "parallax_deg", self.parallax_deg, 0 < self.parallax_deg <= 90, "must be in (0, 90]")


@dataclass(slots=True, frozen=True)
class AccumulateConfig:
    """Stage 4: CurvSurf's per-feature averaging."""

    max_samples: int = 100
    min_samples: int = 5
    zscore: float = 2.0
    max_ids: int = 100_000

    def __post_init__(self) -> None:
        _require("accumulate", "max_samples", self.max_samples, self.max_samples >= 1, "must be >= 1")
        _require(
            "accumulate",
            "min_samples",
            self.min_samples,
            1 <= self.min_samples <= self.max_samples,
            "must be in [1, max_samples]",
        )
        _require("accumulate", "zscore", self.zscore, self.zscore > 0, "must be > 0")
        _require("accumulate", "max_ids", self.max_ids, self.max_ids >= 1, "must be >= 1")


@dataclass(slots=True, frozen=True)
class FitConfig:
    """Stage 5: plane fitting on the averaged cloud."""

    fit_every: int = 6
    """Fit every N frames (6 = 10 Hz at 60 fps)."""
    tau0_m: float = 0.03
    """Inlier distance at zero range."""
    tau_range_k: float = 0.0
    """Inlier distance grows as ``tau0_m + tau_range_k * range²``."""
    min_inliers: int = 30
    min_spread_m: float = 0.3
    """Inliers must spread at least this far in both directions of the plane (rejects a single edge)."""
    edge_keep_m: float = 0.1
    """Points this close to an accepted plane's boundary stay available for the next search (shared corners)."""
    vertical: bool = True
    horizontal: bool = True
    free: bool = False
    iterations: int = 200
    """RANSAC hypotheses per search."""
    max_planes: int = 12
    """Searches per fit."""
    seed: int = 0

    def __post_init__(self) -> None:
        _require("fit", "fit_every", self.fit_every, self.fit_every >= 1, "must be >= 1")
        _require("fit", "tau0_m", self.tau0_m, self.tau0_m > 0, "must be > 0")
        _require("fit", "tau_range_k", self.tau_range_k, self.tau_range_k >= 0, "must be >= 0")
        _require("fit", "min_inliers", self.min_inliers, self.min_inliers >= 3, "must be >= 3")
        _require("fit", "min_spread_m", self.min_spread_m, self.min_spread_m >= 0, "must be >= 0")
        _require("fit", "edge_keep_m", self.edge_keep_m, self.edge_keep_m >= 0, "must be >= 0")
        _require(
            "fit",
            "vertical",
            self.vertical,
            self.vertical or self.horizontal or self.free,
            "at least one of vertical, horizontal, free must be on",
        )
        _require("fit", "iterations", self.iterations, self.iterations >= 1, "must be >= 1")
        _require("fit", "max_planes", self.max_planes, self.max_planes >= 1, "must be >= 1")


@dataclass(slots=True, frozen=True)
class TrackConfig:
    """Stage 6: planes kept across fits, like ARKit anchors (SPEC.md §5.2). Merge terms follow PlaneKit's NMS."""

    merge_angle_deg: float = 10.0
    merge_distance_m: float = 0.08
    merge_overlap: float = 0.3
    confirm_hits: int = 3
    stale_after_fits: int = 30
    ema_alpha: float = 0.3

    def __post_init__(self) -> None:
        _require("track", "merge_angle_deg", self.merge_angle_deg, 0 < self.merge_angle_deg <= 90, "must be in (0, 90]")
        _require("track", "merge_distance_m", self.merge_distance_m, self.merge_distance_m >= 0, "must be >= 0")
        _require("track", "merge_overlap", self.merge_overlap, 0 <= self.merge_overlap <= 1, "must be in [0, 1]")
        _require("track", "confirm_hits", self.confirm_hits, self.confirm_hits >= 1, "must be >= 1")
        _require("track", "stale_after_fits", self.stale_after_fits, self.stale_after_fits >= 1, "must be >= 1")
        _require("track", "ema_alpha", self.ema_alpha, 0 < self.ema_alpha <= 1, "must be in (0, 1]")


@dataclass(slots=True, frozen=True)
class LabConfig:
    filter: FilterConfig = field(default_factory=FilterConfig)
    gate: GateConfig = field(default_factory=GateConfig)
    accumulate: AccumulateConfig = field(default_factory=AccumulateConfig)
    fit: FitConfig = field(default_factory=FitConfig)
    track: TrackConfig = field(default_factory=TrackConfig)


SECTIONS: dict[str, type] = {f.name: f.type for f in fields(LabConfig)}  # type: ignore[misc]


def _coerce(section: str, key: str, expected: type, value: object) -> object:
    """TOML integers are accepted where floats are expected; nothing else is converted."""
    checks: dict[type, Callable[[object], bool]] = {
        bool: lambda v: isinstance(v, bool),
        int: lambda v: isinstance(v, int) and not isinstance(v, bool),
        float: lambda v: isinstance(v, int | float) and not isinstance(v, bool),
        str: lambda v: isinstance(v, str),
    }
    _require(section, key, value, checks[expected](value), f"must be {expected.__name__}")
    return float(value) if expected is float else value  # type: ignore[arg-type]


def config_from_dict(data: dict[str, Any]) -> LabConfig:
    """Builds a config from parsed TOML. Missing sections and keys keep their defaults."""
    sections: dict[str, object] = {}
    for name, values in data.items():
        if name not in SECTIONS:
            raise ConfigError(f"unknown section [{name}]; known: {', '.join(SECTIONS)}")
        if not isinstance(values, dict):
            raise ConfigError(f"[{name}] must be a table")
        cls = SECTIONS[name]
        types = {f.name: f.type for f in fields(cls)}
        for key in values:
            if key not in types:
                raise ConfigError(f"unknown setting {name}.{key}; known: {', '.join(types)}")
        sections[name] = cls(**{k: _coerce(name, k, types[k], v) for k, v in values.items()})
    return LabConfig(**sections)  # type: ignore[arg-type]


# The phone's averaged-cloud settings (RecorderConstants.cloud*, SPEC.md P21), as written to meta by schema v2.
META_KEYS: dict[str, tuple[str, str]] = {
    "const.cloudNearCutM": ("filter", "near_cut_m"),
    "const.cloudFarCutM": ("filter", "far_cut_m"),
    "const.cloudNormalTrackingOnly": ("filter", "normal_tracking_only"),
    "const.cloudGate": ("gate", "mode"),
    "const.cloudMoveM": ("gate", "move_m"),
    "const.cloudTurnDeg": ("gate", "turn_deg"),
    "const.cloudMaxSamples": ("accumulate", "max_samples"),
    "const.cloudMinSamples": ("accumulate", "min_samples"),
    "const.cloudZScore": ("accumulate", "zscore"),
    "const.cloudMaxIds": ("accumulate", "max_ids"),
}


def config_from_meta(meta: dict[str, str]) -> LabConfig:
    """The settings the phone's cloud ran with (``const.cloud*`` rows), on top of the defaults. A recording without
    them (schema v1) gives the defaults, which are the same values.
    """
    data: dict[str, dict[str, object]] = {}
    for key, (section, name) in META_KEYS.items():
        if key not in meta:
            continue
        expected = {f.name: f.type for f in fields(SECTIONS[section])}[name]
        text = meta[key]
        try:
            value: object = {bool: lambda t: t == "true", int: int, float: float, str: str}[expected](text)
        except ValueError as error:
            raise ConfigError(f"meta {key} = {text!r} is not a {expected.__name__}") from error
        data.setdefault(section, {})[name] = value
    return config_from_dict(data)


def load_config(path: Path) -> LabConfig:
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        raise ConfigError(f"{path.name}: {error}") from error
    return config_from_dict(data)


def _toml_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value)
    return repr(value)


def config_to_toml(config: LabConfig, header: str = "") -> str:
    lines = [f"# {line}" for line in header.splitlines()] + ([""] if header else [])
    for name in SECTIONS:
        section = getattr(config, name)
        lines.append(f"[{name}]")
        lines += [f"{f.name} = {_toml_value(getattr(section, f.name))}" for f in fields(section)]
        lines.append("")
    return "\n".join(lines)


def save_config(config: LabConfig, path: Path, header: str = "") -> None:
    path.write_text(config_to_toml(config, header), encoding="utf-8")


def config_rows(config: LabConfig) -> list[tuple[str, str]]:
    """``(section.key, value)`` for every setting, as stored in ``results.sqlite`` (L8)."""
    return [
        (f"{name}.{f.name}", _toml_value(getattr(getattr(config, name), f.name)).strip('"'))
        for name in SECTIONS
        for f in fields(getattr(config, name))
    ]
