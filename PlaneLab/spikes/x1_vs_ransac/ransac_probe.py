"""Quick probe, not T17: sequential RANSAC with vertical/horizontal priors on a recording's final averaged cloud
(EXPERIMENTS.md, X1 verdict, 2026-10-01). Band = 4 cm + 0.12 cm/m^2 x range^2; 400 horizontal (1-point) and 3,000
vertical (2-point) hypotheses per plane; least-squares refit; collinear support rejected; up to 10 planes.

    python spikes/x1_vs_ransac/ransac_probe.py 20261001-142809.planelab 20261001-143156.planelab \\
        20261001-115808.planelab

``ransac_scene.py`` draws the same result in Blender.
"""

import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from planelab.cloud import session_cloud
from planelab.replay import Replay, load_replay
from planelab.session import open_session

UP = np.array([0, 1.0, 0])


@dataclass(slots=True, frozen=True)
class ProbePlane:
    kind: str
    """"V" vertical or "H" horizontal."""
    normal: np.ndarray
    center: np.ndarray
    inliers: np.ndarray
    """Indices into the cloud's points."""
    rms: float
    corners: np.ndarray
    """(4, 3) the inliers' 2-98 % extent as a rectangle on the plane, ARKit world."""
    median_range: float

    @property
    def offset(self) -> float:
        return float(np.dot(self.normal, self.center))

    @property
    def size(self) -> tuple[float, float]:
        return float(np.linalg.norm(self.corners[1] - self.corners[0])), float(
            np.linalg.norm(self.corners[3] - self.corners[0])
        )


def tau_of(r: np.ndarray) -> np.ndarray:  # range-scaled band (SPEC 5.1: tau0 + k z^2)
    return 0.04 + 0.0012 * r**2


def refit_vertical(p: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    xz = p[:, [0, 2]]
    c = xz.mean(0)
    _, _, vt = np.linalg.svd(xz - c)
    d = vt[0]
    n = np.array([-d[1], 0, d[0]])
    return n / np.linalg.norm(n), np.array([c[0], p[:, 1].mean(), c[1]])


def final_cloud(name: str) -> tuple[np.ndarray, Replay]:
    """The phone's averaged cloud after the last frame (ARKit world, float64) and the recording's replay."""
    with open_session(Path.home() / "PlaneLab/sessions" / name) as session:
        replay = load_replay(session)
        cloud, _ = session_cloud(session, replay)
    points, _ = cloud.at(len(replay) - 1)
    return points.astype(np.float64), replay


def probe(points: np.ndarray, cameras: np.ndarray, seed: int = 7) -> list[ProbePlane]:
    """Up to 10 planes, largest first. ``cameras`` (M, 3) are camera positions, for each point's range."""
    rng = np.random.default_rng(seed)
    r = np.min(np.linalg.norm(points[:, None, :] - cameras[None], axis=2), axis=1)
    tau = tau_of(r)
    left = np.ones(len(points), bool)
    planes: list[ProbePlane] = []
    for _ in range(10):
        idx = np.flatnonzero(left)
        if len(idx) < 150:
            break
        cand = points[idx]
        band = tau[idx]
        best = (0, "", np.zeros(0, bool))
        for i in rng.integers(0, len(cand), 400):  # horizontal: 1-point
            inl = np.abs(cand[:, 1] - cand[i, 1]) < band
            if inl.sum() > best[0]:
                best = (int(inl.sum()), "H", inl)
        for _ in range(3000):  # vertical: 2-point
            i, j = rng.integers(0, len(cand), 2)
            d = cand[j] - cand[i]
            d[1] = 0
            if np.linalg.norm(d) < 0.3:
                continue
            n = np.cross(d, UP)
            n /= np.linalg.norm(n)
            inl = np.abs((cand - cand[i]) @ n) < band
            if inl.sum() > best[0]:
                best = (int(inl.sum()), "V", inl)
        count, kind, inl = best
        if count < 150:
            break
        n, c = refit_vertical(cand[inl]) if kind == "V" else (UP, cand[inl].mean(0))
        inl = np.abs((cand - c) @ n) < band  # inliers of the refit
        q = cand[inl]
        if kind == "V":
            n, c = refit_vertical(q)
        h = np.cross(UP, n) if kind == "V" else np.array([1.0, 0, 0])
        h /= np.linalg.norm(h)
        w = np.cross(n, h)
        pu, pv = (q - c) @ h, (q - c) @ w
        left[idx[inl]] = False
        spread = np.sqrt(12 * np.linalg.eigvalsh(np.cov(np.stack([pu, pv])))[0])
        if spread < 0.3:  # an edge seen alone (collinear support)
            continue
        u0, u1 = np.percentile(pu, [2, 98])
        v0, v1 = np.percentile(pv, [2, 98])
        corners = np.array([c + a * h + b * w for a, b in ((u0, v0), (u1, v0), (u1, v1), (u0, v1))])
        planes.append(
            ProbePlane(
                kind=kind,
                normal=n,
                center=c,
                inliers=idx[inl],
                rms=float(((q - c) @ n).std()),
                corners=corners,
                median_range=float(np.median(r[idx[inl]])),
            )
        )
    return planes


def main(names: list[str]) -> None:
    for name in names:
        points, replay = final_cloud(name)
        cameras = replay.cameras[:: max(1, len(replay) // 300), :3, 3]
        print(f"\n===== {name}: {len(points)} points; RANSAC with priors (tau 4 cm + 0.12 cm/m^2)")
        for p in probe(points, cameras):
            width, height = p.size
            print(
                f"  {p.kind} n=({p.normal[0]:+.2f},{p.normal[1]:+.2f},{p.normal[2]:+.2f}) {len(p.inliers):5d} inliers, "
                f"rms {p.rms * 100:.1f} cm, extent (2-98%) {width:.1f} x {height:.1f} m, "
                f"median range {p.median_range:.1f} m, offset {p.offset:+.2f}"
            )


if __name__ == "__main__":
    main(sys.argv[1:])
