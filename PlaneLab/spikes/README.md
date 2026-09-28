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
