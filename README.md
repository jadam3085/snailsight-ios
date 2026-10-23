# SnailSight (iOS)

Native ARKit / RealityKit LiDAR app: world-locked AR with the live scene mesh, measuring, room and object capture,
upload to a self-hosted map server, relocalization in a whole-house map, the house drawn from streamed tiles after the lock (11.0), saved places, localization status pill, mesh-only mapping, a scans viewer (mesh, Gaussian
splats via MetalSplatter, AR dollhouse) and a small physics sim (robot + animals) in AR.

It is built Mac-less on GitHub Actions and produces an **unsigned** `.ipa`; signing and installing happen elsewhere
(any re-signing tool you trust). Feature history: `docs/HISTORY.md`.

## Layout

- `project.yml` XcodeGen spec (the `.xcodeproj` is generated on CI, never committed).
- `Sources/` the app (SwiftUI shell, AR session, recorder, upload queue, scans viewer, sim, live map).
- `SnailSightCore/` Swift package with the pure logic (geometry, networking decisions, log format, sim brains, ...);
  `swift test` runs on Linux in CI.
- `Resources/` app icon, the minimal offline sim model (fox; CC BY, see `Resources/SimModels/ATTRIBUTION.md`). Every other sim model is served live by the map server (12.9).
- `upstream/apple-reconstructed-scene/` Apple's sample code, unmodified (the AR base).

## Build

`.github/workflows/build-ilidar.yml`:

- **test** (every push / PR): `swift test` for `SnailSightCore` in a `swift:6.0.3` Linux container.
- **build** (manual `workflow_dispatch`): XcodeGen + `xcodebuild archive` with signing disabled on `macos-15`, then
  zips `Payload/iLiDAR.app` into artifact `iLiDAR-ipa-arkitfork` / `iLiDAR.ipa`. Inputs: `app_version` (marketing
  prefix; the phone sees `<app_version>.<run number + 200>`).

Locally on a Mac: `brew install xcodegen && xcodegen generate && open SnailSight.xcodeproj`.

## Map server address

No server address is compiled into the source. The app reads its default servers from two Info.plist keys:

| Info.plist key | Build setting | Meaning |
|---|---|---|
| `SnailSightServerTailnet` | `SNAILSIGHT_SERVER_TAILNET` | first default, e.g. `http://100.64.0.1:8904` |
| `SnailSightServerLAN` | `SNAILSIGHT_SERVER_LAN` | fallback, e.g. `http://192.168.1.10:8904` |

Set them as `xcodebuild` build settings, or patch the keys into the unsigned IPA's `Info.plist` before you sign it.
With both empty, enter a server under **Settings → Map server → override**. The server API (`/v1`) is not part of
this repository.

## Security notes

See `SECURITY.md`.

## Licence

MIT for the SnailSight code (`LICENSE`). Third-party parts keep their own licences: `THIRD_PARTY_NOTICES.md`.
