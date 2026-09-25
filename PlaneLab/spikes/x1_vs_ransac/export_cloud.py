"""Writes a recording's final averaged cloud for ``ransac_bench.swift``: N x (x, y, z, band) float32, little-endian.

python export_cloud.py 20261001-142809.planelab cloud.f32
swiftc -O -o ransac_bench ransac_bench.swift && ./ransac_bench cloud.f32
"""

import sys

import numpy as np
from ransac_probe import final_cloud, tau_of

points, replay = final_cloud(sys.argv[1])
cameras = replay.cameras[:: max(1, len(replay) // 300), :3, 3]
ranges = np.min(np.linalg.norm(points[:, None, :] - cameras[None], axis=2), axis=1)
np.concatenate([points.astype(np.float32), tau_of(ranges)[:, None].astype(np.float32)], axis=1).tofile(sys.argv[2])
print(f"{len(points)} points -> {sys.argv[2]}")
