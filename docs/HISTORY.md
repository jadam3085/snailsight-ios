# SnailSight feature history (9.x – 10.x)

Per-version notes carried over from the private monorepo. Paths like `docs/SNAILSIGHT-API.md`,
`docs/SNAILSIGHT-REFACTOR-PLAN.md` and `tools/ilidar_build/` refer to the private server repo and are not part of
this repository.

- `Sources/` app (SwiftUI shell). `ARSessionController` (session/config/taps), `SceneRenderer` (cube, measure,
  ruler, labels), `MeshOverlay` (subtle wireframe), `DebugLog`, `Stubs.swift` (Recorder/Localizer/NetClient seams).
- `SnailSightCore/` Swift package with all pure maths (frames, placement, ruler, fps, tracking text, log format);
  `swift test` runs on CI before every archive.
- `upstream/apple-reconstructed-scene/` Apple's sample, unmodified (AR base, Option A). Licence:
  `LICENSE-Apple-sample.txt` (MIT-style, © 2026 Apple). Derived code: `Sources/AppleSampleDerived.swift`.
- `Resources/Assets.xcassets/AppIcon.appiconset` the SnailSight icon from 8.3 (`tools/ilidar_build/icon/`).

**9.1 (P1)**: talks to the `snailsight` map server (`docs/SNAILSIGHT-API.md`, :8904; Tailscale first, home LAN
fallback, override in the gear sheet). `NetClient.swift` (`ServerLink` actor: probe + requests, agent registration),
`LogUploader.swift` (every log in Documents/logs uploaded append-by-offset every 30 s, on background and on **Send log**),
`Recorder.swift` (StrayScanner-layout capture in Documents/captures/<cap-id>/: rgb jpg 1024×768, 16-bit mm depth,
confidence, odometry.csv, camera_matrix.csv, imu.csv, capture.json; ~10 Hz while tracking is normal),
`UploadQueue.swift` (zip → `POST /v1/sessions` → 4 MB resumable chunks → poll state; persisted), `SettingsView.swift`.
Pure logic (agent id, server order, chunking, log offsets, CSV/quaternion, depth mm) in `SnailSightCore` with tests.

**9.2 (plan §7 S1, simulated agents in AR)**: HUD **Sim** toggle (off by default; paused + hidden while recording unless
Settings allows it). **Spawn** puts RobosnailBob (drawn from its URDF, real 0.76 m footprint, 0.4 m/s · 1.2 rad/s with Nav2
accelerations) or a deer / fox / rabbit where the centre reticle meets the floor. The thumb stick drives the robot
(`StickShaper` → `DiffDrive`); RealityKit convex casts of its footprint against the LiDAR scene mesh stop it at walls
(sliding along them), at steps over 6 cm and at drops over 10 cm, and when there is no floor mesh. Animals run
`AnimalBrain` (graze / stop-go / bounded flee → settle, ported from snailCOP `services/wargame/entities.py`). They are
spooked by the robot (1.8 m for a deer) and by you (1.2 m). Their free-space checks are raycast fans against the mesh.
Code: `Sources/Sim/`, pure logic + tests `SnailSightCore/{SimCore,DiffDrive,AnimalBrain,SimClips}.swift`, models
`Resources/SimModels/` (CC0 / CC-BY, see `ATTRIBUTION.md`). Logs: `sim_on`, `sim_spawn`, `sim_spook`, `sim_block`,
`sim_stats` (every 10 s).

**9.5 (sim fixes + commands, owner feedback on 9.3.65)**: RobosnailBob is drawn at the REAL base size (Q6 Edge 2.0,
0.82 × 0.62 × 0.61 m, from `RobotModel.parts`; the URDF tank placeholder was 0.76 m wide) with a contact shadow, and a
**1 m** scale bar can be shown beside it. **Support physics**: sim blocks (Spawn → Block, dropped from 40 cm), the
robot, animals and placed cubes re-check what holds them up when ARMeshAnchors under them update or vanish (throttled
mesh-change queue → wake → 5-ray probe → fall / land / pop up; never through an unscanned surface). **Tap to select**
any sim body (cyan box + label with its size and behaviour) → command bar: Move (tap a spot or drag), ⟲/⟳ 45°,
Duplicate, Delete; animals Go to / Follow me / Flee / Graze / Stay / Wander; robot Go to / Follow me / Stop / Patrol
(A* on a grid built from the scene mesh around start and goal, respecting the 6 cm step / 10 cm drop and the robot's
width; the joystick always takes control back). Pure logic + tests: `SnailSightCore/{SimBody,SimSupport,SimNav,
SimSelect}.swift`, `SimCommandTests.swift`. Logs: `sim_select`, `sim_cmd`, `sim_plan`, `sim_support`, `sim_arrived`,
`sim_overlap`, `sim_scale_ref`.

**9.3 (object scan, docs/SNAILSIGHT-API.md §9)**: HUD **Object scan (high-res)** next to **Record room** opens a sheet
(name, "Send to the robot page" = tag `robot`) with two modes. **Photo-quality** = Apple Object Capture
(`ObjectCaptureSession` + `ObjectCaptureView`: Continue → fit Apple's box → Start capture → passes → on-device
`PhotogrammetrySession` `.reduced` → USDZ + OBJ; SnailSight's AR session is paused meanwhile). **Quick LiDAR** = set
floor → place/adjust an AR box (sliders, nudges) → record with the object profile (dense full-res keyframes) →
server-side TSDF. Both save `Documents/captures/obj-…` / `objl-…` and upload through the same background parts queue
to **`/v1/objects`** (never `/v1/sessions`, so nothing reaches the house map). Code: `Sources/ObjectScan/`
(`PhotoScan.swift`, `ObjectScanLidar.swift`), pure logic + tests `SnailSightCore/ObjectScan.swift`. Logs:
`object_scan_begin`, `object_photo_*`, `object_floor`, `object_box`, `object_enqueue`. Known limit: a LiDAR object
recording killed mid-way is not auto-recovered (room captures are).

**9.6 (owner feedback on 9.3.65 + native Scans screen)**:
- **Recording HUD / mesh**: the headline shows both rates, `AR 60 fps · REC 10 fps` (the AR/camera frame rate is not the
  capture rate). New `AdaptiveCapture` table (API §4.4a): thermal **fair keeps 10 Hz and the mesh** (wireframe updates
  slowed to every 8 s per anchor, no warning); memory < 1.2 GB / 1 memory warning → 5 Hz + mesh frozen; thermal serious /
  < 700 MB / 2 warnings → 2 Hz + mesh frozen; critical / < 350 MB → clean stop. A mesh memory cap (3 M scene-mesh
  vertices) also freezes the mesh without lowering the rate. **Frozen** = ARKit scene reconstruction stops and frees its
  memory (the 9.1.61 crash cause) but the wireframe already drawn **stays on screen, dimmed amber**, with "Mesh frozen"
  in the HUD; after Stop the live mesh rebuilds and the frozen copy fades out. Logs: `mesh_frozen` (was `mesh_shed`),
  `rec_adapt` gains `mesh_mode` + `mesh_vertices`.
- **Scans** (HUD button next to Object scan; hidden while recording): `Sources/Scans/`. Browse whole-house map versions
  (newest `site` version first; older versions at the end), walks and object scans from `GET /v1/phone/scans` (API
  §8.9) with thumbnails. A scan opens in **Mesh** (the server-built `mesh.usdz` — same coordinates as `mesh.glb` — in
  RealityKit with an unlit, back-face-culled material, so from outside you look into the rooms), **Splat** (native
  Metal Gaussian splats via **MetalSplatter 1.0.1**, MIT, scier/MetalSplatter; the phone splat cut to 1.5 M / 1.0 M /
  0.5 M splats by device RAM and further by `os_proc_available_memory`, records decoded straight into the GPU buffer),
  **AR dollhouse** (own AR session; tap a table/floor, the house becomes ~60 cm across, an object stays 1 : 1; pinch /
  twist / drag) and **AR 1:1** (stub until relocalization, plan P2). Orbit / Walk camera shared by Mesh and Splat, walk
  points ◀ n/N ▶ (views.json / paths, as the web viewer §8.7), Measure on the mesh (ray casts on the mesh's triangles,
  never the splat), double-tap = focus / walk there. A mesh not built yet is requested (`POST …/prepare`) and polled.
  Offline cache in Application Support/scans (the last viewed scan is never evicted; others LRU above 600 MB); the
  main AR session pauses while Scans is open. Logs: `scans_list`, `scan_open`, `scan_download`, `scan_mesh_loaded`,
  `scan_splat_loaded`, `scan_mem` (every 10 s, footprint/available/limit like the recorder), `scan_close`.
  Deployment target is now iOS 18 (MetalSplatter). Pure logic + tests: `SnailSightCore/{ScanCatalog,ScanViewMath}.swift`,
  `ScanTests.swift` (catalogue order, frames, cameras, walk points, grid ray casts vs brute force, dollhouse fit, cache
  eviction, splat budget + .splat record decode).

**9.8 P2b (localize in the whole-house map, sim bodies in the map frame; plan §7 P2b, API §5.6/§5.7)**:
`Sources/Places/MapLocalizer.swift` finds the phone in the map server's master `site` map by itself at launch (one
keyframe/s — RGB 1024×768, LiDAR depth + confidence, intrinsics, ARKit pose — to `POST /v1/localize` until LOCKED, then
12 refinements), in parallel with the 9.7 place relocalization (whose cached map alignment is applied at once and
cross-checked). The place line leads with **LOCALIZED · whole house v7 · 1.8 s** / **FINDING YOU**. Sim bodies live in
the map (`/v1/maps/site/entities`): restored from it on a lock (kept when the place restore agrees within 15 cm),
migrated into it when it has none, updated on every spawn / move / delete. Pure maths + wire types:
`SnailSightCore/MapFrame.swift`, tests `MapFrameTests.swift`. Logs: `maploc_*`, `map_entities_*`, `map_restore`.

**9.9 (owner feedback on 9.8.91)**:
- **Scans → Fly** (Orbit | Fly): the minimalist control is back as the default ("Simple": one move stick, drag anywhere
  to look, ▲▼ height, pinch / two fingers still move; walls / ghost, speed preset, level and Home as small icons). The
  9.8 dual-stick drone is the optional **Advanced** scheme (gamepad toggle, remembered). Collision, walk points and the
  minimap stay; the minimap is small (108 pt) and folds into a map button. `FlyScheme` / `FlyControl` in ScanDrone.swift.
- **Easy cube delete**: tap a placed cube → its bar with ✕; long-press a cube (placed or sim block / crate / box) = delete; More ▸
  Cubes… lists placed cubes + sim cubes (blocks, crate, box; `SimCubes.isCube`) with swipe-to-delete; More ▸ Clear cubes
  (separate from Clear sim and Clear measures). Every deletion shows **Undo** for 5 s (`UndoBuffer`, `CubeLedger`).
  Logs: `cube_select`, `cube_delete`, `cube_clear`, `sim_delete`, `undo_delete`.
- **Physical animals**: each animal is a RealityKit body (capsule or box from its size × Sim scale, `AnimalShape`),
  kinematic while its brain drives it and a dynamic rigid body when knocked (`Impact`: momentum transfer from a
  thrown / rolled / swung object, the robot, another knocked animal; a **kick** = quick flick on the animal (`Kick`); a
  drag released with speed = a **toss**). Big hits tumble, small ones slide upright; it collides with the scene mesh,
  furniture, objects and other animals, can be knocked off a table, then stands back up where it lands and resumes its
  behaviour (`Knock` state machine). Logs: `sim_hit` (source, by, dv, impulse_ns, knocked), `sim_knock_settle`,
  `sim_recover` (drop_m, tumbled).
- **Elevated surfaces**: spawn / Move / drag targets are the first LiDAR-mesh surface under the + or finger whose normal
  is within 25° of up (`SurfaceClass`: floor / elevated / wall / ceiling / steep; walls are refused with a hint). Animals
  stand and walk on table tops and shelves without walking off the edge; a fleeing one may hop down up to 2.5 body
  heights (`ElevatedNav`); tossed ones settle on whatever they hit. RobosnailBob goes on a table only if its footprint
  fits there (a NavGrid at the table height) and it weighs ≤ 15 kg at the current scale (`RobotSurface`). Log
  `sim_surface`.

**10.2 (localization pill + mesh-only mapping, 2026-10-15)**: owner: "I may open the app in any place, but don't
necessarily want to record. Can I have the localized as a status pill at the top margin to see if it's localized?
Otherwise do a non-splat data collection just for colored mesh?"
- **Always-on localization.** `MapLocalizer` now runs whenever the app is open and a server answers — also while
  recording (half rate; a lock found mid-recording places the sim bodies at Stop) and with the sim off. Cadence
  (`LocCadence`): an attempt every 1 s until locked (6 s once "not in map"), 12 refinements every 8 s, then one refresh a
  minute (×3 when iOS reports serious heat, ×2 while recording). LiDAR depth is switched off between refreshes and back
  on 3 s before the next one, unless mapping / recording / Live map keep it on.
- **Top pill** (`LocPill`, centred at the top edge): green "LOCALIZED · whole house v10 · mesh · ±2 cm" (method =
  mesh-refined / visual / saved place; ± = max(fix spread, mesh ICP RMSE) with a per-method floor of 2 / 3 / 5 cm),
  amber "FINDING YOU… 12 s", grey "OFFLINE" or "NOT IN MAP" (no match for 45 s / 25 tries, or the server has no such
  map). Tap: method, last fix age, error estimate, map version, server; **Retry** (new search, or one refinement now),
  **Pick place**, Map mesh toggles.
- **Map mesh** (More ▸ Mapping, Settings; off at launch; optional **Auto when localized**, with a 2 min grace after a
  lost lock): `Sources/MeshMap/MeshMapper.swift` + `SnailSightCore/MeshMap.swift`. Collects LiDAR depth + confidence +
  a 256×192 colour image at ≤ 2 Hz (only after 10 cm / 8° of motion), a sharp 1920×1440 keyframe every ~0.75 m or 20°
  (first frame with ≤ 2 px predicted motion blur, ≤ 6 px after 1.5 s; Laplacian sharpness attached), ARKit mesh anchors
  (new or grown ≥ 15 %, every 5 s) and the map alignment of every frame + `align` chunks at each lock / refinement. No
  video, no audio. Chunks (`SSMM` framing) are written to Documents/meshmap/<upload_id>/ first, then uploaded one at a
  time (`PUT /v1/meshmap/{id}/chunks/{seq}`, idempotent, resumes after offline / relaunch); stop → `finish` once all
  are acknowledged → the server re-meshes + re-textures only the covered 4 m tiles and publishes a new map version; the
  app polls and says "House map updated · v11". Pauses while recording, in Scans, when critically hot, while tracking
  is limited or past 1.5 GB of unsent data. Status line under the pill: "mapping · 34 MB · 12 kf".

**10.3 (master map first, one status, 2026-10-15)**: owner on 10.0.105, in the bathroom with a bedroom place ("Area 1")
loaded at launch: the top read "Limited · Relocalizing" while the card said "LOCALIZED · mesh · whole house v10" *and*
"RELOCALIZING · Area 1 · 52 s"; the sim was paused and no mesh was built. "Why do I see localized and localizing at the
same time? Usually when it's like this, I need to select the map again."
- **Master-map localization is primary.** Launch and Reset AR always run a clean ARKit session (tracking normal at
  once); `MapLocalizer` finds the phone in the house map. No saved ARWorldMap is loaded at launch any more.
- **Saved places are an accelerator** (`PlaceAssist`, pure + tests): one is tried only when the server has not locked
  within 5 s AND the last accepted server fix (persisted, `LastMapFix`) lies inside that place's mapped box (carried with
  the place's cached alignment, `PlaceEvidence`; 0.75 m slack, same floor). An automatic try gives up after 8 s (a
  picked one after 20 s) and the session re-runs without the world map. Each place is tried once per session.
- **A server lock cancels a saved map still relocalizing** — no re-selecting the map. The lock is carried over the
  session reset (`FrameCarry`: the camera pose just before and just after is the same physical pose; yaw + translation),
  shown as "re-anchored ±8 cm" and confirmed by an immediate server re-check (bodies move only if it is > 10 cm off).
  Picking a place while the house map holds a lock is refused with a note (it is the better fix).
- **One status.** The top pill derives ONE state from the server lock and ARKit tracking: LOCALIZED · whole house v10 ·
  mesh · ±4 cm / FINDING YOU… / TRACKING LIMITED — move slowly / OFFLINE / NOT IN MAP. A saved place is a detail row
  ("Saved place Area 1: also trying its AR map · 4 / 8 s") and the status pill only names the place, in neutral colours.
  The status card's headline is the same pill text.
- **Saved places' animals live in the house map** (`PlaceMigration`): on every lock, place entities the map has never
  had (and bodies placed here without a lock) are written with `PUT /v1/maps/site/entities/{id}` in the map version
  their alignment was locked against (the server carries them to the current one), then the lock is applied again.
  Ids seen in the map are remembered (`map_known.json`) so a body deleted from the map is not resurrected.
- Place bookkeeping: a place's cached map alignment is written only when the session's ARKit frame IS the place's
  (matched, or saved here) — 10.2 could cache an alignment from a session that was still relocalizing. Bodies placed
  while the house map holds a lock no longer auto-create "Area N" places. Logs: `reloc_try`, `reloc_abort`
  (reason timeout / server_locked / cancelled, keep_lock), `maploc_carried`, `maploc_confirmed`, `map_migrate`.

**11.0 (localize first, then stream tiles: live shared-map plan M2, 2026-10-17)**: the house in AR no longer comes as
one whole-house mesh. After a real server lock the app streams only the tiles near you from the map server's living-map
tileset (3D Tiles 1.1, map frame; per-tile USDZ blobs, content-addressed and immutable).
- **No map bytes before the lock.** Nothing (tileset, tiles, rooms / objects docs) is fetched until `/v1/localize`
  locks. MapFollower only tracks the head (tiny JSON) and swaps / toasts as before; it no longer prefetches the
  collision mesh or the whole-house usdz. The whole-house `collision.obj` is used only for the Sim X-ray occluder
  (after a lock, while X-ray is on). Scans still downloads a version's usdz when the owner opens it.
- **Tile selection** = `SnailSightCore.TileSelect`, an exact port of the server's reference (`tileselect.py`): distance
  to each tile's box with the vertical part × 3, refine while closer than the tile size (4 m leaves ≤ 8 m, parents
  farther, nothing past 40 m), heading prefetch (lookahead min(speed × 5 s, 10 m)), 600 MB budget (near ≤ 350 MB,
  mid ≤ 150 MB by the tiles' `mem`, farthest cut first), REPLACE with the parent kept until its children are loaded.
- `Sources/AR/TileStreamer.swift`: every 0.5 s select; download nearest first, ≤ 3 at a time, sha256-checked into
  `Caches/tiles/<sha256>.usdz` (2 GB LRU, `TileDiskLRU`), load off the main thread, attach under the map frame turned
  Y-up → Z-up; release what is neither wanted nor drawn. A new `head.tiles.rev` refetches the tileset; unchanged hashes
  cost nothing (old content stays on screen until the new one is loaded).
- **House overlay Model** (textured tiles, unlit) is the new default (one-time migration `ar.house.v11`); Wire / Ghost
  put their materials on the same tiles. **Settings ▸ Raw scan** (default off) draws the raw scan tiles instead of the
  structure variant (walls / floors / ceilings + furniture).
- Localize requests carry `hints` {last_tile, last_level, last_xy, last_pose_age_s} from the last lock (persisted);
  answers' `tile`, `level`, `confidence` are logged.
- Logs: `tiles_start` (variant, rev, since_lock_s), `tile_fetch` (key, bytes, ms, cached), `tile_drawn_first_near`
  (since_lock_s), `tiles_status` every 10 s (drawn, loaded, mem_mb, disk_mb, dl_mb_total, footprint_mb, avail_mb),
  `tile_evict`, `tile_error`, `tiles_unavailable`; `maploc_try` / `maploc_locked` gain tile, level, sigma_cm, sigma_deg.

**11.3 (Room scan, structure layer S4)**: More ▸ Mapping ▸ **Room scan** (LiDAR iPhones, needs the map lock). Apple
RoomPlan runs on the app's own ARSession (`RoomCaptureSession(arSession:)`), so its walls, doors, windows, openings,
floors and furniture boxes are in the ARKit frame the localizer maps with T_map_arkit. The HUD line counts what RoomPlan
has found; tapping again (or leaving the app) builds the room (`RoomBuilder`), and the app uploads the normalized room
(`snailsight-roomplan/1`, `SnailSightCore/RoomScan.swift`), Apple's CapturedRoom JSON and the USDZ export when it is
≤ 8 MB, with the current T_map_arkit, to `POST /v1/maps/site/roomplan`. Spooled to Documents/roomplan first; offline / 5xx
→ resent when the server is back. The server lines the room up with the scanned walls and lets it replace structure
elements only where it scores better. Parametric room only: no images, video or audio. Mesh mapping pauses meanwhile.
Log: `roomscan_start|stop|done|upload|result`.

**12.0 (one sheet, Map, command ring, agent ops, Mesh live)**: the owner-approved UI concepts (2026-10-18), with every
11.3 function kept, only moved.
- **Base layout**: a clean AR view, the localization pill + compact status pill at the top, a right rail (Map · Layers ·
  tap tool, 44 pt), and ONE pull-up sheet (`Sources/UI/MainSheet.swift`, detents in `SnailSightCore.SheetDetent`):
  collapsed = search + Spawn / Room scan / Live map / Record; half = **Near you** (shared + local sim bodies, sim rover /
  drone, cameras from map placements, other agents; nearest first, one primary action each) + **Places** (the house map's
  rooms → the Map; Saved places); full = everything the old bottom toolbar and More menu held (tap tool, view, Sim, House,
  Mapping, Live map, Place, Capture, Session, Settings).
- **Map** (`Sources/Map`): full-screen plan, storey switcher B / 1 / 2 / Yd, the version's floor plan overlay, you,
  bodies, routes, cameras, other agents; tap a body to select it, tap the plan to send it there. **Yard** = robot terrain
  slope shading + no-go, and (server `estimated_world`, API §5.16) surveyed vs estimated coverage (hatched), lidar trees
  (ghost / confirmed / corrected with a line from the estimate), estimated-slope no-go, legend, **Explore gaps**.
- **Command ring** (`CommandRingOverlay`): tapping a body puts its commands (Go to, Follow, Flee, Stay, Roam, Delete —
  what it offers) in a ring around it; the details card below is still the full command bar. Drag-to-trash and Spawn mode
  unchanged.
- **Agent ops** (`AgentOpsPanel`) for a selected sim drone / rover: obstacle-takeover banner, route + layer, altitude /
  canopy strip, Hold · Climb above · Return · Land now. With server `drone_missions` these send the §5.16 orders; without
  it Hold = stop, Return = goto the first-seen spot, Climb / Land are disabled with the reason.
- **Mesh (live)** layer, on by default: this phone's LiDAR wire mesh plus the shared live tiles (API §6b.1) of every agent
  — your own walk with Live map on, other phones, replays, sim rovers / drones — drawn in AR and on the Map as they arrive,
  replaced in place on every rebuild, with a fresh-tile highlight that fades in three steps (`LiveMeshFeed`); base tiles
  the M4 sync swaps in place flash the same way. The downlink no longer needs Other agents / House on, and widens its tile
  box to ±40 m while the Map is open. Logs: `live_mesh_first`, `live_down_stats` (+ mesh_tiles, mesh_mine, mesh_agents),
  `sheet`, `quick_action`, `near_action`, `ring_cmd`, `agent_ops`, `map_open`, `map_scene`, `map_plan`, `map_terrain`,
  `map_estimated`, `estimated_live`, `explore_gaps`, `layer`.
- 12.0.x: drone missions LIVE on the server (`drone_missions`): the ops panel shows the mission line (phase, layer it
  flies over, under / above canopy, AGL, takeovers) and draws the mission path (entity doc `mission`, API §5.9.12);
  Return uses the mission's home. Sim tree statuses (sim ledger) stay out of the Map's real tree layer.

**12.1 (photo-coloured live mesh, faster re-search on a scene change)**:
- **Mesh colour** (Layers ▸ Mesh colour: Photo | Wireframe, default Photo): live tiles from server `snailsight-live` 0.5
  carry per-vertex photo colour (`rgb`, API §6b.1: a weighted running average of the walkers' keyframe colours per 5 cm
  voxel, exposure-normalised). AR draws them as flat-coloured triangles (unwelded, one texel per triangle in a
  nearest-sampled strip, `LiveMeshTile.faceTextured`; fresh tiles tinted green, then settled); the Map's top-down tile
  rasters take the colour of the triangle that wins each cell (`TilePlanRaster.rasterRGBA`). Wireframe, and tiles from
  depth-only agents (Kinect, lidar), keep the amber wire / grey plan.
- **Scene change → fast search** (`LocSceneChange`): unlocked, a light jump > 4x (ambient intensity / exposure time:
  yard → house is 30-100x) or a storey change (ARKit height > 2 m) puts the search back on 0.5 s for 20 s, even while
  recording or "not in map" (a daytime yard → house walk at 6 s x 2 = 12 s took 67 tries / 335 s). Log
  `maploc_scene_change {why, attempts, search_s}`.
- `maploc_locked` logs `T_map_arkit` (row-major 16; the server's phone-lock placement seeds read it).

**12.2 (Mark camera, Camera check)**:
- **Mark camera** (sheet ▸ Mapping or House ▸ Mark camera…): pick a camera / sensor placement (map entities
  `?include=placements`, API §5.7a, nearest first, searchable) or a new one (name + `frigate:` / `ring:` / `ha:` / `kinect`
  source). A crosshair: aim at the physical camera and tap Mark. Each mark is a ray (camera centre + crosshair direction)
  in the MAP frame from the localizer's current T_map_arkit (the lock, not the eased display alignment) with its lock
  quality (`MarkLock` strong / good / weak; no lock = not recorded). Guidance (`MarkGuide`): "step 2 m sideways and mark
  again" (the step grows with the range for 10° of spread). Two or more marks ≥ 10° apart → Locate =
  `POST …/entities/{id}/triangulate` (§5.7b); the point and its 1σ ellipse show in AR as a green sphere plus a ring
  (yellow lines = the marks); Accept = `POST …/triangulate/accept` (the entity moves, `record.position.source
  "triangulated"`, `estimated` false). Within LiDAR range (≤ 5 m) "Use LiDAR point" takes the raycast hit from one mark.
  Fallbacks: no server / no endpoint → the phone's least-squares estimate (`MarkMath.localTriangulate`) and an entity PUT;
  a new placement is created with `PUT …/entities/<slug>-<hex time>`.
- **Camera check** toggle: opens a walk-calibration window (`POST …/cameras/calibration/walk`), posts the localized device
  pose (2 Hz, batches every 5 s, `WalkPoseBuffer`), and every 3 s shows which cameras see you (`GET …/cameras/coverage`
  at your position) and which detected you (the window's recent matched detections). Without those endpoints: a frustum
  test from the placements' pose / yaw / pitch / FOV ("estimated views").
- Logs: `camera_mark`, `camera_triangulate`, `camera_accept`, `camera_mark_start` / `_close`, `camera_check`,
  `camera_view` (cameras in / out of view with your map position).

**12.3 (Map ▸ 3D: the whole colour map, orbit or fly)**: owner 2026-10-20 ("a button on map mode to be able to
manipulate the map in 3d to see the entire 3d color map and float through it", fly like the PC portal).
- Map ▸ **3D** opens `Sources/Map/Map3DView.swift`: a full-screen non-AR RealityKit view over the 2D plan. Our AR session
  pauses while it is up and resumes without reset when it closes (the Scans path; `AppModel.arSuspended` keeps the
  localizer, mesh mapper, Live map and the AR tile streamer from re-running the paused session meanwhile).
- Content: the living map's tiles (structure, or raw with Layers ▸ Raw scan) for the WHOLE site.
  `SnailSightCore.Map3DTiles` covers every root and refines by screen-space error (size / distance) from the virtual
  camera while the refinement fits the 600 MB budget (halved when the OS is short of memory or after a memory warning);
  detail k follows the frame rate (`Map3DQuality`, ~30 fps target); far tiles are evicted first. Blobs come from the AR
  streamer's disk cache (Caches/tiles, by hash; hash-checked downloads go into it) and tiles the AR view already holds
  are cloned (shared mesh + textures). Overlays: the live coloured mesh (Mesh (live)), sim bodies (+ the selected
  route), cameras with their frustums, estimated / corrected trees (nearest 600), the estimated DEM terrain.
- Controls: Orbit (drag, two fingers, pinch; double tap = focus) by default. **Fly** reuses the Scans Fly controller
  (`ViewerCamera`, `DroneDriver` with a new `stepper` hook, `JoystickPad`, `HoldButton`) driven by
  `SnailSightCore.Map3DFly`: left stick moves in the camera frame, drag anywhere else looks (pitch clamped ±75°), ▲▼
  climb, Walk 1.4 / Run 4 / Drone 8 m/s (walk + run follow the floor at eye height 1.6 m, the drone stays 0.4 m
  above it), optional gyro look. Level slicer B / 1 / 2 / Yd hides the storeys above; Reset view; tap a body = select it
  with the same command ring (`CommandRingOverlay(projector:)`), tap the ground = send the selection there.
- Logs: `map3d_open`, `map3d_fly`, `map3d_fps` (every 10 s: fps, footprint_mb, drawn / loaded / wanted / inflight
  tiles, mem_mb, budget_mb, k, slice), `map3d_tileset`, `map3d_first_tiles`, `map3d_select`, `map3d_goto`,
  `map3d_tile_error`, `map3d_mem_warning`, `map3d_close` (max_mb, min_fps); `ar_paused` / `ar_resumed` why `map3d`.

**12.4 (View presets + 3D world switch)**: owner 2026-10-20 ("view live camera plus animals, and turn off the layer where
I see the 3d generated world").
- Layers now opens with a **3D world** master switch (hides/shows ALL rendered world geometry in AR: house tiles in any
  style + labels/objects, live mesh incl. the phone's own wire mesh, terrain; individual settings are kept, so switching
  it back on restores them; sim bodies, paths, cameras and agents are not "world"), then a **View** row: Camera +
  animals / Full world / Custom (any manual toggle -> Custom; Full world restores the previous full set; persisted).
  The same presets are a quick chip in the sheet's search row. House overlay is a picker row right under Structure.
- While the world is off nothing is fetched: no house tiles (loaded tiles are freed after 30 s hidden; the disk cache
  makes coming back cheap), no rooms/objects docs (unless X-ray needs the scene), no terrain grids, and the live
  downlink only runs for agents. Core: `ViewPresets.swift` (LayerSnapshot, ViewPresetState, WorldGate) + 8 tests.
- Logs: `layers_preset` (preset + the applied toggles), `world_toggle` (on, preset, house, mesh_live).

**12.5 (Drive the RC car + no accidental cubes)**: owner 2026-10-20 ("If I select a RC car, let me control it like I do
the robot"; "Don't let the cube be my default when I click on the screen … a measure point").
- **RC car** (server catalog `rc_car`, group Vehicles, API §5.9.10 drivable bodies): Spawn ▸ Robot · Vehicles ▸ RC car
  (shared sim). Drawn with the bundled Kenney toy car stretched to 0.45 × 0.16 × 0.25 m at the body's sim scale. The same
  joystick as the robot: stick up/down = throttle, left/right = steer (+ = right), WS `cmd` `drive {throttle, steer,
  tank}` at 10 Hz, ttl 0.5, one zero on release (`DriveStick`, `DriveSender`, `DriveRoute`); a **Tank** toggle sends
  `tank: true` (robot-like turning). The robot keeps its v / w teleop. Drivable = catalog `drivable`, else kind robot /
  rc_car / sim rovers. Ring for drivable bodies: Drive · Go to · Follow · Stop · Delete (Drive opens the stick; its ✕
  hides it until the next selection). 12.4 already decoded `rc_car` (kind is free text, `cat: robot`), drawing it as a
  RobosnailBob model and driving it through legacy v / w.
- **Tap tool**: every launch starts on **Select / Inspect** (never persisted). A tap selects a body or a house object;
  otherwise it drops a temporary **measure point** (distance from the phone, height above the floor, storey; a second
  point shows A→B; both fade 10 s after the last tap; nothing saved). Cubes only with the Cube tool picked, and each new
  cube shows an **Undo** toast. Core `TapTool.swift` (TapToolState, MeasurePoints).
- 12.4 screenshot fixes: a new selection (or none) clears every overlay the previous one drew (Robot path footprint +
  dotted path, goal markers, route ribbon: `SelectionOverlays`); the Robot path footprint is the body's own (server dims,
  else 0.82 × 0.62 × sim scale: 0.41 × 0.31 m at 50 %, was always 0.82 × 0.62) and its colour comes from
  `/sim/nav/query?scale&kind` when the shared sim runs; Follow me keeps sending `agent_pose` at 2 Hz while localized
  (12.4 dropped the follower on the snapshot already in flight or on a stale entity-doc behaviour: `FollowPoseTracker`).
- Logs: `tap_tool`, `measure_point`, `cube_undo`, `drive_open`, `drive_start` / `drive_release`, `drive_tank`,
  `selection_overlays`; `terrain_path` gains scale / kind / footprint_m / sim_fits.

**12.6 (Articulated doors)**: server API §8.12 (door entities with a hinge and a measured leaf angle) and §6b.4 (live door states).
- Each real door (status `door`) is drawn as a thin hinged leaf (leaf width x height x 4 cm) at its latest angle, in AR
  (under the map frame, with a "L1-06 open 82°" label), on the Map plan (hinge dot + leaf line per level, label when
  zoomed in) and in Map 3D. Colour: closed blue, ajar amber, open green. Unknown hinge or unknown state = closed in the
  doorway; openings and passages are not drawn.
- Live: `door` messages on the downlink's changes layer replace the door's state in place (`door_live` log); a door the
  list does not know triggers a re-read. The list (`GET /v1/maps/{map}/doors`) re-reads every 2 min and on a map version change.
- **Doors** layer toggle: Layers sheet, Settings, sheet quick toggles, Map chip, Map 3D tool. It is part of the 3D world
  master switch (`WorldGate.doors`) and of the Camera + animals / Full world presets (old stored presets decode with doors on).
- Core: `Doors.swift` (DoorsDoc/DoorInfo, DoorEvent, DoorLeaf.make = hinge transform from hinge.point + jamb + frame.t +
  swing.direction + angle_deg, DoorSet) + 7 DoorsTests; logs `doors_load`, `door_live`.

**12.7 (Drive mode: twin sticks, turret, gamepad, first-person 3D)**: owner 2026-10-22 ("It's hard to see and drive at the
same time. I want the right thumbstick and I want that to control turret orientation" · "If you're doing a full screen
drive mode, give me teleop control like in the robosnailbob project, and give first person view with 3d world"). Server:
API §5.9.10 Turret + Controller lease (live on :8904).
- **Drive mode**: Drive (ring / bar / gamepad L3) opens a full-screen driving layout: the command ring, O2 ops card,
  selection bar, rail, pills and the sheet are hidden; a slim strip shows the body, speed (+ throttle %, TURBO), a status
  line (you drive / driven by … / server link / nav problem / storey / pad), AR | FPV | Chase, Exit and STOP. Exit restores
  the previous layout exactly (sheet detent, selection, expanded cards) and sends `cmd {release: true}`. Core
  `DriveMode.swift` (DriveModeLayout, DriveView, DriveChrome, the quick wheel's items).
- **Twin sticks, RoboSnailBob HUD parity** (core `TeleopMap.swift`): left stick drives (Tank toggle for the rc_car), right
  stick aims the turret by RATE (yaw from the horizontal, pitch from the vertical; the turret holds when let go; double-tap
  recentres). Both sticks are one UIKit multi-touch pad, each touch tracked on its own, 124 pt sticks. ONE 10 Hz WS message
  carries `drive` + `turret` (ttl 0.5); each stick's release sends its one zero. HUD feel: the HUD's 0.5 / 0.75 m/s
  (turbo +50 %) become throttle / steer fractions 0.667 normal / 1.0 turbo of the server's full drive (robot at 50 %
  scale: 0.133 / 0.2 m/s, 0.8 / 1.2 rad/s; rc_car 2 / 3 m/s); release = ×0.6 every 50 ms until < 0.03 (≈ 350 ms from full
  stick), then zero; STOP = zero + `stop` now (lease kept, sticks ignored until let go); Turbo hold; quick wheel (hold
  L2 or the wheel button): Stop · Centre · View · Tank · Follow me · Go to · Exit · Take over.
- **Gamepad** (GameController; the owner's GameSir G8 Galileo): core `GamepadMap.swift` = the HUD's presets (default /
  southpaw / triggers: throttle = R2 − L2 / dpadcam) and function map: A select · B E-stop / cancel · X view · Y take over ·
  L1 / R1 previous / next drivable body · L2 hold wheel · R2 hold turbo · L3 drive mode on / off · R3 turret centre ·
  Select controller mode · Start menu (sticky wheel) · D-pad turret ±10° / ±15°. Deadzone 0.15 (the HUD's dz()),
  persisted (UserDefaults `drive.gamepad`), A / B not rebindable. Controller mode hides the on-screen sticks (auto at the
  first pairing; the controller badge brings them back).
- **Turret on the model**: RobosnailBob's lidar + a head camera are a separate node yawing about `origin_m` with a pitch
  child at `camera_m`, driven by the snapshot `turret {yaw, pitch}` through `TurretTrack` (extrapolated ≤ 0.15 s at the
  measured rate, τ 0.12 s error easing, spec clamps). In AR a red aim line shows where the turret points.
- **FPV / Chase** (`Sources/Drive/DriveViewer.swift`): a non-AR RealityKit view from `TurretCamera.pose` (exactly
  `sim/vehicle.py turret_camera`; map → viewer `(x, z, −y)`) or behind it (`TurretCamera.chase`: 0.4 + 1.6·scale back,
  0.2 + 0.6·scale up), every frame from the same interpolated pose + head as the AR bodies. World = the 12.3 Map 3D tile
  loader (SSE LOD centred on the driven camera, 600 MB budget, k adapted to ~30 fps) + overlays (live mesh, doors,
  cameras, trees, terrain, route); the bodies are the AR layer's own sim node borrowed into the scene (same models,
  clips, turret heads; the driven body is hidden in FPV). Minimap inset (the storey's plan, bodies, the phone, the look
  cone). AR is paused while FPV / Chase is up (one renderer at a time, as Map 3D), so a LIVE camera PiP is impossible: the
  PiP is the AR view's last frame (tap it to go back to AR). rc_car: no server turret, the right stick pans the app's own
  view in FPV / Chase (`ViewPan`) and is hidden in AR.
- **Lease fix** (the owner's "RobosnailBob is driven by another device" while he was the only driver): the server sends
  `lease {granted: false, owner: null}` on every RELEASE (2 s after the app's own last command); ≤ 12.6 flashed it.
  `LeaseTracker`: only `granted: true` for someone else or a 409 means another driver; the strip names the holder
  ("driven by portal (cop.snail)") with **Take over** (resend with `force: true`). 409 details are dicts now (both shapes
  handled).
- Logs: `drive_mode_enter` / `_exit`, `drive_view`, `drive_estop`, `drive_takeover`, `drive_wheel`, `drive_turbo`,
  `drive_goto`, `turret_aim` / `turret_centre` / `turret_step`, `gamepad_connect` / `_disconnect`, `gamepad_preset`,
  `controller_mode`, `sim_lease` / `sim_lease_refused`, `fpv_open` / `fpv_fps` / `fpv_close`.
- Core tests: TurretTests (camera vs the Python reference), TeleopMapTests, GamepadMapTests, DriveModeTests (incl. a
  release event never produces "driven by another").

**12.8 (Runtime sim content: lab characters without an app release)**: owner 2026-10-23 (characters customised in the
Helix lab should reach the 3D world "without any extra steps"). Until 12.7 every spawnable model was bundled
(`Resources/SimModels`), so a new character needed an app release.
- **Runtime catalog** (`Sources/Sim/SimContentStore.swift`): `GET /v1/sim/content` (map server) lists runtime items in the
  bundled `catalog.json` item shape plus `blobs` (file name → sha256 + bytes), `clip_info` ({action, loop, duration_s}
  per clip) and `origin`. Every phone file (clip USDZ + thumbnail; the `.glb` web twin is skipped) is fetched once from
  `/v1/sim/content/blobs/<sha256>.<ext>`, its sha256 verified (CryptoKit) before an atomic move into Application
  Support/SimContent/blobs (excluded from backup). An item shows only once ALL its files are on disk (never half a
  character). The last document is kept on disk, so the picker works offline; blobs of the current and the previous
  revision are kept, older ones pruned. Refresh: launch, every reconnect, opening the spawn picker (5 s debounce), and a
  shared-sim body whose kind is unknown (at most every 30 s); bodies drawn as boxes get their model once it arrives.
  `If-None-Match` with the last rev (304 = unchanged).
- The ONE catalog the picker, the local sim and the shared-sim bodies read is the bundled catalog merged with the ready
  runtime items (`SimContent.merge`: a runtime item replaces a bundled one with the same key). Model and thumbnail
  lookups use the cached blob first, else the bundle. Helix lab characters are no longer bundled.
- **Gestures**: runtime characters carry one-shot clips (wave, think, shrug, bow, …; `clip_info.loop == false`). A shared
  sim body plays any clip the server names when the item has it (`SimSharedClip.key`), loads gesture models on first use
  only, plays them once and holds the last frame until the server's clip changes (phase from `clip_t0`, never wrapped).
  The selection bar shows **Gesture** for such bodies (a chooser of the item's gestures → `cmd {gesture}`).
- Logs: `sim_content_sync` {reason, rev, items, rejected, fetched, bytes, ms, unchanged?, error?},
  `sim_content_blob_fail` {sha, reason}, `sim_gesture` {kind, clip, id}.
- Core: `SimContent.swift` (doc/blob refs/clip info, phone files, missing/ready planner, merge, gestures, portable
  SHA-256 + CryptoKit), the `gesture` command; SimContentTests.

**12.9 (live models)**: EVERY sim model (animals, objects, thumbnails, the RC car's toy car, plus low-poly RobosnailBob and
drone parts, `agents` in the document) comes from the map server's one catalog `GET /v1/sim/content`; a model change needs
no app build. `SimContentStore` fetches it at launch, on reconnect and on the sim socket's `catalog` event, downloads changed
blobs in the background (spawned bodies' kinds first, then changed, recents, the rest; 600 MB budget, LRU eviction, sha256
verified), exposes an item only when ALL its files are cached (the old version stays until then) and publishes a diff.
`ServerSimClient` builds the new `ServerSimBody` off-tree and replaces the old one when its first clip loaded (same id,
selection and label). `SimModelLibrary` keys templates by blob name. The bundle keeps only the fox (offline fallback);
a body without a model draws a box that is swapped when it arrives. "Models updating… n/m" pill on the Sim HUD and in the
spawn picker. Core: `SimLive.swift` (diff, cache policy, fallback, agents, catalog event) + `SimLiveTests`. Logs:
`sim_content_event`, `sim_content_sync` (+ changed/removed/evicted/cache_bytes), `sim_content_swap(ped)`.

**12.10 (sharp live keyframes, mapping v3 plan)**: owner: "multiple walks and mapping runs degrades the appearance of the
environment rather than improving it ... I need a way to explore and generate continuous map improvement." Root causes
and the phased fix: `docs/MAPPING-V3-PLAN.md`. App part shipped now:
- **Blur-gated live keyframes** (`LiveGate.decide`): a due keyframe predicted blurrier than 2 px waits for a sharper
  frame (≤ 6 px after 0.2 s, anything after 0.4 s; the 2 Hz rate holds). Same blur model and thresholds as the Map mesh
  keyframes. The live stream used to send the first frame after each tick, often a smeared turn.
- Live keyframe header: optional `blur_px`, `exposure_s` (extra keys; the server ignores them until it ranks by them).
- Log `live_off` + `blurry_frames`. Tests: `LiveGateTests.testBlurHold`, `testHeaderQualityKeys`.

**12.11 (people masked out of the live map)**: each live keyframe runs Vision person segmentation (balanced, on the
encode queue, ≤ 2 Hz) and sends a 0 / 255 `mask_png` blob when ≥ 0.2 % of the image is a person. The server (snailCOP
d77a3b2) zeroes those depth pixels at decode, so people walking through never become ghosts in the mesh, colour smears
or "changes", and are not promoted. No AR configuration change. Core: `LiveMask.binarize` (+ test). Log `live_off` +
`masked_frames`.

**12.12 (live mesh no longer covers the house)**: with House = Model, a live mesh tile (5 cm voxels, one colour per
triangle) is hidden wherever a textured house tile is drawn on the same 4 m cell (leaf or parent), unless a change
marker (something moved) lies in that cell. New territory and Wire / Ghost styles still show the live mesh. Core
`LiveOverBase` (+ tests). Log `live_mesh_under_base {hidden, tiles}`.

**12.13 (ghosts of moved objects hidden in AR)**: owner: "a lot of objects that won't disappear that used to be in another
place, like moved chairs". The old chair is in the textured house tiles until the server promotes the removal (another
session must confirm it) and rebuilds the tile. The live change detector already CONFIRMS the empty space, so every active
`removed` region from the downlink becomes an occlusion box in AR (`GhostMasks`: padded 20 cm like the server's promotion
mask, starting 3 cm above the region's bottom so the floor stays): the base geometry inside is not drawn and the camera
shows the room as it is. The box is removed when the server clears the region (object put back). Side effect: overlay
content right behind a box (a wall) also shows the camera image there. Log `ghost_masks {boxes}`. Core + tests.

**12.14 (moved objects leave the house map)**: the live `bye` carries `recorded` (true when a capture was recorded while
the stream existed). The server (snailCOP 825c15b) promotes a stream whose phone recorded nothing after 2 min instead of
waiting 30 min for an upload that never comes, and a removal confirmed by one session in ≥ 8 keyframes over ≥ 60 s now
promotes on its own (was: a 2nd session or agent required), so a moved chair leaves the base tiles at the next tile
rebuild. Log `live_bye` + `recorded`.

**12.15 (12.13 ghost boxes removed)**: owner: "I don't want to clutter the map with invisible boxes. I want direct and
immediate map updates." The AR occlusion boxes of 12.13 are gone (reverted). The map itself now changes instead: the
server's live editor (snailCOP `liveedit.py`) edits the shared base tiles as soon as a change is confirmed, and the app
swaps the held tiles in place through the existing M4 tile sync (no app code needed for that).
