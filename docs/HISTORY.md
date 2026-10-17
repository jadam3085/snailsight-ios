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
