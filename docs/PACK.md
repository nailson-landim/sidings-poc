# PACK: moving the work to the Linux box

*Written 2026-09-30. What to copy, where it goes, what runs there, and how to resume with Claude. Read it with `HANDOFF.md`.*

## Why move

The next experiment (T33) reconstructs the courtyard with SfM (COLMAP) from the high-resolution stills. COLMAP's dense stage needs CUDA, and the NVIDIA machines run Linux. The Mac stays the place for the phone.

| | Mac Studio | Linux box |
|---|---|---|
| SidingsAR (iOS app), Xcode, `xcodebuild` | yes | no |
| PlaneKit `swift test` | yes | no: the recorder imports AVFoundation, CoreVideo and CoreImage |
| `PlaneLab/scripts/pull.sh` (phone → computer) | yes | no: it uses `xcrun devicectl` |
| Plane Lab Python (`planelab info`, `peek`, `blend`, pytest, ruff) | yes | yes, with its own `.venv` |
| Blender 5.0.1 with the Plane Lab extension | yes | yes, the Linux build (set `$BLENDER`) |
| COLMAP | sparse only (no CUDA) | sparse and dense (T33 installs it) |

New recordings come off the phone on the Mac (`pull.sh`) and then go to the Linux box with the recordings `rsync` below.

## 1. Copy (run on the Mac)

```bash
LINUX=user@linux-box                   # the ssh target
DEST=Developer/beam/sidings_poc        # the repository on the Linux box, relative to its $HOME
```

**The repository, with its git history** (about 22 MB). The Mac's build folders and `.venv` stay behind: they hold macOS binaries.

```bash
cd /Volumes/512G/Developer/beam/sidings_poc
rsync -avz --progress \
  --exclude .DS_Store --exclude .venv/ --exclude .build/ --exclude .swiftpm/ --exclude DerivedData/ \
  --exclude xcuserdata/ --exclude __pycache__/ --exclude .pytest_cache/ --exclude .ruff_cache/ \
  --exclude .coverage --exclude htmlcov/ --exclude PlaneLab/blender/.blender_ext/ \
  ./ "$LINUX:$DEST/"
```

**The recordings** (about 1.4 GB). They're outside git (video of houses; `.gitignore`). Keep them in `~/PlaneLab/sessions/` on the Linux box too, so every path in the docs still works. `lab/` stays behind: it's rebuilt there with `planelab peek` and `planelab blend`.

```bash
rsync -avz --progress --exclude lab/ --exclude .DS_Store \
  ~/PlaneLab/sessions/ "$LINUX:PlaneLab/sessions/"
```

T33 needs only `20260930-174033.planelab` (451 MB), plus `20260930-171700.planelab` (522 MB) as the blurred "before" case.

**Claude's memory.** Claude Code keeps a project's memory under `~/.claude/projects/<key>/memory/`, where `<key>` is the project's absolute path with every character other than a letter or digit replaced by `-`. The Mac's key is `-Volumes-512G-Developer-beam-sidings-poc`. On the Linux box, find its key by starting `claude` once in the repository and looking in `~/.claude/projects/`, or compute it:

```bash
# on the Linux box, inside the repository
pwd | sed 's/[^a-zA-Z0-9]/-/g'        # e.g. -home-nailson-Developer-beam-sidings-poc
```

Then copy the memory files into that key (from the Mac):

```bash
KEY=-home-nailson-Developer-beam-sidings-poc     # what the command above printed
rsync -av ~/.claude/projects/-Volumes-512G-Developer-beam-sidings-poc/memory/ "$LINUX:.claude/projects/$KEY/memory/"
```

Copy `~/.claude/CLAUDE.md` (the global rules) too if the box doesn't have it. Its *Environment* section describes the Mac Studio and OrbStack; change it there to the Linux box and Docker with the NVIDIA runtime.

This session's transcript doesn't need to move: `HANDOFF.md`, this file, `SPEC.md` and the memories carry the state, and a fresh session reads them far more cheaply than it would replay the transcript.

## 2. Set up (on the Linux box)

```bash
cd ~/Developer/beam/sidings_poc && git status          # clean, same last commit as the Mac
cd PlaneLab
virtualenv -p python3.11 .venv && source .venv/bin/activate    # Python 3.11, Blender 5.0.1's version
pip install -r requirements.txt && pip install -e . --no-deps
export BLENDER=/path/to/blender-5.0.1-linux-x64/blender        # put it in the shell profile
ruff check . && ruff format --check . && pytest --cov=planelab --cov-fail-under=85
python -m planelab info ~/PlaneLab/sessions/20260930-174033.planelab --check-cloud
python -m planelab peek ~/PlaneLab/sessions/20260930-174033.planelab
```

- **Blender tests** skip when `$BLENDER` doesn't point at a Blender. Then coverage can fall under the 85 % floor, so set `$BLENDER` first.
- **The Blender extension:** add `PlaneLab/blender/` as a local extension repository, as on the Mac (`PlaneLab/README.md`, *Dev link*). `vendor/planelab` is a relative symlink, so it survives `rsync`.
- **Python 3.11:** if the distribution doesn't ship it, install it first (with pyenv or the distribution's backports); keep the `.venv` rule.
- **COLMAP:** not installed yet. T33 starts by getting a CUDA build running, either the official Docker image with the NVIDIA container toolkit or a native build. Check `nvidia-smi` first.

## 3. Resume with Claude

Start `claude` in the repository on the Linux box and paste:

> Resume from `HANDOFF.md` and `PACK.md`, on the Linux box. Check the setup in PACK §2 first, then start T33: COLMAP on `20260930-174033`'s stills with ARKit's poses frozen, then compare the SfM points with the phone's averaged cloud by distance. Read `SPEC.md` P29, P30 and T33 first. Keep the working agreements in HANDOFF. Ask me with AskUserQuestion when a call is mine.

## 4. The data T33 starts from

| Recording | What it is |
|---|---|
| `20260930-174033` | **The one to use.** 17:40, 64 s, 26 m walked, iPhone 13. 139 stills at 4032 × 3024, exposure 0.99 ms, ISO 500–1250, predicted blur 1.8 px median (3.4 px p90). 3,292 frames at about 51 fps, tracking 100 % normal, the phone's cloud recorded. |
| `20260930-171700` | 17:17, 79 s, 37 m. 123 stills, all blurred (exposure 9.4 ms, 17.4 px median): the "before" case. |
| `20260930-102759`, `20260929-172952` | The same courtyard in daylight, video only (1920 × 1440, 8 Mbps HEVC): the fallback for SfM from video frames. |

## 5. ARKit → COLMAP, for the exporter

Each line of `stills/stills.jsonl` has:
- `file`, `t` (ARKit's clock, the same as `frame.t`) and `frame_idx`;
- `camera_to_world`: a 4 × 4 matrix written row by row, in ARKit's convention (camera +X right, +Y up, looking down −Z; world +Y up; metres);
- `fx`, `fy`, `cx`, `cy` for `camera_image_width` × `camera_image_height`, which equals the JPEG's `width` × `height` (4032 × 3024) in both runs;
- `exposure_s`, `tracking` and `exif`.

COLMAP's `images.txt` wants world-to-camera, with camera +X right, +Y down, looking down +Z:
1. `R_cw` is the upper-left 3 × 3 of `camera_to_world`, and `C` its last column (the camera centre).
2. Flip the camera's Y and Z axes: `R_cw' = R_cw · diag(1, −1, −1)`.
3. World-to-camera: `R = R_cw'ᵀ` and `t = −R · C`. COLMAP stores `R` as a quaternion in `w, x, y, z` order.
4. Keep ARKit's world as COLMAP's world (Y up, metres), so points compare directly with the phone's cloud and with Blender (Blender axes: X, −Z, Y).
5. `cameras.txt`: a `PINHOLE` camera per still (`4032 3024 fx fy cx cy`). Autofocus moves fx a little between stills; one shared camera is fine if the spread turns out tiny.
6. Don't rotate the JPEGs. They're in the sensor's orientation, which the intrinsics describe.
7. Check the result by reprojection error. A half-pixel difference in principal-point conventions is possible, and it would show up there.

Poses stay in ARKit's convention in the recording; the conversion belongs in the exporter (P29). Frozen poses keep D1 (VIO pose taken as given); letting COLMAP refine them would bend D1, so flag it first (`CONSOLIDATION.md`).

## 6. Git between the machines

There's no remote (root `CLAUDE.md`), and both copies carry the full history. Work on one machine at a time, and move commits with a plain pull over ssh, for example on the Mac: `git pull <linux-host>:Developer/beam/sidings_poc main`. Whether to add a remote instead is the user's call. Recordings never go into git.

## 7. Checklist

- [ ] Repository copied; `git status` clean on the Linux box at the same commit as the Mac
- [ ] Recordings copied (at least `20260930-174033`)
- [ ] Claude's memory copied into the Linux key; global `~/.claude/CLAUDE.md` adjusted
- [ ] `.venv` built; ruff and pytest green with `$BLENDER` set
- [ ] `nvidia-smi` works; COLMAP with CUDA runs (T33's first step)
