# Third-party notices

The MIT licence in `LICENSE` covers the SnailSight code written for this project. These parts keep their own licences:

| Component | Where | Licence |
|---|---|---|
| Apple sample code "Visualizing and Interacting with a Reconstructed Scene" | `upstream/apple-reconstructed-scene/` (unmodified), `Sources/AppleSampleDerived.swift` (derived) | MIT-style Apple sample licence, © 2026 Apple Inc. Full text: `LICENSE-Apple-sample.txt` (also `upstream/apple-reconstructed-scene/LICENSE.txt`) |
| MetalSplatter 1.0.1 (scier/MetalSplatter) | Swift package dependency, fetched at build time (not vendored) | MIT |
| Sim models: Quaternius, Kenney, KayKit (Kay Lousberg) packs | `Resources/SimModels/*.usdz`, `Resources/SimThumbs/` | CC0-1.0 (texts in `Resources/SimModels/licenses/`) |
| Khronos glTF Sample Assets "Fox" | `Resources/SimModels/fox_*.usdz` | Model CC0-1.0 (PixelMannen); rigging and animation **CC BY 4.0** (tomkranis); glTF conversion CC BY 4.0 (AsoboStudio, scurest). Text: `Resources/SimModels/licenses/khronos-gltf-sample-fox.txt` |

Attribution (CC BY 4.0): "Fox" rigging and animation by tomkranis (https://sketchfab.com/tomkranis), licensed under
CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Low-poly fox model by PixelMannen (CC0). glTF conversion by
AsoboStudio and scurest. Changes: re-oriented, scaled and converted to USDZ.

Per-model sources, pinned commits and clip mappings: `Resources/SimModels/ATTRIBUTION.md`.
