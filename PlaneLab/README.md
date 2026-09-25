# Plane Lab

Replay SidingsAR recordings on the Mac and fit planes offline: *accumulate → fit → track*, driven from Blender or the command line. The spec, plan and tasks live in [`../SPEC.md`](../SPEC.md); this README covers what exists so far.

**Status (2026-09-30):** the session reader, `planelab info` (T6), `planelab peek`, the Blender import (camera, video, raw points, ARKit planes, and the averaged cloud) with Pick Point in the Plane Lab tab, synthetic sessions (T14), `LabConfig` (T15), and CurvSurf's filter, gate and accumulator (T16) work. Plane fitting comes next (SPEC §18, T17 onward).

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
python -m planelab info <bundle> --check-cloud   # also: is the phone's recorded cloud what the Mac recomputes?
python -m planelab peek <bundle> [--csv frames.csv]   # readable copy: <bundle>/lab/peek.sqlite
python -m planelab blend <bundle>                     # ready-to-open <bundle>/lab/replay.blend
python -m planelab synth <out.planelab> --scene facade|edges|room [--seed 7 --seconds 10 --fps 30]   # known planes
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
| `cloud_rows`, `cloud_points`, `cloud_final` | phone cloud row; id per row; id | the averaged cloud the phone recorded (schema v2): each row's size, every id it removes or sets, and the cloud after the last row |
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
cloud     phone: 2 averaged points after 2 rows (0 frames missed)
```

*fps delivered* comes from the frame times, not from ARKit's promised format. The iPhone 13 has delivered 30 Hz against a promised 60 (SPEC §3.4, §15 R1). *points* is the distance from the camera to every raw feature point (E1).

## Blender extension

`blender/planelab_blender/` is a Blender 5 extension. **File › Import › Plane Lab Session** takes the `session.sqlite` inside a `.planelab` folder, the folder itself, or a zip of it, and builds one collection per recording:
- **Camera:** its pose is keyframed on every frame, converted from ARKit's +Y-up world to Blender's +Z-up world (`planelab.axes`). Lens and principal-point shift are also keyframed on every frame, because the intrinsics drift with autofocus.
- **Trail:** a static polyline of the whole camera path.
- **Video:** `video.mov` is the camera's background. The clip starts at `1 + first frame with an image`, because Blender drops a leading gap in the file but keeps later ones, holding the previous image (SPEC §15 R2). Looking through the camera shows the image with the points on top.
- **ARKit planes:** every plane anchor alive at the current frame, as its boundary polygon in SidingsAR's colors (wall cyan, floor green, ceiling yellow, table/seat orange, door/window purple), 35 % opaque. It comes from the recorded add/update/remove callbacks (`planelab.planes`). Recordings made before T11 (2026-09-28) have no anchors.
- **Raw points:** the current frame's feature points (yellow). A frame-change handler refills them from arrays cached per recording; nothing else is keyframed. Points keep a steady size on screen: radius = *Size* × distance from the recorded camera. *Size* defaults to 0.008 for raw dots and 0.006 for averaged ones, about 12 and 9 px of radius in the recorded image (SPEC P20, doubled in P27), and each layer has a slider in the Plane Lab tab.
- **Averaged cloud:** the phone's own cloud when the recording has one (schema v2, SPEC T29–T30), otherwise the Mac's recompute; the import's report says which. What CurvSurf's app shows, as it was at the current frame: every feature id with at least 5 samples, at the z-score-filtered mean of its last 100 sightings (T16, default `LabConfig`). Colored by samples in the FIFO: under 10 pale pink, 10–49 magenta, 50+ red. **Each band is its own object** (`<recording> averaged cloud under 10 samples`, `… 10 to 49 samples`, `… 50+ samples`, SPEC P31), grouped in an *averaged cloud* child collection. You can select, hide or isolate one band, and each has its own size slider in the Plane Lab tab. Pick Point skips a hidden band. On `20260930-102759`, the final 10,470 points split 11 / 3,267 / 7,192. Files saved before the split keep their single cloud object until re-imported. It's computed once per recording and cached as `<bundle>/lab/cloud-<hash>.npz` (`planelab.cloud`, SPEC P19): a snapshot every 6 frames, so the cloud grows in 0.1 s steps at 60 fps. Your 2,669-frame recording builds in 1.8 s (2 MB), and a frame change then takes < 3 ms.
- **X1 FindSurface planes / X2 RANSAC planes** (`../EXPERIMENTS.md` X1 and X2; the object is named after the recording's `surface_engine` meta): the planes the phone found and tracked, as they were at the current frame. They come from the recording's `surface` rows (schema v3, `planelab.surfaces`). Each track is its outline (the convex hull of its inliers) in the phone's colors: by track number (orange, blue, teal, indigo, mint, brown, yellow, green), faint while tentative, grey once stale. A merged or dropped track disappears at the frame of its remove row. The layer is empty for recordings made before schema v3 or with the engine off. `planelab info` adds a `planes` line (with the engine's name) and, from schema v4, a `rounds` line with the median, p95 and max round time, how many rounds searched, skipped rounds and rounds with the phone hot. `peek` adds `x1_surfaces` and `surface_rounds` tables.
- **Round stats** (schema v4, X2): an empty named `… round stats` carries what each round of the phone's engine cost as custom properties (`total_ms`, `refit_ms`, `search_ms`, `points`, `unclaimed`, `tracks`, `confirmed`, `hypotheses`, `thermal`, …), keyed with constant interpolation at the round's frame. Select it and open the Graph Editor to see compute time over the timeline, with the recording's markers (dial changes, benchmark results) on the same timeline. The **Plane engine** tab in the sidebar shows the latest round at the current frame as text.
- **Scene:** the frame range is 1 … frames (Blender frame = `idx + 1`), fps is the rate ARKit actually delivered, and the resolution is the captured image's. Session events become timeline markers named `PL …`.

**Picking one point** (*3D View › Sidebar (N) › Plane Lab › Points*, SPEC P27). Each layer is a single object, so a click in the viewport selects the whole cloud. To inspect a single point instead, press **Pick Point** and click near a dot, within 20 px. Esc or right-click cancels, and the view can still be orbited and zoomed while picking. The pick is a *feature*: its ARKit id, which the raw point and the averaged point share. The tab then shows, at the current frame:
- the id, as in `peek.sqlite`'s `point_id`
- the timeline frames where the id was seen
- the raw and averaged positions in both ARKit and Blender axes
- the samples in its FIFO
- the raw-to-averaged distance
- the distance from the recorded camera

A sphere marker (`… picked`) sits on the feature and follows it by id as you scrub. It sits on the averaged point, or the raw one before the cloud has it, and hides when the feature is absent. The marker is a normal object, so *N › Item › Location* shows its coordinates too. **Clear** (×) removes it, and re-importing the recording removes it as well. Only visible layers are picked. Averaged points can be picked only when the recording carries the phone's cloud, because the Mac's recompute doesn't keep ids; its raw points still can be.

Importing the same recording again replaces it. Opening a saved `.blend` fills the layers at once. **If the layers stay empty or frozen, the extension is off:** Edit › Preferences › Add-ons, search "Plane Lab", tick it. The user's 48 s recording (2,863 frames) imports in about 0.05 s, and changing frames refreshes the points in about 0.1 ms, measured headless.

```bash
./scripts/build_extension.sh                 # -> dist/planelab_blender-<version>.zip, with the core copied in
```

Install that zip with **Blender › Settings › Get Extensions › ⌄ › Install from Disk**.

`python -m planelab blend <bundle>` saves a ready-to-open `<bundle>/lab/replay.blend` of a recording, taking about 1 s. It runs Blender headless with `scripts/replay_blend.py`, and the file holds the import in an empty scene that opens in camera view. Blender comes from `--blender`, then `$BLENDER`, then `/Applications/Blender.app`.

**Dev link** (set up on 2026-09-28): add `PlaneLab/blender/` as a local repository in **Settings › Get Extensions › Repositories › + › Add Local Repository**, with a custom directory, then enable **Plane Lab**. Blender then runs the repository's code, and code changes load with **F3 › Reload Scripts**, then reopening the file.
- **What F3 reloads:** Blender's F3 reloads only an add-on's top file. Until 2026-10-01, `layers.py`, `build.py` and the whole `planelab` core kept the code Blender had started with. A Blender opened before schema v3 therefore refused v3 recordings through any number of F3s, and the cloud, planes and X1 layers stayed empty. `planelab_blender/__init__.py` now drops those modules when it's re-run, so F3 loads everything (`tests/blender/reload_check.py`).
- **When a recording can't be read:** the reason is logged to `~/PlaneLab/logs/planelab.log` and shown at the top of the Plane Lab tab, instead of the layers silently staying empty. In the repository, `vendor/planelab` is a symlink to `src/planelab`, and the build script copies the real files into the zip (SPEC §17.4 P6).

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
    session.cloud_rows()  # the phone's averaged cloud (schema v2), [] for version 1 files
    session.first_image_idx()  # where the video clip starts in Blender (SPEC §15 R2)
    session.delivered_fps()  # Blender's playback rate (SPEC §3.4)
```

## Layout

```
PlaneLab/
├── src/planelab/     core, no bpy
│   ├── schema.py     DDL, a copy of ../session-format/schema_v2.sql (tested to match); versions 1 and 2 are read
│   ├── session.py    reader: folders and zips, version check, BLOB decoding
│   ├── info.py       the summary behind `planelab info` and the Blender panel
│   ├── peek.py       `planelab peek`: the decoded, documented copy of a recording
│   ├── axes.py       ARKit → Blender: world axes, lens and shift from intrinsics, quaternions
│   ├── replay.py     packed per-frame arrays behind the Blender timeline
│   ├── planes.py     ARKit's planes over time: live anchors per frame, boundaries in world coordinates
│   ├── synth.py      synthetic sessions with known planes (facade, edges, room) and synth_truth.json
│   ├── config.py     LabConfig: every lab setting (filter, gate, accumulate, fit, track), TOML in and out
│   ├── gate.py       stages 2-3: near/far filter, CurvSurf's motion gate (intended/upstream/off), per-point parallax gate
│   ├── accumulate.py stage 4: CurvSurf's FeatureCompressor on numpy ring buffers; accumulate(replay, config)
│   ├── cloud.py      the averaged cloud at any frame: the Mac's recompute (cached in <bundle>/lab/cloud-<hash>.npz) or the phone's rows
│   ├── pick.py       Blender's Pick Point: the point nearest the mouse on screen, and one feature's report at a frame
│   ├── writer.py     a minimal schema-v1 writer, used only by synth
│   ├── cli.py        python -m planelab
│   └── log.py        silent rotating log file, plus stderr for the CLI
├── blender/planelab_blender/  the extension: manifest, import operator, scene build, frame handler, Pick Point, the Plane Lab tab;
│                     vendor/planelab → src/planelab
├── scripts/          build_extension.sh (the zip), replay_blend.py (behind `blend`), pull.sh (phone → Mac → Blender, see the root README),
│                     cloud_golden.py (the accumulator golden the Swift port is checked against, SPEC T27)
├── configs/          default.toml (every setting, commented; tested equal to the code) and recall.toml (overrides only)
├── spikes/           R2 Blender video spike (see spikes/README.md)
└── tests/            pytest: the contract (same fixture as Swift), reader, peek, axes, replay, CLI; test_blender.py drives headless Blender
```

## Checks

```bash
ruff check . && ruff format --check .
pytest --cov=planelab --cov-fail-under=85     # 140 tests incl. headless-Blender ones, about 98 % coverage
```

The contract test reads `../session-format/fixtures/v1/`, written by the Swift recorder, and compares every table with `expected.json` (SPEC S7). The core also runs under Blender's own interpreter:

```bash
PYTHONPATH=src /Applications/Blender.app/Contents/Resources/5.0/python/bin/python3.11 -m planelab info <bundle>
```
