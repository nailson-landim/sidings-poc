# Experiments: plane fitting on ARKit feature points

*Registered 2026-10-01. Two ways to turn the averaged feature-point cloud (`SPEC.md` L12) into stable, tracked planes for facade takeoff at 8–15 m. Each experiment runs on its own branch and is compared with the other on the same sites.*

| ID | Fitter | Tracking | Runs on | Branch | Status |
|---|---|---|---|---|---|
| **X1** | CurvSurf **FindSurface** (proprietary binary) | Ours: tracked and updated across rounds | **Live on the phone** (SidingsAR) | `exp/x1-findsurface-live` | Built and run (X1.1–X1.4). **Verdict 2026-10-01: a baseline, not the pipeline** (see *X1 verdict*) |
| **X2** | **Our RANSAC** (design below) | X1's tracker, extended | **Live on the phone** (SidingsAR), replayed in Blender | `exp/x2-ransac` (from `exp/x1-findsurface-live`) | **Built 2026-10-02 (X2.1–X2.6), not merged, kept for history** (XD14–XD18). Swift only, so `SPEC.md` T17–T20 (the Python port) stay open on `main`. Device checks wait for the user (*X2 on the phone*). |
| **X3** | **Image-based geometry** (plan: `ARKit_WallDetection/tasks/plan.md`, *Experiment X3*) | Stills and video with the ARKit poses frozen (D1), then masks back-projected onto the walls | Offline first (Linux box for COLMAP, Plane Lab for the rest) | `exp/x3-image-geometry` (not created yet; branch from `main`) | **Planned 2026-10-02 (XD19).** Starts with a ground-truth facade. Nothing built. |

The IDs are X1 and X2 because `SPEC.md` already uses E1–E3 for field experiments.

## Why two experiments

CurvSurf's app (`ARFeaturePointFindSurface/`) fits a plane where you aim, from scratch every frame. Nothing links one frame's result to the next, so the preview **flickers by design** and nothing persists until Capture (`ARFeaturePointFindSurface/CLAUDE.md`). Its fitter is good; its use of the fitter isn't what we need. The question is which fitter to put under a tracker that keeps every wall stable:
- **X1** keeps CurvSurf's fitter and adds what its app lacks: automatic seeds and tracking.
- **X2** is fully ours and open, as `SPEC.md` already plans.

## X1: FindSurface + tracking, live on the phone

**Hypothesis.** FindSurface's seeded fitting (region growing plus least squares on orthogonal distances; `ARFeaturePointFindSurface/CLAUDE.md`), run on the phone's live averaged cloud with automatic seeds and a tracker, gives every visible wall one stable plane that updates as more points arrive, with no flicker, at 60 fps.

**What CurvSurf's library gives.**
- **Input:** a point cloud, a seed point index and a seed radius.
- **Output:** one bounded plane (4 corners, normal, center), the inlier flags and the RMS error.
- **Parameters:** `measurementAccuracy`, `meanDistance`, `lateralExtension` and `radialExpansion` (lv0–10).
- **Limits:** iOS only, as an xcframework; no macOS build, so nothing that calls it runs in `swift test`. Free for non-commercial use, capped at 500k points.

**Design (agreed 2026-10-01).**
1. **Rounds.** On a background queue, a few times a second (`roundInterval`), take the latest live cloud and upload it to FindSurface once.
2. **Re-seed tracked planes first.** Each tracked plane is refitted from its own region. The seed is its inlier feature id that is still in the cloud and closest to its center. The seed radius comes from the plane's extent. This is the "keep it updated" part.
3. **Discover new planes with automatic seeds.** Among the points no plane has claimed and that have enough samples, pick seeds from the flattest cells of a 0.5 m grid, then the densest, then the nearest. Flattest, because a cell where two walls meet is dense but not flat, and a seed there fits a plane across the corner (found in the X1.1 tests). Only discovery starts tracks; a refit that wanders off its own surface counts as a miss. Fit, claim the inliers, and repeat up to `maxNewPerRound`. The seed radius scales with range (`seedRadiusPerMetre × range`, clamped), which matches CurvSurf's default on-screen circle (about 0.2 × depth).
4. **Tracker.** A fit is matched to a track by **shared inlier feature ids**: ARKit's feature ids are stable, so this is a much stronger key than geometry alone. The normal angle and plane distance act as gates. There are three possible updates:
   - **Matched:** the plane is updated by EMA on its normal and offset, and its extent becomes the convex hull of the inliers on the plane.
   - **Tentative to confirmed:** a track becomes confirmed after `confirmHits` matches.
   - **Merge and stale:** two confirmed tracks on the same surface merge, and the older id survives, with the same terms as PlaneKit's NMS (10°, 8 cm, 0.3 overlap). A track not seen for `staleRounds` rounds goes stale; it's kept but drawn grey.

   It emits `add` / `update` / `merge` / `stale` events, like `SPEC.md` §5.2.
5. **Display.** One fill per track, colored by track id. Tentative tracks are lighter and stale ones grey. Labels show W × H and the RMS error. A Debug-menu toggle turns it on and off, with HUD readouts for planes and fit time.

6. **Recording** (XD6). While recording, the tracks that changed in each round go into the session's `surface` table, so Plane Lab and Blender replay X1 frame by frame.

**Where the code goes.** The tracker, seeds and round logic are pure Swift in PlaneKit (`Surfaces/`), behind a `SurfaceFitter` protocol. They're tested on the Mac with a stand-in fitter. The FindSurface adapter and the rendering live in SidingsAR, the only place that imports `FindSurfaceFramework`.

**Starting values.**
- **v1** (CurvSurf's demo app): `measurementAccuracy` 0.10 m, `meanDistance` 0.50 m, `lateralExtension` and `radialExpansion` lv5, seed radius 0.2 × range clamped to 0.15–3 m.
- **v2** (2026-10-01): see *X1 dials* below.

**Measured** (device, by the user; never reported unless observed):
- **Stability:** one id per wall for as long as the wall is in view; id switches per minute; whether planes visibly flicker.
- **Coverage:** walls found out of the walls in view, at 2–5 m indoors and 8–15 m on a facade (the T24 building).
- **Geometry:** the RMS error per plane, and the angle between two walls at a corner (near 90°).
- **Recesses:** a window or door 5–10 cm behind the wall stays a separate plane (`CLAUDE.md` domain note).
- **Cost:** fit ms per round, HUD fps (should stay at 60) and *mem MB*.

**Success** = stable ids with no visible flicker, every facade wall in view found at 8–15 m, corners within a few degrees of 90°, and 60 fps kept.

**Caveat.** FindSurface's binaries are free for non-commercial use only. Using X1 in the product needs a commercial license from CurvSurf (support@curvsurf.com), so a "go" on X1 also means a licensing conversation.

**Progress** (`ARKit_WallDetection/tasks/todo.md`, *Experiment X1*):
- **X1.1** (2026-10-01): the PlaneKit core in `Surfaces/`, with 31 Mac tests on a least-squares stand-in. A corner gives two stable planes 90° apart over 50 rounds of fresh noise. A window 10 cm deep stays its own plane; one 5 cm deep joins the wall. A strip along one edge gives no plane. Lesson: seeding the *densest* cells put seeds on corners and fitted planes across them, so seeds now take the flattest cells first.
- **X1.2** (2026-10-01): FindSurface in SidingsAR (`FindSurfaceFitter`, `SurfaceRenderer`, Debug toggles, HUD). It builds, and the framework is embedded. **Nothing has run on a phone yet.**
- **X1.3** (2026-10-01): X1's tracks go into recordings (schema v3 `surface` table, XD6–XD7), and Plane Lab reads them:
  - `planelab info` gets an `x1` line and `peek` an `x1_surfaces` table.
  - Blender gets an **X1 FindSurface planes** layer that follows the timeline in the phone's colors.
  - A Swift test records rounds through the real `SessionWriter` and checks the rows replay to exactly the phone's final tracks. The headless Blender test checks every frame of the contract fixture.
- **First facade run** (2026-10-01, `20261001-115808`, by the user): the wall found and confirmed at about 7 m, RMS 6.6 cm, but it stopped at 7.67 × 5.35 m. "Not bad for a non-LiDAR phone, but I think we could get more."
- **X1.4** (2026-10-01): the v2 defaults, the live dials and the tracker's merge gap (*X1 dials*, XD8–XD10). `swift test` (163) and the compile check pass. **Not yet run on the phone.**

### X1 dials: tuning on the phone (v2, 2026-10-01)

**What the first facade recording showed** (`20261001-115808`, 66 s, iPhone 13, the T24-style building; read from its `surface` rows). The user pointed at frame 2517: the plane covered only the middle of the wall. At that frame X1 had two confirmed tracks:

| Track | What | Size | RMS | Inliers | Range |
|---|---|---|---|---|---|
| #1 | the ground (normal within 1° of vertical) | 7.6 × 9.6 m | 3.5 cm | 2,224 | 1.8 m below the camera |
| #2 | **the wall** (vertical within about 4°) | **7.67 × 5.35 m** | 6.6 cm | 852 | about 7 m |

- The wall track is right in orientation and position. What's short is its **extent**: it stopped growing at about frame 2000 and stayed 7.67 × 5.35 m to the end, while the cloud grew from 5,000 to 6,800 points.
- It looks grey in Blender because blue at 40 % opacity over the grey façade reads grey. It wasn't stale.
- The user's verdict: "quite similar to the fitted plane ARKit gets purely on LiDAR. Not bad for a non-LiDAR phone, but I think we could get more." A rough measure is enough for the POC.

**Why it stopped: the suspects, one per dial.**
- **The plain painted wall gives few feature points, the AC units and pipes many.** The wall's points are sparse at 7 m, and FindSurface rejects inlier regions sparser than `meanDistance` allows (0.50 m in v1).
- **FindSurface's `lateralExtension` (lv5)** limits how far a fit spreads along the surface.
- **The refit's seed radius**, half the plane's size, was capped at 3 m (`seedRadiusMax`).
- **The tracker shed real wall points.** It kept earlier inliers only within 5 cm of the plane (`keepBand`), with 6.6 cm of RMS at that range.
- **Pieces of one wall that don't overlap never joined.** Matching and merging needed overlap or shared ids, so a patch found next to the wall stayed a separate track.

**The dials.** *Debug › X1 dials* in SidingsAR changes them live. A change applies from the next round on and keeps the tracks; *Restart X1* forgets the planes so a wall is found afresh with the current dials. While recording, each change is an `x1_dial` event (`lateralExtension 7→9`, a timeline marker in Blender), and the `x1.*` meta keeps the values at Record.

| Dial | Belongs to | What it does | v1 | **v2** | Menu values | Raise it when | Lower it when / risk |
|---|---|---|---|---|---|---|---|
| Lateral extension | FindSurface | How far a fit spreads along the surface (lv0–10) | 5 | **7** | 3, 5, 7, 9, 10 | A wall stops short of its edges | It spreads past a corner or onto a coplanar neighbour |
| Radial expansion | FindSurface | How thick its inlier band is (lv0–10) | 5 | 5 | 3, 5, 7, 9 | Far walls lose noisy points | It swallows things in front of the wall (AC units 30–60 cm out) |
| Measurement accuracy | FindSurface | The a priori RMS of the points; also our RMS limit (× 1.5) | 0.10 m | 0.10 m | 5, 10, 15, 20 cm | Fits at 10–15 m are rejected for RMS | Planes absorb nearby surfaces |
| Mean distance | FindSurface | The point spacing it expects; sparser inlier regions are rejected | 0.50 m | **1.0 m** | 0.25, 0.5, 1, 2 m | Sparse plain walls don't extend | Fits bridge gaps between separate surfaces |
| Seed radius max | ours | Caps a seed's radius; a refit seeds with half the plane's size | 3 m | **6 m** | 3, 6, 10 m | Big walls don't reach their size | A seed region spans two surfaces |
| Keep band | ours | Earlier inliers stay with a track while this close to its plane | 0.05 m | **0.15 m** | 5, 10, 15, 25 cm | The outline shrinks or flickers between rounds | Points in front of the wall cling to it |
| Merge gap | ours (new) | Coplanar pieces this close match or merge | – (0) | **0.5 m** | off, 0.25, 0.5, 1 m | One wall stays split into pieces | Two separate coplanar walls join |

**How the tracker changed** (v2, also in the code):
- **Merge gap.** A fit or track whose outline lies within `mergeGap` of another's, on the same plane, now matches or merges like an overlapping one.
- **Coplanar test.** "Same plane" now measures the offset along the two planes' *mean* normal. With each plane's own normal, two patches of one wall 6 m apart that disagree by 1° read as 10 cm apart.

The angle (10°) and offset (8 cm) gates are unchanged, so a window 10 cm deep still stays separate.

**On-site protocol** (Checkpoint X1 in `ARKit_WallDetection/tasks/todo.md`):
1. Install the v2 build, stand where you stood for `20261001-115808`, tap **Record** and sweep the facade as before.
2. Note the wall's label (W × H, RMS) and the HUD's **fit ms**.
3. Change **one dial**, tap **Restart X1**, and sweep again. Use **Mark** before each sweep so the markers line up with the `x1_dial` events.
4. Try them in this order, the most likely limiter first:
   - mean distance 1 → 2 m;
   - lateral extension 7 → 9 → 10;
   - keep band 0.15 → 0.25 m;
   - radial expansion 5 → 7, watching the AC units;
   - merge gap 0.5 → 1 m.
5. Stop, `pull.sh`, and compare the sweeps in Blender with the timeline markers. The best set becomes v3.

### X1 verdict (2026-10-01): a useful baseline, not the pipeline

**Runs judged:** `20261001-142809` (147 s, 60 fps, points out to 22 m) and `20261001-143156` (94 s; ARKit delivered 30 fps, likely heat), both with the v2 dials and no changes. Read with `PlaneLab/spikes/x1_vs_ransac/x1_tracks.py`, and set against a quick RANSAC probe on the same final clouds (`ransac_probe.py`, below). The user's view: "somehow promising but … far, very far from what I need".

**What X1 does well:**
- It finds the **ground** (RMS about 4 cm) and the **main facade** within seconds and keeps each under one id for the whole run. In `142809`, #1 and #2 were alive 103 s over 340+ rows each, with no id switches.
- The v2 dials worked: the facade grew to **18.3 × 8.5 m** (v1 stopped at 7.7 × 5.4 m), within 0.4° of vertical, RMS 6.5 cm at about 6 m.

**Why it's far from enough:**

1. **Slanted false planes.** FindSurface fits planes of any orientation, and we can't give it a vertical/horizontal prior.
   - `142809` ends with 6 tracks: ground, facade, a parallel plane 2 m behind (plausible), and **3 tilted 16–39° from vertical** (one 17.5 × 6.6 m).
   - `143156` ends with 7: ground, facade, and **5 tilted 8–58°**. Three of those are one nearby wall fitted three times, at 8°, 20° and 30°. The probe finds it as a single vertical plane with 2 cm RMS.
2. **Churn.** 13 of 22 and 13 of 20 tracks lived 1–8 s, many of them 10–20 m wide: big phantom planes flash on and off between 4,000 and 5,200 frames.
3. **Loose extents.** The facade's track measures 18.3 × 8.5 m, but the cloud within 15 cm of its plane spans 14.5 × 4.6 m (2–98 %). That's **about 2.3× the area**, because a convex hull follows its most stray inliers. This part is our extent method and fixable in either approach.
4. **We can't fix it inside.** It's a closed binary: no orientation prior, the inlier band in "levels" rather than metres, no range-dependent noise model, and no way to see why a fit fails. It's iOS and Linux only (no Mac testing) and non-commercial.

**The RANSAC probe** (scratch numpy, not T17; about 5 s per recording, untuned):
- **Orientation:** every plane is exactly vertical or horizontal, with no slanted planes in any of the three recordings. It finds the same facade as X1 (`142809`, within 1°) and the nearby wall X1 fitted three times (`143156`).
- **It exposes the data's real limit:** at 4–7 m each surface is a **slab about 30–40 cm thick** (the needle-shaped depth error of the averaged points). With a thin band (4 cm + 0.12 cm/m² × range²), RANSAC cuts it into parallel slices:
  - the facade in `142809` came out as 4 planes, offsets −3.50 to −3.87 m;
  - the ground came out as 3, offsets −1.45 to −1.61 m.

  A rough measure needs a band about three times wider at range, or merging parallel slices (the tracker's job). That's T17/T19 tuning, not a blocker. The same limit applies to X1: from this phone's cloud, a plane's offset is good to ±15–20 cm at 4–7 m. For area, the extents matter more.

**Recommendation:** stop tuning X1 and keep it as the baseline. Move to X2 (RANSAC, `SPEC.md` T17 onward), carrying over what X1 taught:
- **Priors:** vertical and horizontal models, with free planes off.
- **Inlier band:** range-scaled and wider than SPEC's 3 cm starting value at range, or slices merged.
- **The tracker's ideas:** match by shared inlier feature ids, merge within a gap, measure the coplanar offset along the mean normal (XD5, XD10).
- **Robust extents:** trimmed percentiles or an occupancy grid instead of a raw convex hull.
- **Comparison:** the same recordings, so X1's recorded planes stay in Blender to compare against.

**X2 must beat X1 on `115808`, `142809` and `143156`:**
- no slanted planes;
- at most one track per real wall;
- each facade's extent within about 20 % of where its points are;
- stable ids.

## X2: our RANSAC + tracking, offline in Plane Lab

**Hypothesis.** Sequential RANSAC with vertical and horizontal priors, a range-scaled inlier band and collinear rejection, followed by a least-squares refit and our tracker, finds the same walls as X1 or more, with stable ids. Being open, it can be tuned and ported to PlaneKit (L1).

**Design:** `SPEC.md` §5.1 (stages 5–6) and §5.2, tasks T17 → T18 → T19 → T20, then the Blender layers T21–T23. It runs offline on recordings, on the Mac or the Linux box, and is built to port to PlaneKit later (L1). Refined on 2026-10-01 by what X1 and the probe showed (XD12):

1. **Models with priors.** Vertical (2-point sample) and horizontal (1-point); free planes off (SPEC already says so). X1's tilted planes are what free orientation gives on this data.
2. **Local sampling (Efficient-RANSAC style, NAPSAC).** The second point of a vertical sample is drawn near the first, through a grid or octree, because walls are local. **Scoring is lazy:** a hypothesis is scored on a random subset first, and the whole cloud only if it could still win.
3. **PROSAC ordering by sample count.** Each averaged point already carries how many sightings it averages (the red, magenta and pink bands). Sample the well-observed points first and widen gradually.
4. **MSAC scoring with a per-point noise level.**
   - Inliers count by closeness (truncated quadratic), not just in or out.
   - The band grows with range (`τ = τ₀ + k·z²`), and **at range it's about three times SPEC's 3 cm starting value**: each surface is a 30–40 cm slab at 4–7 m (*X1 verdict*).
   - A refinement to try: the error runs mostly along the camera-to-point ray (needle-shaped), so a point's band can shrink with how parallel its ray is to the plane.
5. **Degenerate samples rejected.** Collinear support, an edge seen alone (SPEC's existing rule, DEGENSAC-like).
6. **LO refinement.** A few least-squares refits on the winner's inliers, not one.
7. **Connected pieces (T18).** Each plane's inliers are split into connected regions on the plane, using an occupancy grid with Efficient RANSAC's "largest connected component" idea. This fixes the probe's slices that collected coplanar points 20 m away (its 26.7 m "walls").
8. **Robust extents.** Trimmed percentiles or the occupied grid cells, never the raw convex hull. X1's hull overstated the facade's area about 2.3×.
9. **Slices merged.** Parallel planes within about 30 cm of each other, with overlapping or adjacent pieces, become one plane: in the search, or in the tracker's merge. *Trade-off:* a window recessed 10 cm can't be resolved at this range anyway; closer in, the range-scaled band keeps it separate.
10. **Tracker (T19) built on X1's** (XD5, XD10). Match by shared inlier feature ids, merge coplanar pieces within a gap, measure "coplanar" along the mean normal, and use tentative → confirmed → stale states.
11. **Incremental, for speed.** Each round refits the tracked planes locally (O(their inliers)), and runs the full search only on unclaimed points, only when the cloud has changed enough (`FITTING_PLAN_RESUME.md`).

**RANSAC variants considered** (2026-10-01; what each would mean here):

| Step | Variant | What it changes | Here |
|---|---|---|---|
| Sampling | **NAPSAC** (Myatt et al., 2002) | Draws the other sample points near the first | **Used** (2) |
| Sampling | **PROSAC** (Chum & Matas, 2005) | Best-quality points first, then gradually uniform | **Used**, by sample count (3) |
| Sampling, scoring, regions | **Efficient RANSAC** (Schnabel, Wahl & Klein, 2007; in CGAL) | Octree-local sampling, lazy scoring, largest connected component | **The skeleton** (2, 7) |
| Scoring | **MSAC / MLESAC** (Torr & Zisserman, 2000) | Graded inlier cost; likelihood | **MSAC used** (4) |
| Scoring | **MAGSAC / MAGSAC++** (Barath et al., 2019–20) | Averages over the noise level instead of a fixed threshold | Candidate if the per-point band isn't enough |
| Scoring | **R-RANSAC T(d,d), SPRT/WaldSAC** (Matas & Chum, 2004–08) | Drops bad hypotheses after a few points | Covered by lazy scoring (2); SPRT if more speed is needed |
| Scoring | **Preemptive RANSAC** (Nistér, 2003) | Fixed hypothesis set scored on growing point blocks | Option for a hard per-frame time budget on the phone |
| Scoring | **AC-RANSAC / ORSA** (Moisan et al., 2004–12) | Picks the threshold automatically | Not needed while the range model holds |
| Refinement | **LO-RANSAC** (Chum, Matas & Kittler, 2003) | Iterated refits on the best inliers | **Used** (6) |
| Refinement | **GC-RANSAC** (Barath & Matas, 2018) | Graph cut for spatially coherent inliers | Candidate if connected pieces (7) aren't enough |
| Refinement | **DEGENSAC** (Chum et al., 2005) | Detects degenerate samples | **Used** as collinear rejection (5) |
| Many models | **Sequential RANSAC** | Find, remove, repeat | The base. It slices thick surfaces, hence (9) |
| Many models | **J-linkage / T-linkage** (Toldo & Fusiello, 2008; Magri & Fusiello, 2014) | Clusters points by the hypotheses they agree with | Too slow for 10k points per round |
| Many models | **PEARL, Multi-X, Progressive-X** (Isack & Boykov, 2012; Barath & Matas, 2018–19) | Global energy with a cost per extra model | Candidate to replace slice merging (9) if that's fragile |
| Not RANSAC | **Robust planar patches** (Araújo & Oliveira, 2020; Open3D `detect_planar_patches`) | Region growing with robust statistics | A baseline worth comparing against in Plane Lab |
| Learned | **DSAC, NG-RANSAC, CONSAC** (2017–2020) | A network guides sampling or scoring | Out of scope: no training data |
| Frameworks | **USAC** (Raguram et al., 2013); PCL's SAC family; CGAL | Bundles of the above | Reference implementations |

**Is RANSAC real-time? Yes** (measured 2026-10-01, `PlaneLab/spikes/x1_vs_ransac/ransac_bench.swift`):
- **Setup:** Swift `-O`, one M2 Max core, the final averaged cloud of `20261001-142809` (10,912 points), a full sequential search with priors as in the probe.

  | Search | Time | Planes |
  |---|---|---|
  | The probe as it is (400 + 3,000 hypotheses per plane) | 160 ms | 10 |
  | **Adaptive k** (stop once p = 0.99) | **25.6 ms** | 10 |
  | Adaptive k + local pairs | 26.7 ms | 10 |
  | Adaptive k + local pairs, top 3 planes | **4.5 ms** | 3 |

- **What it means:**
  - An iPhone 13 (A15) core should be somewhat slower; that needs measuring on the device. Even at 2× slower, a *full* search every round at X1's 4 Hz uses about 20 % of one core.
  - With (11), refitting known planes and searching only unclaimed points, most rounds should cost a few milliseconds.
  - Scoring is fully parallel, so SIMD and multiple cores are still unused headroom.
  - **Cost grows with the cloud:** O(k · N) per plane. At the accumulator's 100k-id cap it's about 10× slower, so thin the cloud or keep sampling local.
  - **Offline in Plane Lab** (S9: about 1,150 fits for a 2-minute session in < 60 s, so about 50 ms per fit) needs vectorized adaptive scoring or a compiled kernel. The pure-numpy probe takes seconds per cloud.

**Measured:** the same quantities as X1, plus `SPEC.md`'s S8 (planted planes: normal < 2°, offset < 2 cm), S9 (a 2-minute session in < 60 s) and S12, and the *X1 verdict*'s bar on `115808`, `142809` and `143156`.

## X2 on the phone (built 2026-10-02)

The user's call: implement X2 on iOS so its compute cost can be measured there, and test it in the field for a proper feedback loop, with the Blender plugin showing the same data. The branch is finished but not merged, and stays for history (XD14–XD18). Code: `PlaneKit/Sources/PlaneKit/Ransac/`, `Surfaces/SurfaceEngine.swift`, `SidingsAR/RansacDialsMenu.swift`; tasks X2.1–X2.6 in `ARKit_WallDetection/tasks/todo.md`; usage in `ARKit_WallDetection/README.md` *Experiment X2*.

**What was built.**
- **Search** (`PlaneSearch`): the design above, items 1–6: vertical (2-point NAPSAC) and horizontal (1-point) hypotheses only, PROSAC order by sample count, MSAC with a per-point band τ = 4 cm + 0.6 cm/m² × range² capped at 35 cm, lazy strided pre-scoring, adaptive k at 99 %, LO least-squares refits that keep the orientation class. XD12's priors and speed work, in Swift.
- **Round** (`RansacScanner`): refit tracked planes from the points in their band within their extent plus 1 m, then search only the unclaimed points when enough have changed (item 11), split each plane into connected pieces (item 7), and feed the X1 tracker (item 10) with a 25 cm plane-distance gate so slices merge (item 9) and a 2 % trim of the extent before the hull (item 8).
- **Measuring:** every round's stage times and counters go into a `surface_round` table (schema v4, XD16), the HUD shows last, median and p95, and *Benchmark on live cloud* runs 20 full searches on the phone.
- **Blender:** the planes layer is named after the engine, the round costs are keyed properties on a `… round stats` empty (Graph Editor), and a *Plane engine* tab shows the round at the current frame. `planelab info` and `peek` read the rows.

**Mac numbers** (Swift `-O`, one M2 Max core; the iPhone 13 is still to measure):
- `swift test --filter searchSpeed`: a synthetic 15,270-point facade, 3 planes: median 1.8 ms, 84 hypotheses, 0.5 M point tests. That scene is clean and flat, so its search stops early.
- Replay of the real averaged clouds, round by round at 4 Hz (`PLANELAB_REPLAY`, `RecordedReplayTests`):

  | Recording | Rounds | Points | Round median / p95 / max | Searches |
  |---|---|---|---|---|
  | `142809` | 426 | up to 10,910 | 5.4 / 10.3 / 13.0 ms | 113, median 1.2 ms |
  | `143156` | 235 | up to 8,751 | 3.1 / 6.9 / 11.6 ms | 62, median 1.1 ms |
  | `115808` | 188 | up to 6,776 | 4.3 / 8.2 / 11.5 ms | 55, median 0.6 ms |

  Most of the round is the refits of the tracked planes, not the search. At 4 Hz that's about 2 % of a core, and even 3× slower on the phone it stays well under a round interval.

**What the replay says about quality** (the bar from the *X1 verdict*; observed on the Mac, not on the phone):
- **No slanted planes**, by construction: every track is exactly vertical or horizontal (the replay test checks it).
- **Not yet one track per wall.** With the defaults the final tracks are 22, 17 and 10 on the three recordings, and the facade of `142809` is several near-parallel vertical tracks at offsets of −3.3 to −6.2 m, 0.4 to 2 m apart along their common normal, which the 25 cm gate doesn't merge. Raising the slice-merge distance to 0.5 m gives 16, 11 and 9. Ground truth is missing, so the count alone can't say which tracks are real (terraces and sills exist), and the by-eye check in Blender is the judge. The dials are in the app for exactly this.
- **Extents:** not yet compared with the points' own extent (±20 % is the bar); that's a Blender check.

**What the field test should answer** (checkpoint list in `todo.md`): the round time on the phone, hot and cool, against the Mac's 3–5 ms median; whether the facade settles into one track as the slice-merge distance goes up, and what that costs at recesses; whether the 26 cm band at 6 m is right; and how the ids behave while walking.

### X2 field test 1 (2026-10-02, recording `20261002-115935`)

First run of the RANSAC build on an iPhone 13 (iPhone14,5, no LiDAR): 96 s walking along one facade, standoff 3.9–7.5 m (points p50 5.3 m, p95 10.8 m). No dial was touched and the benchmark button wasn't pressed, so these are the XD17 defaults. Read from `surface`, `surface_round`, `cloud` and `plane_anchor`; nobody has judged it by eye in Blender yet.

**Compute: solved.**
- Round median 6.0 ms, p95 13.2 ms, max 20.0 ms, on a 250 ms cadence (about 2.4 % of one core). 0 skipped rounds. Thermal state went from nominal to fair after about 60 s.
- Search alone: median 1.4 ms (571 hypotheses). The refit is what grows with the track count, 1.5 ms at 3 tracks to 7.8 ms at 13, because every track scans the whole cloud (no spatial index). It has room to spare.

**Quality: below the X1-verdict bar** ("one plane per wall, stable IDs").
- 62 tracks over 96 s, 13 alive at the end; 30 of 62 lived under 3 s. 48 merges: 33 into the main facade track (#3), 10 into the ground track (#1). From 40 s on, the same three or four surfaces are re-created every 2–3 s and folded back. The ground also had a duplicate track (#2) for 43 s.
- Cause: the refit claims only points within the band around a track, while the wall's depth smear is wider. The leftover points (about 15 % of the cloud, 213 → 609, never shrinking) hold the next-densest vertical plane, so discovery fires every 4 rounds and finds a slice of the wall again.
- Per-track normals scatter: facade tracks have yaw 37°–50°, while a global yaw scan of the whole cloud peaks sharply at 39° and the long-lived track #3 sits at 39.7°. At 10 m, 10° is about 1.7 m of lateral error.
- Offsets along the facade normal: a main peak at −3.8 m with a skewed tail about 0.9 m wide toward the camera, a second peak 1.9 m behind it, and a flat background of points that belong to no plane (vegetation or air, roughly 45 per 10 cm bin).
- Good: no slanted plane (by construction); the ground (7.5 × 10.5 m, y = −1.5 m, rms 9 cm) agrees with ARKit's horizontal anchors (y −1.3 to −2.1 m); a 13 × 5.1 m facade track held for 91 s; small crisp surfaces come out at rms 2.4 cm (#21, #22).
- Likely junk, unverified by eye: #9 (a vertical plane 0.3 m from where the phone started, alive 79 s), and the horizontal 2–5 m "planes" at rms 13–18 cm (#18, #23).

**What it means.** The search is fast and finds the right orientations; what fails is the model. Inlier-counting planes on a 30–60 cm thick, view-dependent point slab can only place the wall as well as the slab is thick: the earlier recordings put the fitted offset at about ±15–20 cm, and this one's slab is wider; the per-track yaw scatters by 13°. Neither number has a ground truth behind it yet. Since the area of a wall seen through a camera scales with distance squared, an offset error of e at range d costs about 2e/d of area: ±20 cm at 6 m is about 7 %, against a ±5 % target. Patches (suppress discovery inside a confirmed wall's slab, widen the claim to the track's own spread, a global yaw prior) would calm the display, not improve the measurement. This test also stayed at 4–7.5 m, not the 8–15 m the product needs, where the smear is worse.

See XD19.

## Comparing them

- **Same sites.** The T24 building (`20260929-172952`, `20260930-102759`) and the open-standoff site (T25).
- **The same quantities** as listed under X1, with the user's by-eye check per wall (E2).
- **For a side-by-side in Blender,** X1's tracks would need recording into the session. That's a possible follow-up, not in X1's first cut.

## Decisions

| # | Decision | Date | Reason |
|---|---|---|---|
| XD1 | X1 runs live on the phone | 2026-10-01 | The user's call |
| XD2 | X1 finds planes with automatic seeds, not aim-and-capture | 2026-10-01 | The user's call; it finds every wall, like X2 |
| XD3 | The IDs are X1 and X2, and branches are `exp/x<n>-…` | 2026-10-01 | E1–E3 are taken in `SPEC.md` |
| XD4 | X1 calls FindSurface's raw API (`FindSurfaceFramework`) instead of the package's wrapper | 2026-10-01 | The wrapper uploads the cloud on every call and allows one call at a time; the raw context lets a round upload once and fit many seeds |
| XD5 | X1 matches fits to tracks by shared inlier feature ids, with geometry as a gate | 2026-10-01 | ARKit feature ids persist across frames, so they identify the same surface better than geometry alone |
| XD6 | X1's tracks are recorded as **schema v3**, a new `surface` table. It's an add/update/remove log like `plane_anchor`, with one row per track that changed in a round, stamped with the last recorded frame when the round started. Rows hold the state, normal, center, outline, size, RMS error and inlier count; a remove names the survivor of a merge. Inlier ids aren't stored. | 2026-10-01 | The user asked to persist the planes and see them in Blender. A log of changes is small (about 1.5 MB a minute at most), and Plane Lab already replays `plane_anchor` the same way. Inlier ids would cost about 20 MB a minute. |
| XD8 | **v2 defaults:** mean distance 1.0 m, lateral extension 7, seed radius max 6 m, keep band 0.15 m, merge gap 0.5 m (new) | 2026-10-01 | The wall in `20261001-115808` stopped growing at 7.67 × 5.35 m at about 7 m; one suspect per dial (*X1 dials*). The user wants a rough measure and chose to tune live on the phone. |
| XD9 | **The dials are changed live on the phone** (*Debug › X1 dials*). Each change applies from the next round and keeps the tracks; while recording it's an `x1_dial` event. | 2026-10-01 | The user's call ("live in phone") over an offline Simulator replay. The events tie each sweep in a recording to its dials. |
| XD10 | **Tracker:** coplanar pieces within the merge gap match or merge, and "same plane" is measured along the mean normal | 2026-10-01 | Patches of one big wall never joined without overlap. With each plane's own normal, a 1° disagreement between patches 6 m apart reads as a 10 cm offset. |
| XD12 | **X2's design** uses an Efficient-RANSAC skeleton: priors, local sampling with lazy scoring, PROSAC by sample count, MSAC with a per-point range-scaled band, DEGENSAC-style rejection, LO refinement, connected pieces, robust extents, slice merging, X1's tracker ideas, and incremental rounds (*X2*, items 1–11) | 2026-10-01 | The variants reviewed against what X1 and the probe showed: tilted planes, slices of 30–40 cm slabs, coplanar points 20 m away, hull-inflated areas, speed |
| XD13 | **RANSAC is feasible in real time:** a full 10-plane search on a 10.9k-point cloud takes 25.6 ms with adaptive k on one M2 Max core (Swift `-O`), and 4.5 ms for the top 3 planes | 2026-10-01 | Measured on `142809`'s real cloud (`ransac_bench.swift`); the iPhone 13 is still to measure |
| XD11 | X2 branches from `exp/x1-findsurface-live`, not `main`; `main` gets both when merged | 2026-10-01 | The user's call. X2 needs the v3 reader and X1's Blender layer to compare against |
| XD7 | Every recording stores X1's settings as `x1.<name>` meta rows plus `x1_enabled`, and at Stop `x1_rows`, `x1_tracks` and `x1_confirmed` | 2026-10-01 | A run can be read back knowing exactly which settings produced it, like `const.*` for the recorder |
| XD14 | **X2 runs live on the phone, and RANSAC replaces X1 in the UI.** X1's engine (`SurfaceScanner`, `FindSurfaceFitter`) stays in the code and old recordings still replay; `LiveSurfaces` takes any `SurfaceEngine` | 2026-10-02 | The user's call: RANSAC in real time on iOS, field-tested, with the compute cost measured there |
| XD15 | **Swift only on this branch:** no Python RANSAC (SPEC T17–T20 stay open on `main`) | 2026-10-02 | The user's call (fastest route to the field test). The Blender side replays the phone's recorded planes, so it needs no Python fitter |
| XD16 | **Schema v4 adds `surface_round`**, one row per round of the engine: frame, round, points, unclaimed, tracks, confirmed, refits, searched, planes found, hypotheses, full scores, point tests, total, refit and search milliseconds, skipped rounds, thermal state. `meta` gets `surface_engine` (`ransac`; recordings without it are FindSurface's) and at Stop `surface_rounds` and the median, p95 and max round time. The `x1.*` meta rows hold either engine's settings | 2026-10-02 | A claimed speed needs per-round numbers from the device, not one HUD readout; thermal state explains 30 vs 60 Hz slowdowns. Reusing the `surface` table kept the replay path and the Blender layer; a separate table keeps the timings queryable |
| XD17 | **Defaults for the RANSAC engine** (`SurfaceSettings.ransac`): band 4 cm + 0.6 cm/m² × range² capped at 35 cm; plane-distance gate 25 cm, merge gap 0.5 m, keep band 25 cm; extent trim 2 %; RMS limit 3 × measurement accuracy; up to 4 planes per search, a search every 4 rounds or when 1.2× more points are unclaimed | 2026-10-02 | Minor calls from the X1 verdict (a 30–40 cm slab at 4–7 m; slices to merge; a hull inflated 2.3×). Starting values for the field tuning, not tuned results: the replay still leaves several parallel tracks on a facade. The band uses each point's range from the camera at the round, not from where it was seen |
| XD18 | **Surface events are `surface_dial`, `surface_restart` and `benchmark`**; labels read `#3 …`, no longer `X1 #3 …`; the Blender layer keeps its `x1_surfaces` key (so saved files refill) and is named after the engine | 2026-10-02 | The names said X1 while the engine is RANSAC. Older recordings keep their `x1_dial` markers |
| XD19 | **X2 is a primitive, not the pipeline; stop tuning it and test image-based measurement next.** Keep `exp/x2-ransac` as is (history). | 2026-10-02 | Field test 1: compute is a non-issue (6 ms median on an iPhone 13), but 62 tracks churned for 3–4 surfaces, facade yaw scattered by 13°, and the slab thickness caps offset accuracy. The ARKit cloud stays useful as a prior (global yaw, rough wall offsets). Area, corners and openings need the 4032 × 3024 stills and video with known poses (T33, COLMAP, or per-wall edge triangulation); not yet tested, so this is a hypothesis. |
