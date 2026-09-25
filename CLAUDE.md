# CLAUDE.md: sidings_poc

Proofs of concept for the Siding Scanner. `README.md` has the repo map; `CONSOLIDATION.md` has the product and technical context. Read both before proposing anything architectural.

## Orientation

- **`CONSOLIDATION.md`** is the source of truth for decisions (D1–D7) and open questions. Don't contradict a decided item without flagging it. Add new native-ARKit findings to §10b.
- **`REQUEST.md`** holds the current request. Earlier requests (Original Request, Request 2) are archived in `docs/REQUEST_1.md`; they're history, so don't rework them unless asked.
- **`SPEC.md`** is the single file for the **Plane Lab** (SidingsAR recorder + Python core + Blender extension): spec, then plan (§17) and tasks (§18). For this work it replaces `tasks/plan.md` and `tasks/todo.md`. Don't write code for it until the spec phase is approved.
- **`ARFeaturePointFindSurface/`** is an upstream clone of CurvSurf's feature-point app, used as a reference. It has its own nested `.git`; see its `CLAUDE.md` for local patches and findings.
- **`ARKit_WallDetection/`** holds the only code so far: the SidingsAR iOS app plus the `PlaneKit` Swift package. Its own `CLAUDE.md` has the build and test commands, architecture invariants and memory rules. Follow it for any app change.
- `AR_APP.PNG` is the baseline screenshot. `BUILDING_SAMPLE.png` is the outdoor feature-point example the Plane Lab should reproduce (`SPEC.md` §1, *Reference assets*). `ARKit_WallDetection/legacy/` is the 2018 tutorial, kept for reference only.

## Workflow expectations

- **Planning:** non-trivial requests get a plan in `ARKit_WallDetection/tasks/plan.md` and tasks with acceptance criteria and device checkpoints in `tasks/todo.md`. Append new work; never overwrite unchecked tasks from other work without asking.
- **Tests:** pure logic lives in `PlaneKit` with Swift Testing cases that stay on disk. `swift test` must pass before a commit.
- **Device reality:** ARKit needs a physical iPhone. Verify with a build and unit tests, then hand the visual checks to the user. Never report device results that weren't observed. Ask before installing on a connected device.
- **Docs:** when a request is done, update `ARKit_WallDetection/README.md` (features, parameters, findings), the relevant `CLAUDE.md`, and `CONSOLIDATION.md` §10b if it changes what we know about ARKit.
- **Notion:** offer to save session findings to the *LLM Session Memories* page. Only save when the user says yes.
- **Git:** repo root is this directory, branch `main`, no remote yet. Commit when the user asks or approves, with the attribution trailer. Don't push, and don't re-create nested `.git` directories.

## Domain notes that shape the code

- Facade capture happens at an 8–15 m standoff. ARKit plane detection and LiDAR are reliable only to about 5 m, so the native-ARKit app is a baseline to measure, not the final pipeline.
- VIO pose is taken as given (D1). There's no calibration work (D2). Scale error doubles into area error.
- Store measurements relative to anchors, never as raw world coordinates, because relocalization shifts the world frame.
- Recessed openings (doors and windows 3–10 cm behind the wall plane) matter for takeoff. The current NMS distance gate (8 cm) can hide them; keep that in mind when tuning.
