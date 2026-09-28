# HANDOFF: Plane Lab build


**Day wrap-up: [`28_SEP_26-HANDOFF.md`](28_SEP_26-HANDOFF.md)** has everything built, tested and found on 28 Sep, plus the full TODO.
*Last updated 2026-09-28 after T7 closed. Read this first when resuming; `SPEC.md` has the full detail.*

## Resume prompt

Paste this into a new session:

> Resume the Plane Lab build from `HANDOFF.md`. Read it, then `SPEC.md` §0, §15, §17 and §18 (tick state), and continue with the first open item under *Next steps*. Keep the working agreements in HANDOFF.md.

## Where things stand

`SPEC.md` is the single source for this work: spec §0–16, plan §17, tasks §18 with checkboxes. The spec and the plan were approved on 2026-09-28, and every §16 question is closed.

| Task | Status | Commit |
|---|---|---|
| T1 Video writer (PlaneKit) | Done | `3f55bae` |
| T2 Spike R2: Blender video alignment | Done. **User scrub check still open** (doesn't block anything) | `8321164` |
| T3 Spike R1: iPhone 13 load | Done, closed by the user | `003c4a4`, `f6ad4e6`, `14cba09` |
| Checkpoint 0 | Passed | `14cba09` |
| T4 Schema v1, records, packing, contract fixture | Done | `899292c` |
| T5 Session writer | Done | `8686b42` |
| T6 Python package, reader, `planelab info` | Done | `08f55cb` |
| T7 Record/Stop in SidingsAR | Done. The user's recording `20260928-160746`: 2,863 frames at 60 Hz, 0 dropped, 0.24 % without an image | `e90e034` + docs commit |
| T8 Blender extension and import (camera, trail, raw points) | Done (headless). The Reload Scripts dev loop waits for the user's OK to add a local repository | this commit |
| T9 Video behind the camera | Done, S11 confirmed by the user | `f788539` |
| Checkpoint 1 | **Passed** (user, 2026-09-28): S11 holds, points sit on the video. The user linked `PlaneLab/blender/` as a local extension repository | — |
| T11 ARKit anchors + Mark | Done, device-checked on 2026-09-28 (`20260928-181436`: 2 planes, 373 anchor rows; "flawless"). Mark not yet tapped on a device | `32fb327`, `12a525c` |
| T10, T12–T26 | Not started. T21's ARKit-planes layer is already done (P17) | — |

The checks were green at `e90e034`:
- `swift test`: 68 tests in 10 suites.
- The iOS `xcodebuild` compile check: no new warnings. The AppIntents metadata notice is Xcode's own and pre-existing.
- `pytest`: 29 tests, 98 % coverage.
- `ruff`: clean.

## Waiting on the user

1. **T2 scrub check.** The user opens `~/PlaneLab/spikes/r2/r2_scrub.blend`, presses Numpad 0 to look through the camera, and scrubs and plays. They say whether it feels responsive.

## Next steps for Claude

In order:
1. ~~**T8: Blender extension and import (camera and raw points).**~~ Done.
   - Build the P6 layout: `PlaneLab/blender/planelab_blender/`, with `vendor/planelab` as a symlink to `src/planelab`.
   - Write `scripts/build_extension.sh`, which copies the real core into a staging folder and builds the zip.
   - Set up the local-repository dev loop.
   - Import: the scene fps is the **delivered** rate, `session.delivered_fps()`, not `video_fps` (§3.4). Convert ARKit to Blender axes as `(x, −z, y)`. Set lens, shift and resolution from the intrinsics. The raw-points layer comes from a frame-change handler. `event` rows become markers.
   - Headless smoke test on `session-format/fixtures/v1/tiny.planelab`.
2. ~~**T9: video behind the camera.**~~ Code and automated check done; The clip starts at timeline frame `1 + session.first_image_idx()`. Blender drops a leading gap and keeps later ones (§15 R2). The user then checks S11 on the T7 recording (`~/PlaneLab/sessions/20260928-160746.planelab`): the points sit on the image.
3. **Checkpoint 1:** the user reviews. Then comes Phase 2, with two parallel tracks:
   - **2A**, recorder, T10–T13: stop reasons and events, ARKit anchors, permissions and location, the Sessions sheet.
   - **2B**, lab core, T14–T20: synth, config, gate and accumulator, RANSAC, search, tracker, pipeline.

## Facts learned the hard way

Each one is also recorded where it belongs.

- **ARKit's rate on the iPhone 13 follows heat.** It promises 60 fps, delivered a flat 30 Hz at thermal *serious* (charging, spike runs) and a steady 60 Hz at *fair* (T7). Also in `CONSOLIDATION.md` §10b. `video_fps` is only a frame counter (PTS = `idx / 60`), and Blender's playback rate comes from `frame.t`. Re-check 60 Hz, heat and memory at Checkpoint 2A with an unplugged, cool phone and a 1-minute no-Rec baseline. (§3.4, §15 R1)
- **Blender drops a leading gap in the video but keeps later ones.** Place the clip at the first image. Random access costs about 50 ms of decoding; no proxies are needed. (§15 R2, `PlaneLab/spikes/README.md`)
- **Keyframes are capped at 30 encoded images, not 0.5 s of time.** Skipped images stretch the time between keyframes. (§3.4)
- **AVAssetReaderTrackOutput** reports media time in passthrough (it ignores the leading empty edit). When decoding, it applies the edit and adds an extra blank frame. `VideoProbe` handles both. (`ARKit_WallDetection/CLAUDE.md`)
- **SQLite:** `SessionDatabase.seal()` closes the database and deletes the stray `-shm` file, so a sealed session is one file. Empty BLOBs are bound with `sqlite3_bind_zeroblob`, never a nil pointer.
- **Xcode's generated Info.plist silently drops `UIFileSharingEnabled`.** It lives in `ARKit_WallDetection/SidingsAR-Info.plist`.
- **Finder's Files tab can't open an app's folders.** Pull files with `devicectl` instead (below).
- **Blender headless:** renders only follow `frame_set` on the *context* scene.
- **The first real recording** (`peek`): intrinsics drift with autofocus (fx 1524.0 → 1527.4); a feature id's position jitters about 2.5–3 cm RMS; startup lost images for frames 5–9 plus a 50 ms gap at frame 10. Warming the pool at Record is a T10 follow-up.
- **This Mac's locale uses a decimal comma.** Run `awk` over `ffprobe` output with `LC_ALL=C`.

## Working agreements (from the user)

- **Commits:** one per task once its checks are green, with the attribution trailer. Don't ask each time (P14). Never push, and never commit recordings. `*.planelab` is ignored except the contract fixture.
- **Decisions:** minor ones are Claude's to make, logged in `SPEC.md` §17.4 (P-rows) with a date and reason. Use AskUserQuestion for product, scope, device and field calls. The user asks for AskUserQuestion in every session.
- **Devices:** ask before installing. The user installs from Xcode. Reading files with `devicectl` is fine. Never report device results that weren't observed.
- **Spec reviews:** the user annotates `SPEC.md` inline (`USER_ANSWER`, `USER_QUESTION`, `Answer:`, `LAST QUESTION`). Answer each one, then fold it into the spec and remove the markers.
- **Docs change with the code:** the README of the part touched, the relevant `CLAUDE.md`, `SPEC.md` ticks and results, and `CONSOLIDATION.md` §10b for ARKit findings.
- **Notion:** offer to save findings to *LLM Session Memories* and save only on a yes. This session's page is "Plane Lab: spec approved, 26-task plan, and T1 …".
- **Global rules** (`~/.claude/CLAUDE.md`):
  - Python: a `.venv`, pinned requirements, ruff, strict type hints, frozen slotted dataclasses, `logging` with a silent log file.
  - Tests stay on disk.

## Commands

```bash
# Swift
cd ARKit_WallDetection/PlaneKit && swift test
xcodebuild -project ARKit_WallDetection/SidingsAR.xcodeproj -scheme SidingsAR \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Python
cd PlaneLab && source .venv/bin/activate
ruff check . && ruff format --check . && pytest --cov=planelab --cov-fail-under=85
python -m planelab info <bundle>

# Pull the newest recording from the iPhone 13 and open it in Blender (info, peek and blend included): PlaneLab/scripts/pull.sh
# (--list, <name>, --all, --no-open, --force; the manual devicectl steps are in the root README, "Recordings: phone → Mac")
# See everything in one: python -m planelab peek <bundle>  -> <bundle>/lab/peek.sqlite (decoded; _about explains columns)
# (iPhone 13 UDID 782F0FCC-0A00-5F6F-82AE-AC575194E5CA; a 13 Pro is also paired: `xcrun devicectl list devices`)

# Regenerate the contract fixture (only after a deliberate format change + schema_version bump)
cd ARKit_WallDetection/PlaneKit && PLANELAB_WRITE_FIXTURES=1 swift test --filter writeFixtures

# R2 spike
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 \
  --python PlaneLab/spikes/r2_video_alignment.py -- ~/PlaneLab/spikes/r2/spike.mov ~/PlaneLab/spikes/r2/spike_frames.json
```

Blender 5.0.1's `sys.executable` is `/Applications/Blender.app/Contents/Resources/5.0/python/bin/python3.11`. It runs the core standalone (numpy 1.26.4, `tomllib`).

## Outside the repo

| Path | What |
|---|---|
| `~/PlaneLab/spikes/r1/` | Both R1 runs from the iPhone 13 (`.mov` + `.json` with timelines) |
| `~/PlaneLab/spikes/r2/` | The R2 spike video, manifest, report and `r2_scrub.blend` |
| `~/PlaneLab/sessions/` | Real recordings on the Mac. `20260928-160746.planelab`: the T7 recording (48 s indoors, iPhone 13, 60 Hz) |
| `~/PlaneLab/logs/planelab.log` | Python log |
| `~/.claude/projects/-Volumes-512G-Developer-beam-sidings-poc/memory/` | Claude memories: working preferences |
| `ARKit_WallDetection/tasks/` | Earlier SidingsAR plan, with 48 unticked items from other work. Not touched by Plane Lab (P1) |
