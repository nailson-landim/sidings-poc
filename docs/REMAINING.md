# Plane Lab: what's left

*Snapshot of 2026-10-01, taken from `SPEC.md` §18 and `HANDOFF.md`. Full detail and acceptance criteria are in `SPEC.md`. The resume prompt for the build is `FITTING_PLAN_RESUME.md`.*

The recorder side (the iOS app and PlaneKit) is closed.

## Build, in order (not started)

| # | Task | What it is | Gate |
|---|---|---|---|
| 1 | T17 | RANSAC plane models (vertical, horizontal, free), least-squares refit, range-scaled τ, collinear rejection | S8 |
| 2 | T18 | Sequential search and extents (convex hull split into regions) | S8 |
| 3 | T19 | Plane tracker: match, merge, stale. A recess 10 cm behind the wall stays separate; one 5 cm behind merges at 8 cm | S8 |
| 4 | T20 | Pipeline, `lab/<run>/results.sqlite`, `planelab run` and `export --csv` | S9: 2-min session in < 60 s |
| 5 | Checkpoint 2B | The automated part | — |
| 6 | T21 | Blender: our planes layer, per-frame readouts, cloud from a run (the ARKit-planes and averaged-cloud layers are done) | S12: ≤ 100 ms per frame change |
| 7 | T22 | Blender: settings panel, TOML, Recompute with Cancel, run picker, Export CSV | S13 |
| 8 | T23 | Blender: the remaining operators and the all-operators headless test | S10 |
| 9 | Checkpoint 3 | The automated part | — |
| 10 | T26 | Docs pass | — |

## Linux box (NVIDIA)

- **T33:** COLMAP with CUDA on the stills from `20260930-174033`. Not started. See `PACK.md`.

## Waiting on the user (doesn't block the build)

- **T2:** scrub check in `~/PlaneLab/spikes/r2/r2_scrub.blend`.
- **P27:** Pick Point check in `20260930-102759`'s `replay.blend`.
- **T24:** E2 per wall and E3 by eye on `20260929-172952` and `20260930-102759`, once T21 shows our planes.
- **T25:** record the far (open-standoff) site.
- **Final checkpoint:** S1–S14 and sign-off.

## Not to be done (closed or deferred)

T10–T13, Checkpoint 2A and GPS (L9).
