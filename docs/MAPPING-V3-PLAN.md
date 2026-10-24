# Mapping v3: a continuously improving, high-resolution shared map

*2026-10-24. Status: **proposal**. Server paths refer to `snailCOP/services/snailsight/` and its docs
(`docs/SNAILSIGHT-LIVE-SHARED-MAP-PLAN.md`, `docs/SNAILSIGHT-API.md`). The app side is this repo.*

Owner (2026-10-24):

> "goal is to enable multiple sensor simultaneous mapping and realistic 3d world generation that can be used for
> exploration, movement for actual robots, and even creating a 3d sim environment. current record and send to GPU for
> processing is a bit of a bulky process that takes a lot of time. current world is very low res, and multiple walks and
> mapping runs degrades the appearance of the environment rather than improving it. I need a way to explore and generate
> continuous map improvement ... multiple sensors at once for multiple robots in a home and outdoors using a shared map.
> iPhone 15 now, Meta Quest 3 later, and a L1 lidar + colour camera combo."

## 0. Summary

The shared-map backbone already exists: one living map, 4 m tiles with their own revs, every agent localized to one
site frame, multi-sensor live ingest (`sensors.py` profiles, `sensor_of` / `extrinsics` / deskew in `livefront.py`),
held-tile sync. **The problems are in how appearance is fused, what the devices draw, and the batch-shaped path from a
walk to a good-looking tile.** Three root causes:

1. **Appearance is averaged, so more data makes it blurrier.** The live layer keeps a running average of every
   keyframe's colour per 5 cm voxel. The base TSDF fuses every walk into one volume, so a walk that is a few cm off
   thickens or carves the others' surfaces. The splat layer is retrained from scratch each night on 180 frames spread
   evenly across all walks. Each extra walk adds more lighting conditions, more small misalignments and more soft
   frames to one average.
2. **What you see is the lowest-resolution product.** By default AR draws the live mesh (5 cm voxels, one colour per
   vertex, about 20 px/m) on top of the house tiles. The phone copy of a house tile is capped at one 1024² atlas per
   4 m leaf (about 70–80 px/m), even though the server bakes about 400 px/m. The photoreal splat tiles are built every
   night, but no AR or Map 3D view ever loads them. The sharp 1920×1440 keyframes the phone records are used only for
   object detection. Texturing and splats use 1024×768 frames.
3. **Getting from a walk to a good tile is a batch pipeline.** Record, upload, ingest, place (5–8 min), Fast pass
   (4–5 min, 3 cm vertex colour), textured pass (68–79 min), splat (nightly at 01:30). The live stream (1–2 Hz,
   1024×768 JPEG q 0.5) feeds only the coarse live layer, and M7 promotion prefers a capture upload.

**The fix in one line:** store, for every small surface patch, the best observation seen so far and replace it only
with a better one. Do not average new data in. Then stream to each device the best resolution its memory allows,
splats near you, and turn the 2-hour pipeline into continuous per-tile refinement fed by the live stream.

## 1. Root causes, with evidence

| # | What | Where | Effect |
|---|---|---|---|
| A1 | Live colour = weighted running average, capped at 30 views, per 5 cm voxel; one luma gain per keyframe | `livetiles.py` `VOXEL=0.05`, `COLOUR_WMAX=30`, `_gain` | blur, colour drift as lighting changes between walks |
| A2 | Base geometry = one TSDF over all walks (authority rank 4: "fused by TSDF weight (capped 50)") | `hq.py` `tsdf_mesh` (its comments: "passes that disagree by a few cm ... carve each other's surfaces away") | thick or doubled walls, holes, softer edges after more walks |
| A3 | Tile monotonic rule is all-or-nothing per 4 m tile | `ratchet.py` `TILE_MARGIN` / texqa | a tile that is better in one corner and worse in another is either kept whole or replaced whole |
| A4 | Best-single-view texture per cell exists, but only for structure planes (walls, floors, ceilings) at 150 px/m | `planebake.py` | furniture and clutter (most of what you look at) still go through the blended bake |
| A5 | Splat blocks retrained from scratch every night on `linspace` over all candidate frames (≤ 180), no sharpness or lighting ranking, SH degree 0 | `splattiles.py` `prepare_block` | more walks means fewer frames per walk and mixed lighting; no view-dependent shine |
| B1 | AR "Mesh (live)" layer on by default, Photo colour, drawn over the house tiles | app 12.0 / 12.1, `LiveMeshFeed` | the coarse layer covers the better one |
| B2 | Phone tile atlas ≤ 1024² per leaf | `tiles.py` `PHONE_TEX_MAX=1024` | about 5× fewer texels than the server bake |
| B3 | Splat tiles (SPZ per leaf) never loaded by the app | `splattiles.py`, app has MetalSplatter only in Scans | the photoreal layer exists but can't be seen while exploring |
| B4 | Texture / splat input = 1024×768 frames; 1920×1440 sharp keyframes unused | `allframes.py`, `capture.py` `read_keyframes` | resolution ceiling well below the camera's |
| C1 | Walk to textured tile about 2 h; splat next night | plan §2 / M3 timings | "bulky", no feedback while exploring |
| C2 | Live keyframe = first frame after the 0.5 s tick, no blur check, q 0.5 | app `LiveStreamer` (**fixed in 12.10**, §5) | soft frames feed live colour, change detection and promotion |

## 2. Target architecture

```
 agents (phone, Quest 3, rover L1+RGB, Kinect, drone)          map server (node00 + SnailFarm GPU)
 ───────────────────────────────────────────────────          ─────────────────────────────────────────────
 own odometry (ARKit / Quest / LIO)                            localize (unchanged) → T_site_odom per stream
 live stream, ONE path for everything:                         ┌ live layer (seconds): coarse TSDF, occupancy,
   depth / points + pose every frame the gate takes            │   terrain, change evidence (unchanged)
   sharp keyframe (full-res, blur-gated, novelty-gated) ──────►├ observation store (NEW): every keyframe kept with
   exposure / WB / blur metadata, sensor id + extrinsics       │   its pose, sharpness, exposure, sensor σ
                                                              ├ surface-patch best-view store (NEW, §3.1)
 ◄── tile revs (held tiles only)                               ├ per-tile refine queue (NEW, §3.3): minutes, not
 ◄── coverage gaps "look here" (NEW, §3.4)                     │   nightly; geometry, texture, splat warm-start
 draws: near = splat + 2048² mesh, mid = mesh, far = plan      └ products per tile: mesh LOD, terrain, nav,
                                                                   objects, splat, sim collider (unchanged formats)
```

Principles:

- **One ingest path.** Live streaming is the capture. "Record" becomes "stream at high quality", with the same spool
  and resume. There is no separate upload and no separate GPU batch to wait for.
- **Keep the best, never average.** Appearance is stored per surface patch as the top-k observations ranked by a
  score, and is replaced only when a better one arrives. Geometry is fused per walk first, then merged with
  per-region quality selection (§3.2).
- **Refinement is continuous and local.** Each tile has a dirty score (new evidence × expected gain). A scheduler
  rebuilds the tiles with the highest gain in minutes on the GPU, between live-vision jobs.
- **Devices draw what they can afford.** Near tiles get splats and high-res atlases. The live mesh only fills where
  no base tile exists yet, and fades out once one does.
- **Robots and sim read the same tiles.** Mesh, terrain and nav are geometry products. Splats are visual only and are
  never used for collision.

## 3. Server changes (snailCOP)

### 3.1 Surface-patch best-view store (fixes A1, A3, A4, B4)

- Store is keyed per 2 cm surface patch (a surfel on the tile mesh, or a cell of the existing `planebake` grid,
  generalized from planes to every chart of the `texbake` atlas). Each patch keeps its **top-k (k = 3)
  observations**: frame id, uv, score.
- Score = the `planebake` / `ratchet` texture score you already trust: sharpness_rel² · cos³ · 1/z² · exposure
  quality · residual term. Add a lighting-consistency term against the patch consensus so one dark walk can't win.
- A new keyframe updates only the patches it improves (`TEX_MARGIN`). The tile atlas is re-baked from the per-patch
  winners with the existing MRF seam choice and global gain solve. **The guarantee:** a walk that scores worse
  everywhere leaves the texture bit-identical. That is the ratchet test you already have, applied to all surfaces.
- Input: the full-res 1920×1440 keyframes (and live high-quality keyframes, §4.1), not the 1024×768 frames.
  Target density near surfaces 600–800 px/m. That is about 2 px/mm at 1 m, roughly what the camera resolves.

### 3.2 Geometry: fuse per walk, select per region (fixes A2, A3)

- Each walk or stream becomes a **per-walk sub-volume** after placement (you already compute per-walk placement and
  residuals in `place`).
- Merge per 0.5 m region: pick or weight the sub-volumes by local quality (depth σ from the sensor profile, distance,
  incidence, placement residual against the consensus) instead of one global TSDF. A region whose walks disagree by
  more than 2 cm is not averaged: the better-scoring walk wins, and the disagreement goes to `livechange` as
  evidence.
- Per-region monotonic rule instead of per-tile, so a tile can improve in one corner and stay as it is elsewhere.
- Base voxel 1 cm near (≤ 2 m from where agents walked), 2 cm otherwise, as hq does today. The live layer stays
  5 cm (it is for robots and change detection).

### 3.3 Continuous refine queue (fixes C1, A5)

- `tile_refine` job per dirty tile, ranked by gain = new-patch-wins × visibility (how often agents are near it).
  Debounce: 2 min after the last keyframe in the tile, or immediately when an agent stands in it for 30 s.
- Steps: geometry region merge (CPU) → texture re-bake from the patch winners (CPU, seconds per tile) → **splat
  warm-start** on the GPU: load the block's current Gaussians, add the new top-k frames per patch, 1–2k iterations
  instead of 7k from scratch, freeze Gaussians in patches that didn't change. Expected: under 60 s per block on the
  4090, versus 105 s cold today.
- Splat frame selection = the per-patch winners (sharp, frontal, lighting-consistent), not `linspace`. Move to SH
  degree 1–2 for near tiles (glass, floors, metal).
- The nightly batch remains only as a compaction or cleanup pass.

### 3.4 Coverage feedback ("look here")

- Per tile: patches with no observation above `TEX_MIN_SCORE`, and geometry regions with only one walk or a high σ.
- Exposed in the live WS as a `gaps` layer. The app draws a soft highlight in AR ("scan this"), and robots get explore
  goals (the `Explore gaps` and drone mission plumbing already exist).

### 3.5 Multi-sensor specifics

| Sensor | Geometry | Colour | Needed |
|---|---|---|---|
| iPhone LiDAR (15 **Pro** / Pro Max) | 256×192 depth, σ ≈ 1 cm at 1 m, ≤ 3–4 m | 1920×1440 keyframes | live HQ keyframes (§4.1). **A non-Pro iPhone 15 has no LiDAR**: today it sends nothing on the live stream (`sceneDepth` is nil). It could still contribute RGB-only keyframes for texture and splats, but needs a new depth-less path |
| Unitree L1 + RGB camera | L1 points (deskewed, `lidar3d` profile exists) | camera frames projected onto points / mesh | an `rgb` sensor with `extrinsics` to the L1 (calibration tool: target board or edges-to-depth alignment), shutter-time sync, colour samples from projection onto the tile mesh, not the depth grid. `sensors.py` only registers RGB to a pinhole depth today |
| Meta Quest 3 | coarse depth API (rank 6: change evidence only) | Passthrough Camera API ~1280×960 RGB | native capture app (plan §9.3 spike Q0); RGB keyframes enter the best-view store like phone keyframes once localized; geometry stays evidence-only |
| Kinect v2 / others | profile exists | registered RGB | none |

Outdoors: the same tiles apply. Raise the live voxel to 10 cm beyond 10 m from any surface and drop texture
targets to 200 px/m for terrain. Splats are what make yards look real.

## 4. App changes (this repo)

### 4.1 Live stream as the high-quality capture

- **12.10 (done, §5):** blur-gated live keyframes, plus `blur_px` / `exposure_s` in the header.
- Next: a novelty gate. Send a full-res 1920×1440 JPEG (q 0.85) only when the view adds coverage: more than 15 % of
  its depth pixels land in voxels with fewer than 2 good views (a phone-side visit grid, 10 cm), or more than 0.75 m /
  20° since the last HQ keyframe (the Map mesh rule). Expected about 0.3–0.6 HQ keyframes/s while walking, around
  0.5 MB each, so about 1–2.5 Mbit/s, well within home Wi-Fi.
- Lock exposure and white balance per 10 s segment and send them (ARKit `exposureOffset` / AVCapture values), so the
  server's gain solve has fewer unknowns.
- Retire "Record" for mapping. It stays for raw captures and debugging.

### 4.2 Draw the best product

- AR near band (≤ 6 m): **splat tiles**, with the mesh as an invisible occluder and collider. MetalSplatter already
  renders SPZ-like data in Scans. The work is a RealityKit integration (a `CustomMaterial` or a Metal pass composited
  over the AR camera feed) under a budget of about 1.5 M Gaussians on an A17 Pro.
- Map 3D: splats near the virtual camera, mesh beyond.
- Ask the server for a 2048² phone atlas in the near band (a new `variant=near` or `tex=2048` query). Keep 1024 for
  mid.
- "Mesh (live)": draw only where no base tile holds the cell, or where `livechange` flags a change; fade it out after
  promotion.

### 4.3 Coverage gaps in AR

- Draw the server `gaps` layer as a soft pulse on surfaces that need a better view, with a counter in the status pill
  ("3 spots need a closer look").

## 5. Shipped in this change (app 12.10)

- `LiveGate.decide(t:T:blurPx:)`: a due live keyframe whose predicted motion blur exceeds 2 px waits for a sharper
  frame (≤ 6 px accepted after 0.2 s, anything after 0.4 s, so the 2 Hz rate holds). Predicted blur uses the same
  formula and thresholds as the Map mesh keyframes (`KeyframeQuality.predictedBlurPx`, `MeshMapGate.blurOK/blurLate`).
- Live keyframe header gains optional `blur_px` and `exposure_s`. These are extra JSON keys: `livefront.py` reads
  only the keys it knows, so the current server is unaffected. The best-view store will use them.
- Log `live_off` gains `blurry_frames`.
- Tests: `LiveGateTests.testBlurHold`, `testHeaderQualityKeys`.

## 6. Phases

| Phase | What | Repo | Fixes | Rough effort |
|---|---|---|---|---|
| V3.0 | blur-gated live keyframes + quality header | app | C2 | **done** |
| V3.1 | draw policy: live mesh only where no base; 2048² near atlas | app + server `tiles.py` | B1, B2 | 1–2 days |
| V3.2 | splat tiles in AR near band and Map 3D | app | B3 | 4–6 days (RealityKit/Metal) |
| V3.3 | splat selection by quality + warm-start refine per block, SH1 near | server | A5, C1 (splats) | 3–4 days |
| V3.4 | HQ keyframes on the live stream (novelty gate, full res, exposure lock) | app + server ingest | B4, C1 | 3–5 days |
| V3.5 | best-view patch store + per-patch ratchet for all surfaces, 600–800 px/m | server | A1, A3, A4 | 6–10 days |
| V3.6 | per-walk sub-volumes + per-region geometry selection | server | A2, A3 | 6–10 days |
| V3.7 | continuous `tile_refine` scheduler (replaces the 70 min textured pass and nightly splat) | server | C1 | 3–5 days |
| V3.8 | coverage gaps layer (AR + robot explore goals) | server + app | exploration | 2–3 days |
| V3.9 | L1 + RGB colour profile and calibration; Quest 3 RGB keyframes | server + device clients | multi-sensor | 4–8 days each |

**Gate for every server phase:** replay an existing walk as new on top of the map (the M3 harness). Texture must stay
bit-identical in regions where the new walk scores worse. `texqa` / `meshqa` seam and sharpness metrics must improve
or stay the same in every tile. Localization A/B must pass (`tools/loc_ab.py`).

## 7. Open questions

1. ~~Which iPhone 15 model?~~ **15 Pro** (LiDAR), owner 2026-10-24.
2. Which camera is in the L1 combo (model, resolution, global or rolling shutter, hardware trigger)? This decides
   whether colour can be time-synced to the L1 sweep.
3. ~~Order~~: owner 2026-10-24: server work goes straight to `main` in small, separately revertible commits; pick from
   the menu in §8.

## 8. Menu of updates (owner 2026-10-24: "a list of available updates to improve a live and fast update to the world
map in addition to the 2 cm update ... lighting may make this an odd patchwork ... environments change over time with
objects, tables, chairs, branches and vehicles")

Status: **exists** = already in the server, only needs wiring; **partial** = some of it exists; **new**. Effort is in
agent-days. Each item is one or a few commits that can be reverted on their own.

### 8.1 Faster, live updates

| # | Update | Where | Status | Effort | Why |
|---|---|---|---|---|---|
| L1 | Blur-gated live keyframes + blur / exposure in the header | app | **done 12.10** | – | sharp input everywhere downstream |
| L2 | **Person masks from the phone**: ARKit `personSegmentationWithDepth` mask as a `mask_png` blob; the server leaves those pixels out of fusion, colour and change evidence | app + `livefront` / `livetiles` | new | 1–2 | people walking through never become ghosts or "changes" |
| L3 | Full-res HQ keyframes on the live stream, novelty-gated (§4.1), HEIC instead of JPEG (about half the bytes) | app + ingest | new | 3–5 | the live stream becomes the capture; no record/upload step |
| L4 | **Per-tile refine queue** (§3.3): a dirty tile is rebuilt about 2 min after the last keyframe in it, ranked by expected gain | server | partial (`tile_fast` + textured pass) | 3–5 | minutes instead of 70 min / next night |
| L5 | **Splat warm-start per block**: continue from the current Gaussians with the new frames, 1–2k iterations, unchanged regions frozen | server + farm `splat.train` | new | 3–4 | splat updates in about 1 min per block, not nightly from scratch |
| L6 | Provisional, then settled: fuse at once with the live pose, re-fuse a keyframe when the pose graph (`livegraph` iSAM2) moves it more than 1 cm | server | partial | 2–3 | fast without baking in drift |
| L7 | Smaller near tiles (1 m sub-leaves inside 4 m leaves) and delta blobs (only changed charts or Gaussians) | server + app | new | 3–4 | a small change costs KB, not a whole tile |
| L8 | Finer live voxels near agents (2–3 cm within 2 m, 5 cm beyond), or move the live TSDF to the GPU (Open3D CUDA, or NVIDIA **nvblox**, Apache-2.0: GPU TSDF, ESDF, people masking, LiDAR + depth) | server | new | 2 (CPU) / 5–8 (nvblox) | sharper live geometry; nvblox also gives robots an ESDF for planning |
| L9 | Instant projected texture: until the bake lands, the newest sharp keyframe is projected onto the live mesh near you | app | new | 3–4 | you see high-res colour seconds after looking |
| L10 | Coverage gaps layer ("look here") for people and robot explore goals (§3.4) | server + app | partial (Explore gaps) | 2–3 | exploration aims at what improves the map |

### 8.2 Lighting without a patchwork

| # | Update | Where | Status | Effort | Why |
|---|---|---|---|---|---|
| C1 | **Per-tile splats onto the v2 gsplat trainer** with `appearance` (per-walk gain + bias), `people`, `pose_opt` on. The tile batch still runs OpenSplat v1 (no exposure or pose refinement; its own comment: walks that disagree get "needles") | server `splattiles.py` | **exists** (v2 trainer in `tools/splat_v2`) | 1 | removes most lighting patchwork in splats at once |
| C2 | One global per-frame exposure / white-balance gain solve shared by the live colour, the bake and the splats (today: luma-only gain in live, a separate solve in the bake) | server | partial (`texbake.solve_gains`) | 2–3 | one consistent lighting reference for every product |
| C3 | Phone exposure discipline: AE/AWB locked per ~10 s segment while mapping; send `exposure_s`, ISO, ARKit light estimate (ambient intensity, colour temperature) | app | partial (CameraPolicy; `exposure_s` 12.10) | 1–2 | fewer unknowns for C2; colour stops drifting mid-room |
| C4 | Lighting-consistency term in the best-view score: a view far from the patch's consensus brightness/colour loses even if sharper | server (§3.1) | new | with §3.1 | one dark or lamp-lit walk cannot win a few patches and speckle the wall |
| C5 | Gradient-domain seam blending (Poisson / Waechter global + local adjustment) across charts **and across tile borders** | server | partial (`level_seams` per texture tile) | 2–3 | no visible boxes where two views or two tiles meet |
| C6 | Lighting states: keep top-k per lighting bucket (day / night-lamps; outdoors by sun elevation), each tile renders one bucket consistently, picked by time or by the device's light estimate | server + app | new | 4–6 | night visits stop overwriting day texture; AR can match the current light |
| C7 | Store linear radiance (exposure × ISO normalised) rather than camera-processed sRGB; tone-map once on output | server | new | 2–3 | exposure differences cancel in maths instead of by heuristics |

### 8.3 Environments that change

| # | Update | Where | Status | Effort | Why |
|---|---|---|---|---|---|
| D1 | **Persistence classes per region**: static (walls, floors), semi-static (furniture, parked cars: moves over days), dynamic (people, pets, moving cars, swaying branches). Built on the `livechange` evidence cells + the ARKit mesh classes + YOLOE labels | server | partial (`livechange` dynamic tiles, door state) | 3–4 | each class gets its own update rule instead of one rule for everything |
| D2 | **Movable objects as entities**: chairs, tables, bins, vehicles become object entities with their own mesh, texture and splat (`object_build`); a moved chair moves its entity, the base gets the floor under it, no ghost | server + app | partial (objects per leaf, entities, P4) | 5–8 | furniture moves never smear the texture of the room |
| D3 | Change-gated texture replace: inside a confirmed change region the best-view history is reset (recency wins there, rank 3); everywhere else quality wins | server | partial (ratchet bypass for change evidence) | 1–2 | a repainted wall or a new rug shows up instead of losing to old sharper photos |
| D4 | Free-space carving with decay: what is repeatedly seen through is removed, with a half-life per class (fast for dynamic, slow for static) | server | partial (`livechange` removed + 2-agent rule) | 2–3 | old car / moved table disappears on its own, walls never do |
| D5 | Vegetation: per-voxel temporal variance marks swaying regions; leaves and branches go to splat + soft cost only, trunks stay hard geometry; seasonal change by D3 | server | partial (lidar trees, estimated layer) | 3–4 | wind and seasons stop corrupting the yard mesh and nav |
| D6 | Vehicle / parking slots: a slot is a semi-static region; whatever vehicle is there is an entity, the base keeps the empty ground | server | new | 2 | the driveway does not become a melted car average |
| D7 | Map snapshots for sim: "static + semi-static as of time T" exported as a USD scene (mesh colliders + splat visuals + entities) | server | partial (`usd_compliance`, sim world) | 2–3 | reproducible sim environments from the living map |

### 8.4 Recommended order

1. **C1** (1 day: biggest lighting win, code exists), **L2** (people masks), **D3** (change-gated replace).
2. **L4 + L5** (minutes instead of hours), with **C2 + C3** so the faster loop stays colour-consistent.
3. §3.1 best-view store with **C4 + C5** (the 2 cm item), then **D1 + D2 + D4** (persistence classes, movable
   entities, decay).
4. App display: splats in AR (V3.2), **L9**, 2048² near atlas.
5. **L3** HQ live keyframes, then **L8** (nvblox) and the multi-sensor profiles (§3.5).
