# Plane Lab

Replay SidingsAR recordings on the Mac and fit planes offline: *accumulate → fit → track*, driven from Blender or the command line. The spec, plan and tasks live in [`../SPEC.md`](../SPEC.md); this README covers what exists so far.

**Status (2026-09-28):** the session reader, `planelab info` (T6), `planelab peek`, and the Blender import of the camera path and raw points (T8) work. The pipeline, the synthetic sessions and the Blender extension come next (SPEC §18, T8 onward).

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
python -m planelab blend <bundle>                     # ready-to-open <bundle>/lab/replay.blend
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

## Blender extension

`blender/planelab_blender/` is a Blender 5 extension. **File › Import › Plane Lab Session** takes the `session.sqlite` inside a `.planelab` folder, the folder itself, or a zip of it, and builds one collection per recording:
- **Camera:** its pose is keyframed on every frame, converted from ARKit's +Y-up world to Blender's +Z-up world (`planelab.axes`). Lens and principal-point shift are also keyframed on every frame, because the intrinsics drift with autofocus.
- **Trail:** a static polyline of the whole camera path.
- **Video:** `video.mov` is the camera's background. The clip starts at `1 + first frame with an image`, because Blender drops a leading gap in the file but keeps later ones, holding the previous image (SPEC §15 R2). Looking through the camera shows the image with the points on top.
- **ARKit planes:** every plane anchor alive at the current frame, as its boundary polygon in SidingsAR's colors (wall cyan, floor green, ceiling yellow, table/seat orange, door/window purple), 35 % opaque. It comes from the recorded add/update/remove callbacks (`planelab.planes`). Recordings made before T11 (2026-09-28) have no anchors.
- **Raw points:** the current frame's feature points (yellow). A frame-change handler refills them from arrays cached per recording; nothing else is keyframed.
- **Scene:** the frame range is 1 … frames (Blender frame = `idx + 1`), fps is the rate ARKit actually delivered, and the resolution is the captured image's. Session events become timeline markers named `PL …`.

Importing the same recording again replaces it. The user's 48 s recording (2,863 frames) imports in about 0.05 s, and changing frames refreshes the points in about 0.1 ms, measured headless.

```bash
./scripts/build_extension.sh                 # -> dist/planelab_blender-<version>.zip, with the core copied in
```

Install that zip with **Blender › Settings › Get Extensions › ⌄ › Install from Disk**.

`python -m planelab blend <bundle>` saves a ready-to-open `<bundle>/lab/replay.blend` of a recording, taking about 1 s. It runs Blender headless with `scripts/replay_blend.py`, and the file holds the import in an empty scene that opens in camera view. Blender comes from `--blender`, then `$BLENDER`, then `/Applications/Blender.app`.

**Dev link** (set up on 2026-09-28): add `PlaneLab/blender/` as a local repository in **Settings › Get Extensions › Repositories › + › Add Local Repository**, with a custom directory, then enable **Plane Lab**. Blender then runs the repository's code, and code changes load with **F3 › Reload Scripts**. For development, a local repository pointing at `PlaneLab/blender/` loads the source directly, so *Reload Scripts* picks up edits. In the repository, `vendor/planelab` is a symlink to `src/planelab`, and the build script copies the real files into the zip (SPEC §17.4 P6).

`tests/test_blender.py` runs the real Blender headless. It imports the contract fixture and checks the camera pose, lens and points against the core's own conversion. It also builds the zip and installs it into a throwaway Blender profile. It's skipped when Blender isn't installed.

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
│   ├── axes.py       ARKit → Blender: world axes, lens and shift from intrinsics, quaternions
│   ├── replay.py     packed per-frame arrays behind the Blender timeline
│   ├── planes.py     ARKit's planes over time: live anchors per frame, boundaries in world coordinates
│   ├── cli.py        python -m planelab
│   └── log.py        silent rotating log file, plus stderr for the CLI
├── blender/planelab_blender/  the extension: manifest, import operator, scene build, frame handler; vendor/planelab → src/planelab
├── scripts/          build_extension.sh (the zip), replay_blend.py (behind `blend`), pull.sh (phone → Mac → Blender, see the root README)
├── spikes/           R2 Blender video spike (see spikes/README.md)
└── tests/            pytest: the contract (same fixture as Swift), reader, peek, axes, replay, CLI; test_blender.py drives headless Blender
```

## Checks

```bash
ruff check . && ruff format --check .
pytest --cov=planelab --cov-fail-under=85     # 64 tests incl. headless-Blender ones, about 99 % coverage
```

The contract test reads `../session-format/fixtures/v1/`, written by the Swift recorder, and compares every table with `expected.json` (SPEC S7). The core also runs under Blender's own interpreter:

```bash
PYTHONPATH=src /Applications/Blender.app/Contents/Resources/5.0/python/bin/python3.11 -m planelab info <bundle>
```
