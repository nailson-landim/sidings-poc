Resume the Plane Lab build and implement everything still open, autonomously, task by task, until it's done. I'm around: ask me with AskUserQuestion whenever a call is mine (product, scope, anything you  can't verify). Otherwise keep going.                                                                                                                                                                      READ FIRST                                                                                           - HANDOFF.md: state, working agreements, facts learned the hard way.                                - SPEC.md §0, §5, §6, §13, §17.4 (P-rows up to P28) and §18 (tick state). - The CLAUDE.md files (root and ARKit_WallDetection/) and PlaneLab/README.md.                       
SCOPE (agreed 2026-09-30, SPEC P28), in this order
1. Lab core:
   - T17: RANSAC models (vertical 2-pt, horizontal 1-pt, free 3-pt), least-squares refit, τ = τ₀ +
k·z², rejection of near-collinear inliers.
   - T18: sequential search (edge_keep_m) and extents (convex hull split into connected regions).
   - T19: plane tracker (match, EMA or refit, tentative → confirmed, merge where the older id
survives, stale, add/update/merge/stale events). A recessed opening 10 cm behind the wall stays
separate; one 5 cm behind merges at 8 cm.
   - T20: pipeline, lab/<run>/results.sqlite (config table, per-frame readouts, planes and events,
cloud snapshots), `run --progress`, `export --csv`.
   - Then the automated part of Checkpoint 2B.
2. Blender, the full spec (S10 stays):
   - T21: our planes layer (colored by track id; tentative lighter, stale grey; labels), per-framereadouts and session info in the Plane Lab tab, and the cloud layer from a run's results.sqlite. S12: ≤ 100 ms per frame change.                                                                               - T22: settings panel generated from LabConfig, TOML load/save, Recompute as a subprocess with     Blender's Python (progress, Cancel within 1 s, new run shown without a restart), run picker, Export   CSV.   - T23: File > New > Plane Lab Synthetic Session, add-on preferences (sessions folder), sessionbrowser, layer toggles, peek button, and the headless test that drives every bpy.ops.planelab.*operator.   - Then the automated part of Checkpoint 3.
3. T26 docs pass.                                                                                 

DON'T TOUCH (closed or deferred): T10–T13, Checkpoint 2A, GPS (L9). The recorder is closed, so noSwift changes unless a task truly needs one.
RULES
- P28: a run fits the phone's recorded cloud when its filter/gate/accumulate settings equal therecording's const.cloud*. Any other settings recompute on the Mac.- S9: a 2-minute session runs in under 60 s. Time it on the real recordings~/PlaneLab/sessions/20260930-102759.planelab (116 s, 10,470 cloud points) and20260929-172952.planelab, and run `run` + `export` on them as a sanity check. If fitting is too slow, refit only when the cloud has changed enough; don't lower the rate.                                   - Every task:                                                                                           - tests on disk (pytest; Blender headless through tests/test_blender.py)                              - ruff check and ruff format --check                                                                  - pytest --cov=planelab --cov-fail-under=85
  - ruff check and ruff format --check
  - pytest --cov=planelab --cov-fail-under=85
  - tick §18, and log minor decisions as P-rows (P29 and up) with date and reason
  - update PlaneLab/README.md and HANDOFF.md
  - one commit per task with the attribution trailer. Never push, never commit recordings.
- Minor calls are yours if logged. Never report a result you didn't observe. GUI and by-eye checks go under HANDOFF "Waiting on the user".

MY CHECKS (don't block on them): P27 pick check, T2 scrub check, T24 E2/E3 by eye once our planes show (recordings 20260929-172952 and 20260930-102759), T25 far-site recording.

WHEN DONE: a short report of what shipped, the numbers (S8, S9, S12), and what's waiting on me. Then offer to save the findings to Notion.