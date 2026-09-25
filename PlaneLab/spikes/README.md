# Plane Lab spikes

Throwaway experiments that answer a risk before real code depends on it (`SPEC.md` §15, §18 Phase 0). The scripts stay on disk so a result can be re-run. Their inputs and outputs live outside the repo, in `~/PlaneLab/spikes/<id>/`.

## R2: does Blender keep our video in step with the timeline? (T2, 2026-09-28)

**Question.** The recorder writes log frame `idx` at video time `idx / fps`, and a frame without an image leaves a gap (`SPEC.md` §3.4). Does Blender show image `idx` at timeline frame `idx + 1`?

**Input.** The T1 spike video, written by the real `VideoWriter`:

```bash
cd ARKit_WallDetection/PlaneKit
PLANELAB_SPIKE_OUT=$HOME/PlaneLab/spikes/r2 swift test --filter spikeVideo
```

It has 600 log frames at 1920 × 1440 and 60 fps, with 29 frames skipped: a **leading gap** (0–2), every frame where `idx % 37 == 5`, and a 10-frame hole (300–309). Each image carries its frame number as a 4 × 4 grid of black and white blocks.

**Run.**

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 \
  --python PlaneLab/spikes/r2_video_alignment.py -- \
  ~/PlaneLab/spikes/r2/spike.mov ~/PlaneLab/spikes/r2/spike_frames.json
```

The script renders 72 sampled frames through two paths, reads the blocks back, and writes `r2_report.json` and `r2_scrub.blend` next to the video:
- a MovieClip through the compositor, which is what a camera background uses
- a sequencer movie strip

The samples are the first 12 frames, the whole 298–312 stretch, every frame right after a gap, the last 5 frames, and 30 random ones.

**Result (Blender 5.0.1).**

| Path | Clip starts at timeline frame 1 | Clip starts at `1 + first image` (frame 4) |
|---|---|---|
| MovieClip (camera background) | 64 of 72 wrong: everything 3 frames early | **0 of 72 wrong** |
| Sequencer strip | 64 of 72 wrong | **0 of 72 wrong** |

- **Blender drops a leading gap.** Both readers report 597 frames, not 600, and put the first image (log frame 3) on the clip's first frame. FFmpeg's `start_time` (0.05 s here) is subtracted.
- **Gaps later in the file are kept.** Frames inside a gap hold the previous image, and the frame right after a gap shows the right image. No timecode index or proxy is needed.
- **Fix, in the importer:** `clip.frame_start = 1 + <first log frame with has_image = 1>`. The recorder doesn't need to change.
- **Seeking:** random access costs about 50 ms of decoding per frame on the MovieClip path, the same as in-order access. For the sequencer strip the cost was within noise. These are estimates: the colour-strip baseline (0.36 s of render and PNG work per frame) is subtracted from the measured time, so treat them as ±15 ms. Keyframes at most 30 images apart are enough.

**Still open:** the user scrubs `~/PlaneLab/spikes/r2/r2_scrub.blend` in the Blender UI.
- The file holds only `PhoneCamera`, whose background is the clip, placed at frame 4, and it opens looking through that camera.
- **The camera is static on purpose:** the spike video is synthetic block patterns with no poses. A camera that follows a recorded path comes with the real import (T8).
- To rewrite just this file, add `--scrub-only` to the run command.
- The first version of the file (2026-09-28) was saved from Blender's startup scene, so the default Cube, Light and Camera were still in it, with `PhoneCamera` inside the cube. That's fixed: the file now starts from an empty scene.

**Script gotcha:** in background mode, a render only follows `frame_set` on the *context* scene. Rendering another scene with `render(scene=…)` always gave the same frame, so the script reuses `bpy.context.scene` for every variant.

## `x1_vs_ransac/` (2026-10-01)

Evidence for the X1 verdict (`../../EXPERIMENTS.md`, *X1 verdict*):
- **`x1_tracks.py <recording>…`** describes X1's recorded tracks: kind, fate, lifetime, and their support in the final cloud.
- **`ransac_probe.py <recording>…`** is a quick sequential RANSAC with vertical/horizontal priors on the final averaged cloud. It's a probe, not T17.
- **`ransac_scene.py <recording>…`** draws the probe in Blender as `<recording>/lab/ransac_probe.blend`, leaving `replay.blend` alone. Run it from inside `spikes/x1_vs_ransac/`. The file holds:
  - the final cloud, coloured by probe plane (grey: in none), with each plane in its own collection holding its points and a translucent 2–98 % extent rectangle;
  - X1's final planes;
  - the camera path.

  It needs no add-on. Hide the `H` (horizontal) collections and look from the top (Numpad 7) to see one facade come out as 3–4 parallel slices, 30–40 cm apart.
- **`ransac_replay.py <recording>… [--every 10]`** puts the probe over the video replay, as `<recording>/lab/ransac_replay.blend`. The file holds:
  - the normal Plane Lab import (camera, video, raw points, ARKit and X1 layers), with the averaged cloud hidden because the probe recolours the same points;
  - the probe run on the cloud as it was every 10 s of timeline. Each checkpoint is a collection, visible from its frame to the next one through keyframes, with each plane's screen-sized points and translucent extent rectangle. Vertical planes are warm colours and horizontal ones cool.

  Look through the camera (Numpad 0) and play. It needs the Plane Lab extension enabled for the video and the per-frame layers.

Both read `~/PlaneLab/sessions/`.
- **`export_cloud.py` + `ransac_bench.swift`** time the probe's search in compiled Swift on a real cloud: the fixed budget, adaptive k, local pairs, and top 3 planes. That's the measurement behind *Is RANSAC real-time?* in `../../EXPERIMENTS.md`, X2.
