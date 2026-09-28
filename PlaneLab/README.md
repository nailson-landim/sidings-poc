# Plane Lab

Replay SidingsAR recordings on the Mac and fit planes offline: *accumulate → fit → track*, driven from Blender or the command line. The spec, plan and tasks live in [`../SPEC.md`](../SPEC.md); this README covers what exists so far.

**Status (2026-09-28):** the session reader, `planelab info` (T6) and `planelab peek` work. The pipeline, the synthetic sessions and the Blender extension come next (SPEC §18, T8 onward).

## Setup

Python 3.11, the same as Blender 5.0.1. The core needs only numpy 1.26.4, pinned to Blender's version, so it runs inside Blender with no extra installs (L6).

```bash
cd PlaneLab
virtualenv -p python3.11 .venv && source .venv/bin/activate
pip install -r requirements.txt
pip install -e . --no-deps        # makes the `planelab` command available
```

## Commands

```bash
python -m planelab info <bundle>          # a .planelab folder, or a zip of one
python -m planelab info <bundle> --json   # machine-readable
python -m planelab peek <bundle> [--csv frames.csv]   # readable copy: <bundle>/lab/peek.sqlite
```

### `peek`: see everything in a recording

`peek` writes `<bundle>/lab/peek.sqlite`, a copy of the recording with every BLOB decoded into plain columns and every enum spelled out. The recording itself is never touched (SPEC §3.2). The **`_about`** table explains each table and column, with units.

| Table | One row per | Highlights |
|---|---|---|
| `frames` | logged frame | time and `dt_ms`, image yes/no, tracking, thermal, exposure, camera position (ARKit and Blender axes), path and speed, yaw/pitch/roll, intrinsics, point count, new feature ids, point distance percentiles |
| `points` | point per frame | feature id (as text, so uint64 fits), x/y/z, distance from the camera |
| `features` | feature id | first and last frame, times seen, mean position, **spread** (how much ARKit's estimate of that point moved), mean distance |
| `anchors` | ARKit plane callback | event, alignment, classification, position, normal, extent, boundary |
| `locations`, `headings`, `events`, `meta` | row of the original | readable copies (ISO times) |
| `summary` | field | the `planelab info` numbers |

The views `frames_without_image`, `slow_frames` (`dt_ms > 25`) and `tracking_not_normal` list the frames worth a look. Open the copy in any SQLite browser (DB Browser for SQLite, TablePlus), or with the `sqlite3` shell:

```bash
sqlite3 -box ~/PlaneLab/sessions/<name>.planelab/lab/peek.sqlite \
  "SELECT idx, round(t_rel_s,1) t, round(cam_x,2) x, round(cam_y,2) y, round(cam_z,2) z, round(yaw_deg) yaw,
          point_count, round(dist_p50_m,2) p50_m FROM frames WHERE idx % 300 = 0"
sqlite3 -box <peek.sqlite> "SELECT * FROM _about WHERE table_name = 'frames'"
```

`--csv` also writes the `frames` table as CSV for Numbers or a spreadsheet. A 48 s recording (2,863 frames, 721,812 points) takes about 2 s.

Zips are extracted once into `~/PlaneLab/cache/`. Logs go silently to `~/PlaneLab/logs/planelab.log` (`$PLANELAB_LOG_DIR` overrides it), and the CLI also prints warnings on stderr. An unreadable path or an unknown `schema_version` exits with code 2 and a message.

Example on the contract fixture:

```
tiny.planelab  (iPhone14,5, started 2026-09-28T12:00:00Z, stop: user)
frames    10 in 0.28 s, 32.0 fps delivered; 7 with an image, 0 dropped
tracking  70 % normal
points    p50 6.22 m, p95 9.30 m, max 9.69 m (36 points)
anchors   2 ARKit planes: 2 add, 1 update, 1 remove
site      -12.976562, -38.476562 (± 4.5 m); 2 fixes, 2 headings
events    6
```

*fps delivered* comes from the frame times, not from ARKit's promised format. The iPhone 13 has delivered 30 Hz against a promised 60 (SPEC §3.4, §15 R1). *points* is the distance from the camera to every raw feature point (E1).

## Reading sessions in code

```python
from pathlib import Path
from planelab.session import open_session

with open_session(Path("~/PlaneLab/sessions/20260928-101500.planelab")) as session:
    for frame in session.frames():
        frame.camera  # (4, 4) world <- camera, row-major, ARKit axes (+Y up)
        frame.points  # (N, 3) float32 raw feature points, world
        frame.point_ids  # (N,) uint64
    session.first_image_idx()  # where the video clip starts in Blender (SPEC §15 R2)
    session.delivered_fps()  # Blender's playback rate (SPEC §3.4)
```

## Layout

```
PlaneLab/
├── src/planelab/     core, no bpy
│   ├── schema.py     DDL, a copy of ../session-format/schema_v1.sql (tested to match)
│   ├── session.py    reader: folders and zips, version check, BLOB decoding
│   ├── info.py       the summary behind `planelab info` and the Blender panel
│   ├── peek.py       `planelab peek`: the decoded, documented copy of a recording
│   ├── cli.py        python -m planelab
│   └── log.py        silent rotating log file, plus stderr for the CLI
├── spikes/           R2 Blender video spike (see spikes/README.md)
└── tests/            pytest: the contract (same fixture as Swift), reader edge cases, CLI
```

## Checks

```bash
ruff check . && ruff format --check .
pytest --cov=planelab --cov-fail-under=85     # 39 tests, 98 % coverage
```

The contract test reads `../session-format/fixtures/v1/`, written by the Swift recorder, and compares every table with `expected.json` (SPEC S7). The core also runs under Blender's own interpreter:

```bash
PYTHONPATH=src /Applications/Blender.app/Contents/Resources/5.0/python/bin/python3.11 -m planelab info <bundle>
```
