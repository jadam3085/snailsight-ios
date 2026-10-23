// SnailSight 12.7 drive mode FPV / Chase: a non-AR RealityKit view of the 3D world from the driven body's turret camera
// (FPV) or behind it (Chase), following the robot pose + turret yaw / pitch EVERY frame.
// - World = the 12.3 Map 3D pieces: Map3DTileLoader (the living map's textured tiles, whole-site SSE LOD centred on the
//   driven body's camera, the same 600 MB budget, halved / thirded when the OS is short, detail k adapted to ~30 fps,
//   blobs from the AR streamer's cache / clones of the tiles the AR view holds) + Map3DOverlays (live coloured mesh,
//   doors, cameras, trees, DEM terrain, the selected route).
// - Bodies: the AR layer's OWN sim node (ServerSimClient) is borrowed into this scene under a map-frame holder, so the
//   viewer draws the very same models, clips and turret heads at the same interpolated poses (RemoteTrack +
//   TurretTrack on the shared server clock) — no second copy; it goes back to the AR map frame on close. In FPV the
//   driven body itself is hidden (the camera sits in its head).
// - The camera pose = SnailSightCore TurretCamera.pose (exactly sim/vehicle.py turret_camera), converted map → viewer
//   with MapViewerFrame ((x, z, −y)); Chase = TurretCamera.chase.
// - AR is paused while this is up (one renderer at a time, as Map 3D; AppModel.beginDriveViewer): a LIVE PiP of the AR
//   camera is therefore impossible — the overlay shows the AR view's LAST frame (snapshot taken just before the pause).
// - While AR is paused nothing else ticks the shared sim, so this view's frame loop calls ServerSimClient.frame()
//   (drive / turret sends at 10 Hz, body animation) and tick() at 2 Hz (socket + authority).
// Logs: fpv_open, fpv_fps (every 10 s: fps, footprint, tiles, budget, k), fpv_close.
import SwiftUI
import RealityKit
import Combine
import SnailSightCore

@MainActor
final class DriveViewerModel: ObservableObject {
    let model: AppModel
    let data: MapPlanData
    let world = Entity()
    let tiles: Map3DTileLoader
    let overlays: Map3DOverlays
    private let bodiesHolder = Entity()
    private weak var simParent: Entity?
    let camera = PerspectiveCamera()
    private var subs: [Cancellable] = []
    private var bag: Set<AnyCancellable> = []
    private var started = false
    private var fps = Map3DFps(window: 1)
    private var lastFps: Double?
    private var minFps = Double.infinity
    private var maxMB = 0.0
    private var k = Map3DTiles.REFINE_K
    private var lowMemUntil: TimeInterval = 0
    private var lastTile: TimeInterval = 0
    private var lastOverlay: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var lastLog: TimeInterval = 0
    private var lastAdapt: TimeInterval = 0
    private var openedAt = Date().timeIntervalSince1970
    private var frames = 0

    init(model: AppModel, data: MapPlanData) {
        self.model = model
        self.data = data
        tiles = Map3DTileLoader(model: model)
        overlays = Map3DOverlays(model: model, data: data)
        world.name = "fpv.world"
        bodiesHolder.name = "fpv.bodies"
        bodiesHolder.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))   // map z-up → viewer y-up
        world.addChild(tiles.node)
        world.addChild(overlays.root)
        world.addChild(bodiesHolder)
        camera.camera.fieldOfViewInDegrees = 70
        camera.camera.near = 0.03
        camera.camera.far = 1500
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    func start() {
        guard !started else { return }
        started = true
        openedAt = now
        data.refresh(level: nil)
        let sn = model.serverSim.simNode                      // borrow the AR bodies (same models, same poses)
        simParent = sn.parent
        sn.removeFromParent()
        bodiesHolder.addChild(sn)
        sn.isEnabled = true
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in self?.memoryWarning() }.store(in: &bag)
        var ev = MemoryProbe.fields()
        ev["view"] = .string(model.drive.view.rawValue)
        ev["id"] = .string(model.drive.bodyID ?? "")
        ev["tiles_rev"] = .int(model.mapFollower.tiles?.rev ?? -1)
        ev["shared_ar_tiles"] = .int(model.controller.mapLayer.tiles.drawnCount)
        model.log.event("fpv_open", ev)
    }

    func stop() {
        guard started else { return }
        started = false
        for s in subs { s.cancel() }
        subs.removeAll()
        bag.removeAll()
        let sn = model.serverSim.simNode
        sn.removeFromParent()
        simParent?.addChild(sn)                               // back into the AR map frame
        var ev = MemoryProbe.fields()
        ev["s"] = .double(((now - openedAt) * 10).rounded() / 10)
        ev["max_mb"] = .double(maxMB.rounded())
        ev["min_fps"] = .double(minFps.isFinite ? (minFps * 10).rounded() / 10 : -1)
        ev["frames"] = .int(frames)
        ev["fetched"] = .int(tiles.fetchedCount)
        ev["shared"] = .int(tiles.sharedCount)
        model.log.event("fpv_close", ev)
        tiles.clear()
        overlays.clear()
    }

    func attach(_ v: ARView) {
        subs.append(v.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            MainActor.assumeIsolated { self?.frame(dt: e.deltaTime) }
        })
    }

    private var budget: Int {
        let b = Map3DQuality.budget(availableMB: MemoryProbe.availableMB())
        return now < lowMemUntil ? b / 2 : b
    }

    private func memoryWarning() {
        lowMemUntil = now + 30
        k = max(0.6, k * 0.7)
        model.log.event("fpv_mem_warning", MemoryProbe.fields())
    }

    /// Every rendered frame: the shared sim (sends + bodies), then the camera from the SAME interpolated pose.
    private func frame(dt: Double) {
        let t = now
        frames += 1
        if let f = fps.frame(t: t) {
            lastFps = f
            if t - openedAt > 3 { minFps = min(minFps, f) }
        }
        model.serverSim.frame()
        if t - lastTick >= 0.5 { lastTick = t; model.serverSim.tick() }
        guard let id = model.drive.bodyID, let d = model.serverSim.driven(id), let cam = model.drive.fpvCamera(d) else { return }
        let eyeMap: [Double]
        let targetMap: [Double]
        if model.drive.view == .chase {
            let c = TurretCamera.chase(cam, scale: d.scale)
            eyeMap = c.eye; targetMap = c.target
        } else {
            eyeMap = cam.position; targetMap = TurretCamera.aimPoint(cam, distance: 1)
        }
        let e = MapViewerFrame.toViewer(eyeMap), g = MapViewerFrame.toViewer(targetMap)
        camera.look(at: SIMD3<Float>(Float(g[0]), Float(g[1]), Float(g[2])), from: SIMD3<Float>(Float(e[0]), Float(e[1]), Float(e[2])),
                    upVector: SIMD3<Float>(0, 1, 0), relativeTo: nil)
        if let f = lastFps, t - lastAdapt >= 2 { lastAdapt = t; k = Map3DQuality.adjust(k: k, fps: f) }
        if t - lastTile >= TileSelect.stepS {
            lastTile = t
            tiles.tick(cam: eyeMap, maxLevel: nil, budget: budget, k: k)
        }
        if t - lastOverlay >= 0.5 {
            lastOverlay = t
            overlays.tick(cutZ: nil, eye: eyeMap)
            let mb = MemoryProbe.footprintMB() ?? 0
            maxMB = max(maxMB, mb)
            model.drive.ui.fpvStatus = [tiles.statusText, String(format: "%.0f MB", mb),
                                        lastFps.map { String(format: "%.0f fps", $0) }].compactMap { $0 }.joined(separator: " · ")
        }
        if t - lastLog >= 10 {
            lastLog = t
            var ev = MemoryProbe.fields()
            ev["fps"] = .double(((lastFps ?? 0) * 10).rounded() / 10)
            ev["view"] = .string(model.drive.view.rawValue)
            ev["drawn"] = .int(tiles.drawnCount)
            ev["loaded"] = .int(tiles.loadedCount)
            ev["mem_mb"] = .double((tiles.memMB * 10).rounded() / 10)
            ev["budget_mb"] = .int(budget >> 20)
            ev["k"] = .double((k * 100).rounded() / 100)
            ev["live_tiles"] = .int(overlays.liveCount)
            model.log.event("fpv_fps", ev)
        }
    }
}

struct DriveViewerScene: UIViewRepresentable {
    let vm: DriveViewerModel

    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        v.environment.background = .color(UIColor(red: 0.42, green: 0.55, blue: 0.68, alpha: 1))   // daylight sky
        v.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableHDR, .disableGroundingShadows,
                           .disableAREnvironmentLighting]
        let anchor = AnchorEntity(world: matrix_identity_float4x4)
        anchor.addChild(vm.world)
        anchor.addChild(vm.camera)
        v.scene.addAnchor(anchor)
        vm.attach(v)
        return v
    }

    func updateUIView(_ v: ARView, context: Context) {}

    static func dismantleUIView(_ v: ARView, coordinator: ()) {
        v.scene.anchors.removeAll()
    }
}

/// The full-screen FPV / Chase view (under DriveModeView's controls).
struct DriveViewerView: View {
    @StateObject private var vm: DriveViewerModel
    @ObservedObject var ui: DriveUI

    init(model: AppModel, data: MapPlanData, ui: DriveUI) {
        _vm = StateObject(wrappedValue: DriveViewerModel(model: model, data: data))
        self.ui = ui
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            DriveViewerScene(vm: vm).ignoresSafeArea()
            Text(ui.fpvStatus).font(.system(size: 9, weight: .semibold).monospaced()).foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 2).allowsHitTesting(false)
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}
