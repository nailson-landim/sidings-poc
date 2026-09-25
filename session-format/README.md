# session-format

The on-disk contract between the SidingsAR recorder (Swift) and Plane Lab (Python). The full definition is in `../SPEC.md` §3: the bundle layout, the conventions, every table and the video rules. This folder holds the two artifacts both sides test against.

| File | What it is |
|---|---|
| `schema_v4.sql` | **The one source of the DDL** (SPEC §17.4 P2), schema version 4: version 3 plus the `surface_round` table, what each round of the phone's plane engine cost (`../EXPERIMENTS.md` XD16). Swift (`SessionSchema.ddl` in PlaneKit) and Python (`planelab.schema.DDL`) embed copies, and a test on each side checks the copy matches this file exactly. |
| `schema_v3.sql`, `schema_v2.sql`, `schema_v1.sql` | Versions 3 (v2 plus the `surface` table, the phone's tracked planes, XD6), 2 (v1 plus the `cloud` table, SPEC L12, P23) and 1, kept for reference. Both readers still open version 1 to 3 files. |
| `fixtures/v4/tiny.planelab/` | A 10-frame session written by the real Swift writer: a sealed `session.sqlite` and a 256 × 192 HEVC `video.mov`. |
| `fixtures/v4/expected.json` | What the fixture must decode to, table by table. |
| `fixtures/v1/` to `fixtures/v3/` | The version 1 to 3 fixtures and their `expected.json`, kept to prove old recordings stay readable. |
| `fixtures/cloud/recorded.planelab/` | The golden frames recorded by the real Swift path (`SessionWriter` + `LiveCloud`, SPEC T30), with its `cloud` rows and `const.cloud*` meta. Plane Lab's recompute must equal it (`planelab info --check-cloud`). Regenerate with `PLANELAB_WRITE_FIXTURES=1 swift test --filter writeRecordedCloudFixture`; a Swift test keeps it current. |
| `fixtures/cloud/golden.json` | Frames and the averaged cloud Plane Lab's accumulator builds from them under five settings (SPEC T27). The Swift port (`FeatureAccumulator`) must give the same ids and sample counts, and positions within 2e-6 m. Written by `PlaneLab/scripts/cloud_golden.py`; a Python test keeps it current. |

## The fixture

It exercises the cases a reader can get wrong:
- **Frame 0 has no points.** Its `points` and `point_ids` are zero-length BLOBs, never NULL.
- **Frames 0, 4 and 7 have no image** (`has_image = 0`). The video therefore starts with a gap, stored as an empty edit that Blender ignores (SPEC §3.4, §15 R2).
- **Frame 9's point ids are above 2^53.** Read them as uint64, never through float64.
- **Camera matrices alternate identity and a quarter turn about Y,** with a translation in column 3, so a transposed or row-major reader fails.
- **One anchor is added, updated and removed; another is only added.** A `remove` row carries only the id.
- **Every other table has rows:** two location fixes, two headings (one with `true_deg = -1`, meaning invalid) and six events.
- **Two `cloud` rows (v2):** a full copy after frame 5, then changes after frame 9 that remove one id and set one kept id plus an id above 2^53 with a sample count of 300 (above a byte).
- **Seven `surface` rows (v3):**
  - Track #1 is added tentative at frame 3, grows confirmed at frame 6 (a 5-vertex outline), and goes stale at frame 8.
  - Track #2 is added at frame 4 and removed at frame 7, with `merged_into` naming #1.
  - Track #3, a floor, is added at frame 8 and dropped at frame 9: a remove with `merged_into` NULL.
  - Remove rows carry only the id and number.
- **Three `surface_round` rows (v4):** a first round that searched, a refit-only round, and a third that searched with the phone at thermal `serious`. The third has 3,000,000,000 points, above int32. Milliseconds are dyadic fractions.
- **Float32 values are dyadic fractions,** so decimal ↔ float32 conversions are exact in every language.

Every video frame shows its own log frame number as a 4 × 4 grid of black and white blocks (SPEC §17.4 P4). Block `i`, counted row-major from the top left, is white when bit `i` is set.

## `expected.json` layout

- **Tables:** one key per table. Each row is an object whose keys are the SQL column names.
- **BLOBs:**
  - matrices are flat column-major float lists (16 values for `camera` and `transform`, 9 for `intrinsics`)
  - `center` and `extent` are 3-float lists
  - point lists are lists of `[x, y, z]`
  - `point_ids`, `removed_ids` and `ids` are integers; `samples` are integers
- **NULL columns are left out** of the row object. That applies to a `remove` row's geometry, so read them as missing = NULL.
- **`meta`** is a string-to-string object.

## Regenerating

Only after a deliberate format change, which also bumps `schema_version` (SPEC §3.5):

```bash
cd ARKit_WallDetection/PlaneKit
PLANELAB_WRITE_FIXTURES=1 swift test --filter writeFixtures
swift test        # the committed fixture must decode to expected.json again
```

This rewrites `fixtures/v4/`; `fixtures/v1/` to `fixtures/v3/` are never regenerated. Then commit both files together, and make sure the Python contract test passes too.
