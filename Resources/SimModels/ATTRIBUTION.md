# SnailSight sim models: sources and licences

Bundled for the SnailSight AR sim (catalog `catalog.json`, thumbnails `SimThumbs/<key>.png`). No model here was
built by hand: every one is a free CC0 / CC-BY asset-pack model, fetched at a pinned commit by
`tools/ilidar_build/fetch_sim_assets.py` (sha256 of every file in `tools/ilidar_build/sim_assets.lock.json`;
jam-ready-assets mirror commit `bdce326b2d7eee85524c08c751faf4804d453f3d`), converted by `tools/ilidar_build/build_sim_assets.py`
(Blender 5.1 headless: face +X, real-world size, feet at 0, transforms APPLIED into the skeleton/meshes,
y-up USDZ, one clip per file) and measured bake-skinned by `tools/ilidar_build/verify_sim_assets.py`.
`<key>_<clip>.usdz` is one animation clip; `<key>.usdz` is a static model (objects, or an animal with no idle).
The licence texts as shipped with each pack are in `licenses/` (Xcode copies them flat as `<pack>.txt`).

| Key | Files | Source model | Pack / author / URL | Licence (text) | Clip actions (source → clip) |
|---|---|---|---|---|---|
| deer | `deer_idle.usdz`, `deer_walk.usdz`, `deer_run.usdz`, `deer_eat.usdz` | `Stag.gltf` | Quaternius, *Quaternius Ultimate Animated Animals (Stag)*, https://quaternius.com/packs/ultimateanimatedanimals.html | CC0-1.0 (`licenses/quaternius-animated-animals.txt`) | `Idle` → idle, `Walk` → walk, `Gallop` → run, `Eating` → eat |
| fox | `fox_idle.usdz`, `fox_walk.usdz`, `fox_run.usdz` | `fox.glb` | PixelMannen, tomkranis, AsoboStudio, scurest, *Khronos glTF Sample Assets (Fox)*, https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/Fox | CC0-1.0 model (PixelMannen); rigging + animation CC-BY-4.0 (tomkranis) (`licenses/khronos-gltf-sample-fox.txt`) | `Survey` → idle, `Walk` → walk, `Run` → run |
| rabbit | `rabbit_idle.usdz`, `rabbit_walk.usdz`, `rabbit_run.usdz`, `rabbit_eat.usdz` | `animal-bunny.glb` | Kenney, *Kenney Cube Pets 2.0 (bunny)*, https://kenney.nl/assets/cube-pets | CC0-1.0 (`licenses/kenney-cube-pets.txt`) | `idle` → idle, `walk` → walk, `run` → run, `eat` → eat |
| dog | `dog_idle.usdz`, `dog_walk.usdz`, `dog_run.usdz`, `dog_eat.usdz` | `ShibaInu.gltf` | Quaternius, *Quaternius Ultimate Animated Animals (Shiba Inu)*, https://quaternius.com/packs/ultimateanimatedanimals.html | CC0-1.0 (`licenses/quaternius-animated-animals.txt`) | `Idle` → idle, `Walk` → walk, `Gallop` → run, `Eating` → eat |
| cat | `cat_idle.usdz`, `cat_walk.usdz`, `cat_run.usdz`, `cat_eat.usdz` | `animal-cat.glb` | Kenney, *Kenney Cube Pets 2.0 (cat)*, https://kenney.nl/assets/cube-pets | CC0-1.0 (`licenses/kenney-cube-pets.txt`) | `idle` → idle, `walk` → walk, `run` → run, `eat` → eat |
| bird | `bird_idle.usdz`, `bird_walk.usdz`, `bird_run.usdz`, `bird_eat.usdz` | `animal-parrot.glb` | Kenney, *Kenney Cube Pets 2.0 (parrot)*, https://kenney.nl/assets/cube-pets | CC0-1.0 (`licenses/kenney-cube-pets.txt`) | `idle` → idle, `walk` → walk, `run` → run, `eat` → eat |
| cow | `cow_idle.usdz`, `cow_walk.usdz`, `cow_run.usdz`, `cow_eat.usdz` | `Cow.gltf` | Quaternius, *Quaternius Ultimate Animated Animals (Cow)*, https://quaternius.com/packs/ultimateanimatedanimals.html | CC0-1.0 (`licenses/quaternius-animated-animals.txt`) | `Idle` → idle, `Walk` → walk, `Gallop` → run, `Eating` → eat |
| horse | `horse_idle.usdz`, `horse_walk.usdz`, `horse_run.usdz`, `horse_eat.usdz` | `Horse.gltf` | Quaternius, *Quaternius Ultimate Animated Animals (Horse)*, https://quaternius.com/packs/ultimateanimatedanimals.html | CC0-1.0 (`licenses/quaternius-animated-animals.txt`) | `Idle` → idle, `Walk` → walk, `Gallop` → run, `Eating` → eat |
| sheep | `sheep_idle.usdz`, `sheep_walk.usdz`, `sheep_run.usdz`, `sheep_eat.usdz` | `sheep.glb` | Quaternius, *Quaternius farm animals (Sheep, poly.pizza/m/rgJXF570ZK)*, https://poly.pizza/m/rgJXF570ZK | CC0-1.0 (`licenses/quaternius-farm-animals.txt`) | `AnimalArmature&#124;AnimalArmature&#124;AnimalArmature&#124;Idle` → idle, `AnimalArmature&#124;AnimalArmature&#124;AnimalArmature&#124;Walk` → walk, `AnimalArmature&#124;AnimalArmature&#124;AnimalArmature&#124;Run` → run, `AnimalArmature&#124;AnimalArmature&#124;AnimalArmature&#124;Idle_Eating` → eat |
| pig | `pig_idle.usdz`, `pig_walk.usdz`, `pig_run.usdz`, `pig_eat.usdz` | `pig.glb` | Quaternius, *Quaternius farm animals (Pig, poly.pizza/m/u35l6uP5vj)*, https://poly.pizza/m/u35l6uP5vj | CC0-1.0 (`licenses/quaternius-farm-animals.txt`) | `AnimalArmature&#124;AnimalArmature&#124;AnimalArmature&#124;Idle` → idle, `AnimalArmature&#124;AnimalArmature&#124;AnimalArmature&#124;Walk` → walk, `AnimalArmature&#124;AnimalArmature&#124;AnimalArmature&#124;Run` → run, `AnimalArmature&#124;AnimalArmature&#124;AnimalArmature&#124;Idle_Eating` → eat |
| chicken | `chicken_idle.usdz`, `chicken_walk.usdz`, `chicken_run.usdz`, `chicken_eat.usdz` | `chicken.glb` | Quaternius, *Quaternius farm animals (Chicken, poly.pizza/m/ineV9pU5VL)*, https://poly.pizza/m/ineV9pU5VL | CC0-1.0 (`licenses/quaternius-farm-animals.txt`) | `CharacterArmature&#124;Idle` → idle, `CharacterArmature&#124;Walk` → walk, `CharacterArmature&#124;Walk` → run, `CharacterArmature&#124;Bite_Front` → eat |
| alpaca | `alpaca_idle.usdz`, `alpaca_walk.usdz`, `alpaca_run.usdz`, `alpaca_eat.usdz` | `Alpaca.gltf` | Quaternius, *Quaternius Ultimate Animated Animals (Alpaca)*, https://quaternius.com/packs/ultimateanimatedanimals.html | CC0-1.0 (`licenses/quaternius-animated-animals.txt`) | `Idle` → idle, `Walk` → walk, `Gallop` → run, `Eating` → eat |
| donkey | `donkey_idle.usdz`, `donkey_walk.usdz`, `donkey_run.usdz`, `donkey_eat.usdz` | `Donkey.gltf` | Quaternius, *Quaternius Ultimate Animated Animals (Donkey)*, https://quaternius.com/packs/ultimateanimatedanimals.html | CC0-1.0 (`licenses/quaternius-animated-animals.txt`) | `Idle` → idle, `Walk` → walk, `Gallop` → run, `Eating` → eat |
| wolf | `wolf_idle.usdz`, `wolf_walk.usdz`, `wolf_run.usdz`, `wolf_eat.usdz` | `Wolf.gltf` | Quaternius, *Quaternius Ultimate Animated Animals (Wolf)*, https://quaternius.com/packs/ultimateanimatedanimals.html | CC0-1.0 (`licenses/quaternius-animated-animals.txt`) | `Idle` → idle, `Walk` → walk, `Gallop` → run, `Eating` → eat |
| bear | `bear_idle.usdz`, `bear_walk.usdz`, `bear_run.usdz`, `bear_eat.usdz` | `animal-polar.glb` | Kenney, *Kenney Cube Pets 2.0 (polar bear)*, https://kenney.nl/assets/cube-pets | CC0-1.0 (`licenses/kenney-cube-pets.txt`) | `idle` → idle, `walk` → walk, `run` → run, `eat` → eat |
| penguin | `penguin_idle.usdz`, `penguin_walk.usdz`, `penguin_run.usdz`, `penguin_eat.usdz` | `animal-penguin.glb` | Kenney, *Kenney Cube Pets 2.0 (penguin)*, https://kenney.nl/assets/cube-pets | CC0-1.0 (`licenses/kenney-cube-pets.txt`) | `idle` → idle, `walk` → walk, `run` → run, `eat` → eat |
| frog | `frog_idle.usdz`, `frog_walk.usdz`, `frog_run.usdz`, `frog_eat.usdz` | `Frog.fbx` | Quaternius, *Quaternius Easy Animated Enemy Pack, Jan 2019 (Frog)*, https://quaternius.com | CC0-1.0 (`licenses/quaternius-easy-animated-enemy-pack.txt`) | `FrogArmature&#124;FrogArmature&#124;Frog_Idle` → idle, `FrogArmature&#124;FrogArmature&#124;Frog_Jump` → walk, `FrogArmature&#124;FrogArmature&#124;Frog_Jump` → run, `FrogArmature&#124;FrogArmature&#124;Frog_Attack` → eat |
| ball | `ball.usdz` | `ball-red.glb` | Kenney, *Kenney Minigolf Kit (ball-red)*, https://kenney.nl/assets/minigolf-kit | CC0-1.0 (`licenses/kenney-minigolf-kit.txt`) | static |
| beachball | `beachball.usdz` | `ball-blue.glb` | Kenney, *Kenney Minigolf Kit (ball-blue)*, https://kenney.nl/assets/minigolf-kit | CC0-1.0 (`licenses/kenney-minigolf-kit.txt`) | static |
| toycar | `toycar.usdz` | `vehicle-racer.glb` | Kenney, *Kenney Toy Car Kit (vehicle-racer)*, https://kenney.nl/assets/toy-car-kit | CC0-1.0 (`licenses/kenney-toy-car-kit.txt`) | static |
| blocks | `blocks.usdz` | `Cube_Prototype_Small.gltf` | Kay Lousberg, *KayKit Prototype Bits (Cube_Prototype_Small)*, https://kaylousberg.itch.io/prototype-bits | CC0-1.0 (`licenses/kaykit-prototype-bits.txt`) | static |
| teddy | `teddy.usdz` | `animal-panda.glb` | Kenney, *Kenney Cube Pets 2.0 (panda, static pose)*, https://kenney.nl/assets/cube-pets | CC0-1.0 (`licenses/kenney-cube-pets.txt`) | static |
| cone | `cone.usdz` | `item-cone.glb` | Kenney, *Kenney Toy Car Kit (item-cone)*, https://kenney.nl/assets/toy-car-kit | CC0-1.0 (`licenses/kenney-toy-car-kit.txt`) | static |
| crate | `crate.usdz` | `box.glb` | Kenney, *Kenney Survival Kit (box)*, https://kenney.nl/assets/survival-kit | CC0-1.0 (`licenses/kenney-survival-kit.txt`) | static |
| cardboard | `cardboard.usdz` | `cardboardBoxClosed.glb` | Kenney, *Kenney Furniture Kit (cardboardBoxClosed)*, https://kenney.nl/assets/furniture-kit | CC0-1.0 (`licenses/kenney-furniture-kit.txt`) | static |
| cup | `cup.usdz` | `cup.gltf` | Kay Lousberg, *KayKit Furniture Bits (cup)*, https://kaylousberg.itch.io/furniture-bits | CC0-1.0 (`licenses/kaykit-furniture.txt`) | static |
| mug | `mug.usdz` | `mug_A.gltf` | Kay Lousberg, *KayKit Furniture Bits (mug_A)*, https://kaylousberg.itch.io/furniture-bits | CC0-1.0 (`licenses/kaykit-furniture.txt`) | static |
| can | `can.usdz` | `soda-can.glb` | Kenney, *Kenney Food Kit (soda-can)*, https://kenney.nl/assets/food-kit | CC0-1.0 (`licenses/kenney-food-kit.txt`) | static |
| bottle | `bottle.usdz` | `soda-bottle.glb` | Kenney, *Kenney Food Kit (soda-bottle)*, https://kenney.nl/assets/food-kit | CC0-1.0 (`licenses/kenney-food-kit.txt`) | static |
| apple | `apple.usdz` | `apple.glb` | Kenney, *Kenney Food Kit (apple)*, https://kenney.nl/assets/food-kit | CC0-1.0 (`licenses/kenney-food-kit.txt`) | static |
| book | `book.usdz` | `book_single.gltf` | Kay Lousberg, *KayKit Furniture Bits (book_single)*, https://kaylousberg.itch.io/furniture-bits | CC0-1.0 (`licenses/kaykit-furniture.txt`) | static |
| pillow | `pillow.usdz` | `pillow.glb` | Kenney, *Kenney Furniture Kit (pillow)*, https://kenney.nl/assets/furniture-kit | CC0-1.0 (`licenses/kenney-furniture-kit.txt`) | static |
| lamp | `lamp.usdz` | `lampRoundTable.glb` | Kenney, *Kenney Furniture Kit (lampRoundTable)*, https://kenney.nl/assets/furniture-kit | CC0-1.0 (`licenses/kenney-furniture-kit.txt`) | static |
| plant | `plant.usdz` | `pottedPlant.glb` | Kenney, *Kenney Furniture Kit (pottedPlant)*, https://kenney.nl/assets/furniture-kit | CC0-1.0 (`licenses/kenney-furniture-kit.txt`) | static |
| chair | `chair.usdz` | `chair.glb` | Kenney, *Kenney Furniture Kit (chair)*, https://kenney.nl/assets/furniture-kit | CC0-1.0 (`licenses/kenney-furniture-kit.txt`) | static |
| stool | `stool.usdz` | `stoolBar.glb` | Kenney, *Kenney Furniture Kit (stoolBar)*, https://kenney.nl/assets/furniture-kit | CC0-1.0 (`licenses/kenney-furniture-kit.txt`) | static |

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
