# sidings_poc

Proofs of concept for the **Siding Scanner**: an on-device iOS/Android app that produces a siding takeoff (net wall area, linear feet of trim, opening counts) from a few minutes of AR capture around a house, with a calibrated margin of error. It's delivered on site instead of hours later.

Read [`CONSOLIDATION.md`](CONSOLIDATION.md) first. It holds the product framing, the decisions so far (D1–D7), the proposed geometry architecture, and the open questions.

## What's here

| Path | What it is |
|---|---|
| [`CONSOLIDATION.md`](CONSOLIDATION.md) | Living project summary: product, decisions, VIO notes, geometry architecture, MoE model, capture UX, first spike, evaluation, open questions |
| [`REQUEST.md`](REQUEST.md) | The current request. Earlier ones are in [`docs/REQUEST_1.md`](docs/REQUEST_1.md). |
| [`SPEC.md`](SPEC.md) | **Plane Lab**: record ARKit sessions in SidingsAR, then replay them and fit planes on the Mac in Python and Blender. Spec, plan (§17) and tasks (§18) in one file; approved 2026-09-28 and being built. |
| [`session-format/`](session-format/) | The recording format's contract: the canonical DDL and a Swift-written fixture that both Swift and Python test against. See its [README](session-format/README.md). |
| [`PlaneLab/`](PlaneLab/) | The Python side of Plane Lab: session reader and `planelab info` so far. See its [README](PlaneLab/README.md). |
| [`ARKit_WallDetection/`](ARKit_WallDetection/) | **SidingsAR**, an iOS app that validates what native ARKit plane detection gives us. See its [README](ARKit_WallDetection/README.md). |
| [`ARFeaturePointFindSurface/`](ARFeaturePointFindSurface/) | CurvSurf's feature-point surface-fitting demo (upstream clone, reference only). Our notes are in its [`CLAUDE.md`](ARFeaturePointFindSurface/CLAUDE.md). |
| `AR_APP.PNG` | A screenshot of the original tutorial app: the "dirty" baseline that motivated the rewrite |
| `BUILDING_SAMPLE.png` | ARFeaturePointFindSurface outdoors on an iPhone 13 (no LiDAR): 3,533 averaged points, including some 8–10 m up a building. It's the working example the Plane Lab should reproduce (see [`SPEC.md`](SPEC.md) §1). |

The research brief referenced by `CONSOLIDATION.md` (`research/01-landscape-brief-and-vio-handoff.md`) isn't in this repo.

## Current state (2026-09-28)

**SidingsAR v2.1** is a RealityKit app for iOS 18. It covers:
- vertical and horizontal `ARPlaneAnchor`s with classification
- Non-Maximum Suppression of duplicate planes, with hysteresis and EMA smoothing
- magenta anchor, center and boundary markers
- a feature-points debug view
- a live memory readout, plus a memory-savvy rendering pipeline

The user has tested it on device as "a great starter". Numbers (memory, LiDAR vs. non-LiDAR) are still to be recorded.

This is the native-ARKit baseline for **CONSOLIDATION D3**: measure what ARKit does for free before building the custom RANSAC and plane-hypothesis pipeline (§5 of the consolidation).

**Plane Lab** (`SPEC.md`) is in progress. Phase 0 answered both risks:
- The iPhone 13 records every delivered image without stutter. ARKit delivers about 30 Hz there, against a promised 60.
- Blender keeps the video in step, as long as the clip starts at the first frame with an image.

The recorder's core is built in PlaneKit (video writer, SQLite store, session writer), with a contract fixture. The Python reader reads that fixture. Next: recording on the phone (T7) and importing into Blender (T8–T9).

## Quick start

```bash
cd ARKit_WallDetection/PlaneKit && swift test        # unit tests on the Mac
open ../SidingsAR.xcodeproj                          # then run on a physical iPhone (no Simulator for ARKit)

cd PlaneLab && source .venv/bin/activate             # Plane Lab, Python side (setup in PlaneLab/README.md)
pytest --cov=planelab && python -m planelab info ../session-format/fixtures/v1/tiny.planelab
```

Requirements, usage and architecture are in [`ARKit_WallDetection/README.md`](ARKit_WallDetection/README.md).

## How work is organized

1. **The request:** a new numbered section is added to `REQUEST.md`.
2. **The plan:** for larger work, `ARKit_WallDetection/tasks/plan.md` (design decisions, risks) and `tasks/todo.md` (tasks, acceptance criteria, device checkpoints). Plane Lab is the exception: its plan and tasks are in `SPEC.md` §17–18.
3. **The build:** pure logic goes into the `PlaneKit` Swift package with tests; ARKit/RealityKit glue goes into the app.
4. **Device verification:** by the user on a physical iPhone. Results go into the app README's *Findings* and `CONSOLIDATION.md` §10b.
5. **Session findings:** saved to the Notion page *LLM Session Memories* when the user agrees.

## Repository

- Git root is this directory, branch `main`. The tutorial's original git history was dropped on import; upstream is [ambujpunn/ARKit_WallDetection](https://github.com/ambujpunn/ARKit_WallDetection).
- There's no remote configured yet.
