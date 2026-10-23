# SnailSight sim models: sources and licences

12.9: ONLY the fox is bundled (offline fallback); every other model is served live by the map server (GET /v1/sim/content; full table in snailCOP tools/ilidar_build/sim_models/ATTRIBUTION.md). Bundled for the SnailSight AR sim (catalog `catalog.json`, thumbnails `SimThumbs/<key>.png`). No model here was
built by hand: every one is a free CC0 / CC-BY asset-pack model, fetched at a pinned commit by
`tools/ilidar_build/fetch_sim_assets.py` (sha256 of every file in `tools/ilidar_build/sim_assets.lock.json`;
jam-ready-assets mirror commit `bdce326b2d7eee85524c08c751faf4804d453f3d`), converted by `tools/ilidar_build/build_sim_assets.py`
(Blender 5.1 headless: face +X, real-world size, feet at 0, transforms APPLIED into the skeleton/meshes,
y-up USDZ, one clip per file) and measured bake-skinned by `tools/ilidar_build/verify_sim_assets.py`.
`<key>_<clip>.usdz` is one animation clip; `<key>.usdz` is a static model (objects, or an animal with no idle).
The licence texts as shipped with each pack are in `licenses/` (Xcode copies them flat as `<pack>.txt`).

| Key | Files | Source model | Pack / author / URL | Licence (text) | Clip actions (source → clip) |
|---|---|---|---|---|---|
| fox | `fox_idle.usdz`, `fox_walk.usdz`, `fox_run.usdz` | `fox.glb` | PixelMannen, tomkranis, AsoboStudio, scurest, *Khronos glTF Sample Assets (Fox)*, https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/Fox | CC0-1.0 model (PixelMannen); rigging + animation CC-BY-4.0 (tomkranis) (`licenses/khronos-gltf-sample-fox.txt`) | `Survey` → idle, `Walk` → walk, `Run` → run |

Attribution (CC-BY 4.0): "Fox" rigging and animation by tomkranis, https://sketchfab.com/tomkranis, licensed under
CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Low-poly fox model by PixelMannen (CC0). glTF conversion
by AsoboStudio and scurest. Changes: re-oriented, scaled and converted to USDZ.

The glTF conversion of the Khronos Fox by @AsoboStudio and @scurest is itself CC BY 4.0 (Khronos sample README,
`licenses/khronos-gltf-sample-fox.txt`); the credit above covers it.

RobosnailBob is **not** a mesh file. The app draws it at runtime from the robot's own URDF dimensions
(`RoboSnailBob/src/robosnailbob-bringup/urdf/tank_robot.xacro`), as the snailCOP Garage "URDF look" does
(`Sources/Sim/SimEntities.swift`).

Note: the console `MANIFEST.json` lists the fox as plain CC0. The CC-BY 4.0 rigging/animation credit above is the
correct one per the Khronos sample's README; fix the manifest the next time it is edited.
