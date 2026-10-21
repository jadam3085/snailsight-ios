// SnailSight 12.3 Map ▸ 3D (owner 2026-10-20: "a button on map mode to be able to manipulate the map in 3d to see the
// entire 3d color map and float through it", fly like the PC portal). A full-screen NON-AR RealityKit view over the
// Map's 2D plan; the AR session is paused while it is up and resumed (no reset) when it closes.
//
//  - Content: the living map's textured tiles (M2 per-tile USDZ, the structure or raw variant per Layers ▸ Raw scan) for
//    the WHOLE site: SnailSightCore.Map3DTiles covers every root and refines by screen-space error from the virtual
//    camera inside the 600 MB budget (lower when the OS is short of memory, detail k adapts to the frame rate); far
//    tiles are evicted first. Blobs come from the AR streamer's disk cache (Caches/tiles, by hash) and tiles the AR view
//    already holds are CLONED (shared mesh + textures, no second copy). Overlays: the live coloured mesh (Mesh (live)),
//    sim bodies (+ the selected one's route), cameras with frustums, estimated / surveyed trees, the estimated terrain.
//  - Controls: Orbit (drag = rotate, two fingers = pan, pinch = zoom) by default; Fly = the Scans Fly controller
//    (ViewerCamera + DroneDriver + JoystickPad / HoldButton) driven by SnailSightCore.Map3DFly: left stick moves in the
//    camera frame, drag anywhere else looks, ▲▼ climb, Walk / Run / Drone speed (walk + run follow the floor at eye
//    height), optional gyro look. Level slicer B / 1 / 2 / Yd (storeys above the slice hidden), Reset view, tap a body =
//    select it (the same command ring), tap the ground with a selection = send it there. The ground clamp always holds.
// Logs: map3d_open, map3d_fly, map3d_fps (every 10 s: fps, footprint_mb, tiles), map3d_tileset, map3d_select,
// map3d_tile_error, map3d_close.
import SwiftUI
import RealityKit
import Combine
import CoreMotion
import CryptoKit
import SnailSightCore

// MARK: frames

private func yUp(_ m: [Double]) -> SIMD3<Float> {
    SIMD3(Float(m[0]), Float(m.count > 2 ? m[2] : 0), Float(-m[1]))
}

private func mapOf(_ p: SIMD3<Float>) -> [Double] { [Double(p.x), Double(-p.z), Double(p.y)] }

private func vec(_ p: SIMD3<Float>) -> Map3DVec { Map3DVec(Double(p.x), Double(p.y), Double(p.z)) }

private func fv(_ v: Map3DVec) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }

/// Holder turning map-frame (z up) children into the viewer frame (y up): −90° about X.
private func mapFrameHolder(_ name: String) -> Entity {
    let e = Entity()
    e.name = name
    e.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
    return e
}

// MARK: - model

@MainActor
final class Map3DModel: ObservableObject {
    let model: AppModel
    let data: MapPlanData
    let camera = ViewerCamera()
    let drone: DroneDriver
    let world = Entity()
    let tiles: Map3DTileLoader
    let overlays: Map3DOverlays
    weak var arView: ARView?

    @Published var fly = false { didSet { if fly != oldValue { flyChanged() } } }
    @Published var speed: Map3DSpeed = .drone {
        didSet {
            params.speed = speed
            if speed != oldValue { speedChanged() }
        }
    }
    @Published var gyro = false { didSet { if gyro != oldValue { gyroChanged() } } }
    @Published var sliceID: String?
    @Published private(set) var statusText = ""
    @Published var hint: String?

    private(set) var params = Map3DFlyParams(speed: .drone)
    private var fps = Map3DFps(window: 1)
    private var lastFps: Double?
    private var minFps = Double.infinity
    private var maxMB = 0.0
    private var k = Map3DTiles.REFINE_K
    private var lowMemUntil: TimeInterval = 0
    private var lastTileTick: TimeInterval = 0
    private var lastOverlayTick: TimeInterval = 0
    private var lastFpsLog: TimeInterval = 0
    private var lastAdapt: TimeInterval = 0
    private var openedAt = Date()
    private var framed = false
    private var started = false
    private var subs: [Cancellable] = []
    private var bag: Set<AnyCancellable> = []
    private var hintTask: Task<Void, Never>?
    private let motion = CMMotionManager()
    private var gyroPrev: (yaw: Double, pitch: Double)?
    private var gyroYaw = 0.0

    init(model: AppModel, data: MapPlanData) {
        self.model = model
        self.data = data
        drone = DroneDriver(camera: camera)
        tiles = Map3DTileLoader(model: model)
        overlays = Map3DOverlays(model: model, data: data)
        world.name = "map3d.world"
        world.addChild(tiles.node)
        world.addChild(overlays.root)
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    var slice: PlanLevel? { data.levels.first { $0.id == sliceID } }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        openedAt = Date()
        data.refresh(level: nil)                                    // yard: estimated trees, DEM, terrain
        if sliceID == nil { sliceID = data.levels.first { $0.level == nil }?.id }
        drone.stepper = { [weak self] s, input, dt in self?.flyStep(s, input, dt) ?? s }
        camera.walkCollider = { [weak self] _, b in self?.clampEye(b) ?? b }
        camera.onTap = { [weak self] p, size in self?.tap(p, size) }
        camera.onDoubleTap = { [weak self] p, size in self?.doubleTap(p, size) }
        tiles.onTileset = { [weak self] in self?.frameSite(force: false) }
        frameSite(force: false)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in self?.memoryWarning() }.store(in: &bag)
        var ev = MemoryProbe.fields()
        ev["tiles_rev"] = .int(model.mapFollower.tiles?.rev ?? -1)
        ev["variant"] = .string(model.mapFollower.tiles?.variant(raw: model.rawScan) ?? "")
        ev["shared_ar_tiles"] = .int(model.controller.mapLayer.tiles.drawnCount)
        ev["levels"] = .int(data.levels.count)
        model.log.event("map3d_open", ev)
    }

    func stop() {
        guard started else { return }
        started = false
        drone.stop()
        drone.stepper = nil
        motion.stopDeviceMotionUpdates()
        for s in subs { s.cancel() }
        subs.removeAll()
        bag.removeAll()
        var ev = MemoryProbe.fields()
        ev["s"] = .double((Date().timeIntervalSince(openedAt) * 10).rounded() / 10)
        ev["max_mb"] = .double(maxMB.rounded())
        ev["min_fps"] = .double(minFps.isFinite ? (minFps * 10).rounded() / 10 : -1)
        ev["fly"] = .bool(fly)
        ev["fetched"] = .int(tiles.fetchedCount)
        ev["shared"] = .int(tiles.sharedCount)
        ev["dl_mb"] = .double((Double(tiles.dlBytes) / 1_048_576 * 10).rounded() / 10)
        model.log.event("map3d_close", ev)
        tiles.clear()
        overlays.clear()
    }

    /// The scene view is up: per-frame updates.
    func attach(_ v: ARView) {
        arView = v
        subs.append(v.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            MainActor.assumeIsolated { self?.frame(dt: e.deltaTime) }
        })
    }

    // MARK: per frame

    private func frame(dt: Double) {
        let t = now
        if let f = fps.frame(t: t) {
            lastFps = f
            if t - openedAt.timeIntervalSince1970 > 3 { minFps = min(minFps, f) }
        }
        if gyro, fly { applyGyro() }
        if !fly { clampOrbit() }
        if t - lastOverlayTick >= 1.0 / 15 {
            lastOverlayTick = t
            overlays.tickBodies(cutZ: cutZ)
        }
        if t - lastTileTick >= TileSelect.stepS {
            lastTileTick = t
            tick(t)
        }
    }

    private var cutZ: Double? { Map3DSlice.cutZ(levels: data.levels, slice: slice) }

    private var budget: Int {
        let b = Map3DQuality.budget(availableMB: MemoryProbe.availableMB())
        return now < lowMemUntil ? b / 2 : b
    }

    private func tick(_ t: TimeInterval) {
        if sliceID == nil, let y = data.levels.first(where: { $0.level == nil }) { sliceID = y.id }
        let cam = mapOf(camera.eye)
        if let f = lastFps, t - lastAdapt >= 2 {
            lastAdapt = t
            k = Map3DQuality.adjust(k: k, fps: f)
        }
        tiles.tick(cam: cam, maxLevel: Map3DSlice.maxLevel(slice), budget: budget, k: k)
        overlays.tick(cutZ: cutZ, eye: cam)
        let mb = MemoryProbe.footprintMB() ?? 0
        maxMB = max(maxMB, mb)
        statusText = [tiles.statusText, String(format: "%.0f MB", mb), lastFps.map { String(format: "%.0f fps", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        if t - lastFpsLog >= 10 {
            lastFpsLog = t
            var ev = MemoryProbe.fields()
            ev["fps"] = .double(((lastFps ?? 0) * 10).rounded() / 10)
            ev["drawn"] = .int(tiles.drawnCount)
            ev["loaded"] = .int(tiles.loadedCount)
            ev["wanted"] = .int(tiles.wantedCount)
            ev["inflight"] = .int(tiles.inFlightCount)
            ev["mem_mb"] = .double((tiles.memMB * 10).rounded() / 10)
            ev["budget_mb"] = .int(budget >> 20)
            ev["k"] = .double((k * 100).rounded() / 100)
            ev["fly"] = .bool(fly)
            ev["speed"] = .string(speed.rawValue)
            ev["slice"] = .string(slice?.label ?? "all")
            ev["live_tiles"] = .int(overlays.liveCount)
            ev["bodies"] = .int(overlays.bodyCount)
            model.log.event("map3d_fps", ev)
        }
    }

    // MARK: view

    /// Frame the whole site (tileset bounds, else the scene's plan bounds) from a three-quarter view.
    func frameSite(force: Bool) {
        guard force || !framed else { return }
        var lo: SIMD3<Float>?, hi: SIMD3<Float>?
        if let b = tiles.siteBounds {
            lo = SIMD3(Float(b[0]), Float(b[2]), Float(-b[4])); hi = SIMD3(Float(b[3]), Float(b[5]), Float(-b[1]))
        } else if let b = data.sceneBounds {
            let zs = data.floorplans.values.compactMap(\.floorZ)
            lo = SIMD3(Float(b[0]), Float(zs.min() ?? 0), Float(-b[3]))
            hi = SIMD3(Float(b[2]), Float((zs.max() ?? 0) + 3), Float(-b[1]))
        }
        guard let l = lo, let h = hi else { return }
        framed = tiles.siteBounds != nil
        if fly { fly = false }
        camera.mode = .orbit
        camera.frame(min: l, max: h)
    }

    func resetView() {
        model.log.event("map3d_reset", ["fly": .bool(fly)])
        fly = false
        frameSite(force: true)
    }

    func flash(_ t: String) {
        hint = t
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.hint = nil }
        }
    }

    private func memoryWarning() {
        lowMemUntil = now + 30
        k = max(0.6, k * 0.7)
        model.log.event("map3d_mem_warning", MemoryProbe.fields())
    }

    // MARK: fly

    private func flyChanged() {
        if fly {
            let o = camera.orbit
            var eye = o.eye
            eye = clampEye(eye)
            camera.walk = WalkCamera(eye: eye, yaw: o.yaw, pitch: Float(Map3DFly.clampPitch(Double(-o.pitch), params: params)))
            camera.mode = .walk
            drone.start()
        } else {
            drone.stop()
            let w = camera.walk
            let d: Float = 6
            camera.orbit.target = w.eye + w.forward * d
            camera.orbit.yaw = w.yaw
            camera.orbit.pitch = min(OrbitCamera.maxPitch, max(OrbitCamera.minPitch, -w.pitch))
            camera.orbit.distance = d
            camera.mode = .orbit
            if gyro { gyro = false }
        }
        logFly()
    }

    private func speedChanged() {
        if fly, speed.followsGround {                               // settle onto the floor at eye height
            let w = camera.walk
            if let g = groundY(x: Double(w.eye.x), z: Double(w.eye.z), eyeY: Double(w.eye.y)) {
                var to = w
                to.eye.y = Float(g + params.eyeHeight)
                drone.fly(to: to)
            }
        }
        logFly()
    }

    private func gyroChanged() {
        gyroPrev = nil
        if gyro {
            guard motion.isDeviceMotionAvailable else { gyro = false; flash("No motion sensors on this device"); return }
            motion.deviceMotionUpdateInterval = 1.0 / 60
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        } else {
            motion.stopDeviceMotionUpdates()
        }
        logFly()
    }

    private func logFly() {
        model.log.event("map3d_fly", ["on": .bool(fly), "speed": .string(speed.rawValue), "gyro": .bool(gyro),
                                      "slice": .string(slice?.label ?? "all")])
    }

    func climb(_ down: Bool, _ dir: Float) {
        if down, speed.followsGround { speed = .drone }              // ▲▼ always do something: take off
        drone.input.climb = down ? dir : 0
    }

    /// Gyro look: turn about the vertical with the phone (rotation rate about gravity), tilt from the gravity vector.
    private func applyGyro() {
        guard let m = motion.deviceMotion else { return }
        let g = m.gravity, r = m.rotationRate
        let gl = max(1e-6, (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
        let dt = 1.0 / max(lastFps ?? 60, 10)
        gyroYaw += -(r.x * g.x + r.y * g.y + r.z * g.z) / gl * dt    // about "up" (= −gravity), left positive
        let pitch = asin(max(-1, min(1, g.z / gl)))
        let cur = (yaw: gyroYaw, pitch: pitch)
        defer { gyroPrev = cur }
        guard let prev = gyroPrev else { return }
        let d = Map3DFly.gyroDelta(from: prev, to: cur)
        var w = camera.walk
        w.yaw += Float(d.0)
        w.pitch = Float(Map3DFly.clampPitch(Double(w.pitch) + d.1, params: params))
        camera.walk = w
        camera.changed()
    }

    /// DroneDriver's frame step: Map3DFly (camera-frame stick velocity, look clamp, ground clamp).
    private func flyStep(_ s: DroneState, _ input: DroneInput, _ dt: Float) -> DroneState {
        let eyeY = Double(s.camera.eye.y)
        let st = Map3DFlyState(eye: vec(s.camera.eye), yaw: Double(s.camera.yaw), pitch: Double(s.camera.pitch),
                               velocity: vec(s.velocity))
        let out = Map3DFly.step(st, stick: (Double(input.move.x), Double(input.move.y)),
                                look: (Double(input.look.x), Double(input.look.y)), climb: Double(input.climb),
                                dt: Double(dt), params: params) { [weak self] x, z in self?.groundY(x: x, z: z, eyeY: eyeY) }
        return DroneState(camera: WalkCamera(eye: fv(out.eye), yaw: Float(out.yaw), pitch: Float(out.pitch)),
                          velocity: fv(out.velocity))
    }

    /// Floor height (viewer y) under viewer (x, z) for an eye at `eyeY`.
    func groundY(x: Double, z: Double, eyeY: Double) -> Double? {
        let floors = data.floorplans.values.compactMap { f in f.floorZ.map { Map3DFloor(z: $0, bounds: f.bounds) } }
        return Map3DGround.height(x: x, y: -z, eyeZ: eyeY, floors: floors, dem: data.groundZ(x: x, y: -z))
    }

    /// The ground clamp for gesture moves (pinch / two fingers) in Fly.
    func clampEye(_ p: SIMD3<Float>) -> SIMD3<Float> {
        var q = p
        let y = Map3DFly.groundClamp(Double(p.y), ground: groundY(x: Double(p.x), z: Double(p.z), eyeY: Double(p.y)),
                                     dt: 0, params: params)
        q.y = Float(y)
        return q
    }

    /// Orbit keeps the eye above the ground.
    private func clampOrbit() {
        let o = camera.orbit
        let e = o.eye
        guard let g = groundY(x: Double(e.x), z: Double(e.z), eyeY: Double(e.y)),
              let mp = Map3DFly.orbitMinPitch(targetY: Double(o.target.y), distance: Double(o.distance), groundY: g),
              Double(o.pitch) < mp else { return }
        camera.orbit.pitch = min(OrbitCamera.maxPitch, Float(mp))
        camera.changed()
    }

    // MARK: taps

    private func tap(_ p: CGPoint, _ size: CGSize) {
        let r = camera.ray(p, size)
        if let hit = overlays.pick(origin: r.origin, dir: r.dir) {
            switch hit {
            case .server(let id, let title):
                model.serverSim.select(id: id)
                model.log.event("map3d_select", ["id": .string(id), "server": .bool(true)])
                flash(title)
            case .local(let id):
                model.controller.sim.select(id: id)
                model.log.event("map3d_select", ["id": .int(id), "server": .bool(false)])
            case .camera(let title, let sub):
                flash("\(title) · \(sub)")
            }
            return
        }
        guard let g = groundHit(origin: r.origin, dir: r.dir) else { return }
        let m = mapOf(g)
        let ui = model.serverSim.ui
        if ui.active, ui.selection != nil {
            model.serverSim.goTo(mapPoint: m)
            model.log.event("map3d_goto", ["goal": .doubles(m.map { ($0 * 100).rounded() / 100 })])
        } else if !ui.active, model.controller.sim.ui.selection != nil {
            guard let w = model.controller.mapLayer.toWorld(map: m) else {
                flash("The house map has not placed you yet: the local sim needs that to go by the map")
                return
            }
            model.controller.sim.goTo(world: w)
        } else {
            flash("Tap a body to select it, then tap where it should go")
        }
    }

    private func doubleTap(_ p: CGPoint, _ size: CGSize) {
        guard !fly, let g = groundHit(origin: camera.ray(p, size).origin, dir: camera.ray(p, size).dir) else { return }
        camera.orbit.target = g
        camera.orbit.distance = min(camera.orbit.distance, 25)
        camera.changed()
    }

    /// Where a view ray meets the ground (the slice's floor indoors, else the floor / DEM under the hit, two passes).
    private func groundHit(origin o: SIMD3<Float>, dir d: SIMD3<Float>) -> SIMD3<Float>? {
        guard d.y < -1e-3 else { return nil }
        var y = Float(slice?.floorZ ?? groundY(x: Double(o.x), z: Double(o.z), eyeY: Double(o.y)) ?? 0)
        var p = o
        for _ in 0..<2 {
            let t = (y - o.y) / d.y
            guard t > 0, t < 2000 else { return nil }
            p = o + d * t
            if slice?.floorZ != nil { break }
            guard let g = groundY(x: Double(p.x), z: Double(p.z), eyeY: Double(p.y) + 1.6) else { break }
            y = Float(g)
        }
        return p
    }

    /// The command ring's projection: map point → view point (nil behind the camera).
    func project(map m: [Double]) -> CGPoint? {
        guard let v = arView else { return nil }
        let w = yUp(m)
        guard simd_dot(w - camera.eye, camera.forward) > 0.1 else { return nil }
        return v.project(w)
    }
}

// MARK: - tiles

@MainActor
final class Map3DTileLoader {
    private unowned let model: AppModel
    /// Tiles hang directly under it: their usdz are already in the viewer frame (Y up = map z).
    let node = Entity()
    var onTileset: (() -> Void)?

    private var roots: [TileNode] = []
    private var parents: [String: String] = [:]
    private var hashes: [String: String] = [:]
    private var variant: String?
    private var rev: Int?
    private var path: String?
    private var fetchingTileset = false
    private var retryAt: TimeInterval = 0
    private(set) var siteBounds: [Double]?

    private var entities: [String: Entity] = [:]
    private var loadedHash: [String: String] = [:]
    private var loadedMem: [String: Int] = [:]
    private var inFlight: [String: String] = [:]
    private var failedUntil: [String: TimeInterval] = [:]
    private var want: [String: TileSelect.Want] = [:]
    private var drawn = Set<String>()
    private var cam: [Double] = [0, 0, 0]
    private var firstDrawnLogged = false

    private(set) var fetchedCount = 0
    private(set) var sharedCount = 0
    private(set) var cachedCount = 0
    private(set) var dlBytes = 0
    private(set) var evictions = 0

    static let maxConcurrent = 4

    init(model: AppModel) {
        self.model = model
        node.name = "map3d.tiles"
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }
    private var streamer: TileStreamer { model.controller.mapLayer.tiles }

    var drawnCount: Int { drawn.count }
    var loadedCount: Int { entities.count }
    var wantedCount: Int { want.count }
    var inFlightCount: Int { inFlight.count }
    var memMB: Double { Double(loadedMem.values.reduce(0, +)) / 1_048_576 }

    var statusText: String? {
        if roots.isEmpty { return fetchingTileset ? "loading the map tiles…" : (model.mapFollower.tiles == nil ? "no tiles on the map server yet" : nil) }
        let pending = want.keys.filter { loadedHash[$0] != hashes[$0] || entities[$0] == nil }.count
        return pending > 0 ? "tiles \(drawn.count) · loading \(pending)" : "tiles \(drawn.count)"
    }

    func tick(cam c: [Double], maxLevel: Int?, budget: Int, k: Double) {
        cam = c
        ensureTileset()
        guard !roots.isEmpty else { return }
        want = Map3DTiles.select(roots, cam: c, budget: budget, k: k, maxLevel: maxLevel)
        let current = Set(entities.keys.filter { loadedHash[$0] == hashes[$0] })
        var d = TileSelect.drawn(want: want, loaded: current, parents: parents, prevDrawn: drawn)
        // a tile whose content changed keeps its old entity on screen until the new one is loaded
        for k in entities.keys where want[k] != nil && !current.contains(k) { d.insert(k) }
        var loaded: [String: (mem: Int, distance: Double)] = [:]
        for (key, m) in loadedMem {
            let dist = want[key]?.distance ?? nodeDistance(key)
            loaded[key] = (m, dist)
        }
        for key in Map3DTiles.evict(loaded: loaded, want: want, drawn: d, budget: budget) {
            release(key)
            d.remove(key)
        }
        for (key, e) in entities {
            let on = d.contains(key)
            if e.isEnabled != on { e.isEnabled = on }
        }
        drawn = d
        if !firstDrawnLogged, !d.isEmpty {
            firstDrawnLogged = true
            model.log.event("map3d_first_tiles", ["drawn": .int(d.count), "shared": .int(sharedCount)])
        }
        schedule()
    }

    private var nodeIndex: [String: TileNode] = [:]

    private func nodeDistance(_ key: String) -> Double {
        nodeIndex[key].map { Map3DTiles.distance(cam, $0) } ?? 1e9
    }

    // MARK: tileset

    private func ensureTileset() {
        guard let tb = model.mapFollower.tiles, let v = tb.variant(raw: model.rawScan), let p = tb.tilesetPath(v) else { return }
        if v == variant && tb.rev == rev { return }
        guard !fetchingTileset, now >= retryAt, let link = model.link else { return }
        fetchingTileset = true
        let t0 = CACurrentMediaTime()
        Task { [weak self] in
            var data: Data?
            var status = 0
            var err: String?
            do {
                let (d, s) = try await link.request("GET", p, timeout: 30)
                status = s
                if s == 200 { data = d } else { err = "HTTP \(s)" }
            } catch { err = error.localizedDescription }
            let dataF = data
            let parsed: [TileNode]? = await Task.detached(priority: .userInitiated) { () -> [TileNode]? in
                guard let d = dataF else { return nil }
                return try? TileSet.parse(d)
            }.value
            let statusF = status, errF = err, ms = (CACurrentMediaTime() - t0) * 1000
            await MainActor.run {
                guard let self else { return }
                self.fetchingTileset = false
                guard let r = parsed, !r.isEmpty else {
                    self.retryAt = self.now + 15
                    self.model.log.event("map3d_tile_error", ["what": .string("tileset"), "status": .int(statusF),
                                                              "error": .string(errF ?? "parse failed")])
                    return
                }
                self.dlBytes += dataF?.count ?? 0
                self.install(r, variant: v, rev: tb.rev, path: p, ms: ms)
            }
        }
    }

    private func install(_ r: [TileNode], variant v: String, rev rv: Int, path p: String, ms: Double) {
        if v != variant { clear() }
        roots = r
        parents = TileSelect.ancestorsMap(r)
        let all = TileSet.flatten(r)
        nodeIndex = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        hashes = Dictionary(all.compactMap { n in n.hash.map { (n.key, $0) } }, uniquingKeysWith: { a, _ in a })
        variant = v
        rev = rv
        path = p
        failedUntil.removeAll()
        let first = siteBounds == nil
        siteBounds = Map3DTiles.bounds(r)
        model.log.event("map3d_tileset", ["variant": .string(v), "rev": .int(rv), "tiles": .int(hashes.count),
                                          "roots": .int(r.count), "ms": .int(Int(ms)),
                                          "mem_total_mb": .int(all.reduce(0) { $0 + $1.mem } >> 20)])
        if first { onTileset?() }
    }

    func clear() {
        for k in Array(entities.keys) { release(k) }
        inFlight.removeAll()
        drawn.removeAll()
    }

    // MARK: loading

    private func schedule() {
        guard inFlight.count < Self.maxConcurrent, let base = path else { return }
        let current = Set(entities.keys.filter { loadedHash[$0] == hashes[$0] })
        let t = now
        for w in Map3DTiles.fetchOrder(want, loaded: current) {
            if inFlight.count >= Self.maxConcurrent { break }
            let k = w.node.key
            guard inFlight[k] == nil, (failedUntil[k] ?? 0) <= t, let hash = w.node.hash, let uri = w.node.uri else { continue }
            start(w.node, key: k, hash: hash, path: TileURL.resolve(uri, against: base))
        }
    }

    private func start(_ n: TileNode, key: String, hash: String, path: String) {
        inFlight[key] = hash
        if let c = streamer.sharedContent(key: key, hash: hash) {    // the AR view holds it: share the resources
            sharedCount += 1
            attach(c.clone(recursive: true), node: n, key: key, hash: hash)
            return
        }
        if let f = streamer.blobFile(hash) {
            cachedCount += 1
            load(f, node: n, key: key, hash: hash)
            return
        }
        guard let link = model.link else { inFlight[key] = nil; return }
        Task { @MainActor [weak self] in
            var got: Data?
            var err: String?
            do {
                let (d, s) = try await link.request("GET", path, timeout: 60)
                if s != 200 { err = "HTTP \(s)" }
                else if TileStreamer.sha256(d) != hash { err = "hash mismatch (\(d.count) bytes)" }
                else { got = d }
            } catch { err = error.localizedDescription }
            guard let self else { return }
            guard let d = got, let f = self.streamer.storeBlob(hash, data: d) else {
                self.failed(key, hash: hash, what: "fetch", err: err ?? "cache write failed")
                return
            }
            self.fetchedCount += 1
            self.dlBytes += d.count
            self.load(f, node: n, key: key, hash: hash)
        }
    }

    private func load(_ file: URL, node n: TileNode, key: String, hash: String) {
        guard want[key] != nil, hashes[key] == hash else {          // flew on meanwhile: stays on disk only
            if inFlight[key] == hash { inFlight[key] = nil }
            return
        }
        Task { @MainActor [weak self] in
            do {
                let e = try await Entity(contentsOf: file)
                ScanModelLoader.makeUnlit(e)                        // the texture IS the photographed light
                self?.attach(e, node: n, key: key, hash: hash)
            } catch {
                self?.failed(key, hash: hash, what: "load", err: error.localizedDescription)
            }
        }
    }

    private func failed(_ key: String, hash: String, what: String, err: String) {
        if inFlight[key] == hash { inFlight[key] = nil }
        failedUntil[key] = now + 15
        model.log.event("map3d_tile_error", ["what": .string(what), "key": .string(key), "error": .string(err)])
    }

    private func attach(_ e: Entity, node n: TileNode, key: String, hash: String) {
        guard inFlight[key] == hash else { return }
        inFlight[key] = nil
        guard want[key] != nil, hashes[key] == hash else { return }
        if entities[key] != nil { release(key) }
        let holder = Entity()
        holder.name = "map3d.tile.\(key)"
        holder.addChild(e)
        holder.isEnabled = false
        node.addChild(holder)
        entities[key] = holder
        loadedHash[key] = hash
        loadedMem[key] = n.mem
    }

    private func release(_ key: String) {
        guard let e = entities.removeValue(forKey: key) else { return }
        e.removeFromParent()
        loadedHash[key] = nil
        loadedMem[key] = nil
        drawn.remove(key)
        evictions += 1
    }
}

// MARK: - overlays

@MainActor
final class Map3DOverlays {
    enum Pick { case server(String, String), local(Int), camera(String, String) }

    private unowned let model: AppModel
    private let data: MapPlanData
    let root = Entity()
    private let live = mapFrameHolder("map3d.live")
    private let terrain = mapFrameHolder("map3d.terrain")
    private let doorNode = mapFrameHolder("map3d.doors")
    private var doorRev = -1
    private let cameraNode = Entity()
    private let treeNode = Entity()
    private let bodyNode = Entity()
    private let routeNode = Entity()

    private var liveRev = -1
    private var liveSources: [(clone: Entity, minZ: Float)] = []
    private var bodies: [String: ModelEntity] = [:]
    private var bodyPos: [String: (p: SIMD3<Float>, pick: Pick)] = [:]
    private var camerasKey = ""
    private var cameraPos: [(p: SIMD3<Float>, z: Double, entity: Entity, title: String, sub: String)] = []
    private var treesKey = ""
    private var terrainKey = ""
    private var terrainBuilding = false
    private var routeKey = ""
    private var lastLiveClone: TimeInterval = 0

    private lazy var sphere = MeshResource.generateSphere(radius: 1)
    private lazy var cylinder = MeshResource.generateCylinder(height: 1, radius: 1)

    init(model: AppModel, data: MapPlanData) {
        self.model = model
        self.data = data
        root.name = "map3d.overlays"
        for n in [live, terrain, doorNode, cameraNode, treeNode, bodyNode, routeNode] { root.addChild(n) }
        let sun = DirectionalLight()
        sun.light.intensity = 2500
        sun.look(at: .zero, from: SIMD3(20, 40, 15), relativeTo: nil)
        root.addChild(sun)
    }

    var liveCount: Int { liveSources.count }
    var bodyCount: Int { bodies.count }

    func clear() {
        for n in [live, terrain, doorNode, cameraNode, treeNode, bodyNode, routeNode] { n.children.removeAll() }
        doorRev = -1
        liveSources = []
        bodies = [:]
        bodyPos = [:]
        cameraPos = []
        liveRev = -1
        camerasKey = ""; treesKey = ""; terrainKey = ""; routeKey = ""
    }

    private static func unlit(_ c: UIColor, opacity: Float = 1) -> UnlitMaterial {
        var m = UnlitMaterial(color: c)
        if opacity < 1 { m.blending = .transparent(opacity: .init(scale: opacity)) }
        return m
    }

    // MARK: slow layers (every 0.5 s)

    func tick(cutZ: Double?, eye: [Double]) {
        // live coloured mesh: clones of the AR live tiles (shared resources), refreshed when the store changes
        live.isEnabled = model.meshLive
        let t = Date().timeIntervalSince1970
        if model.meshLive, model.meshStore.rev != liveRev, t - lastLiveClone >= 2 {   // ≤ every 2 s while mapping
            lastLiveClone = t
            liveRev = model.meshStore.rev
            live.children.removeAll()
            liveSources = []
            let src = model.controller.mapLayer.liveNode
            for c in src.children {
                let b = c.visualBounds(relativeTo: src)
                let cl = c.clone(recursive: true)
                cl.isEnabled = true
                live.addChild(cl)
                liveSources.append((cl, b.isEmpty ? 0 : b.min.z))
            }
        }
        for s in liveSources {
            let on = cutZ.map { Double(s.minZ) < $0 } ?? true
            if s.clone.isEnabled != on { s.clone.isEnabled = on }
        }
        doorNode.isEnabled = model.drawDoors
        if model.drawDoors {
            model.doorStore.ensure()
            if model.doorStore.rev != doorRev {
                doorRev = model.doorStore.rev
                doorNode.children.removeAll()
                for d in model.doorStore.leaves { doorNode.addChild(DoorMeshes.leaf(d)) }
            }
        }
        cameraNode.isEnabled = model.showCameras
        rebuildCameras()
        for c in cameraPos {
            let on = cutZ.map { c.z < $0 } ?? true
            if c.entity.isEnabled != on { c.entity.isEnabled = on }
        }
        rebuildTrees(eye: eye)
        rebuildTerrain()
        routeNode.isEnabled = model.showPaths
        rebuildRoute()
    }

    private func rebuildCameras() {
        let cams = data.cameras
        let key = cams.map { "\($0.id):\($0.pose.x):\($0.pose.y):\($0.pose.yaw ?? 0)" }.joined(separator: "|")
        guard key != camerasKey else { return }
        camerasKey = key
        cameraNode.children.removeAll()
        cameraPos = []
        let body = Self.unlit(UIColor(white: 0.85, alpha: 1))
        let edge = Self.unlit(UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1), opacity: 0.8)
        for c in cams {
            let holder = Entity()
            let p = [c.pose.x, c.pose.y, c.pose.z]
            let box = ModelEntity(mesh: .generateBox(size: SIMD3(0.22, 0.14, 0.14), cornerRadius: 0.02), materials: [body])
            box.position = yUp(p)
            holder.addChild(box)
            if c.kind == "camera", let yaw = c.pose.yaw {
                let r = c.record
                let pts = Map3DShapes.frustum(camera: p, yaw: yaw, pitchDeg: r?.pitch ?? -20, hfovDeg: r?.hfov ?? 90,
                                              vfovDeg: r?.vfov ?? 60, far: min(r?.far ?? 8, 12)).map(yUp)
                for (a, b) in Map3DShapes.frustumEdges { holder.addChild(Self.segment(pts[a], pts[b], 0.025, edge)) }
            }
            cameraNode.addChild(holder)
            cameraPos.append((yUp(p), c.pose.z, holder, c.title, c.subtitle))
        }
    }

    private func rebuildTrees(eye: [Double]) {
        guard let e = data.estimated else { return }
        let key = "\(e.trees.count):\(e.correctedCount)"
        guard key != treesKey else { return }
        treesKey = key
        treeNode.children.removeAll()
        let solid = SimpleMaterial(color: UIColor(red: 0.2, green: 0.42, blue: 0.18, alpha: 1), roughness: 1, isMetallic: false)
        let ghost = SimpleMaterial(color: UIColor(red: 0.66, green: 0.82, blue: 0.56, alpha: 0.35), roughness: 1, isMetallic: false)
        let corrected = SimpleMaterial(color: UIColor(red: 0.85, green: 0.8, blue: 0.2, alpha: 1), roughness: 1, isMetallic: false)
        let trunk = SimpleMaterial(color: UIColor(red: 0.36, green: 0.26, blue: 0.18, alpha: 1), roughness: 1, isMetallic: false)
        // nearest 600 to the site centre (the estimate can hold thousands of lidar trees)
        let c = data.sceneBounds.map { [($0[0] + $0[2]) / 2, ($0[1] + $0[3]) / 2] } ?? [eye[0], eye[1]]
        let trees = e.trees.filter { $0.look != .hidden }
            .sorted { hypot($0.x - c[0], $0.y - c[1]) < hypot($1.x - c[0], $1.y - c[1]) }.prefix(600)
        for t in trees {
            let z = t.z ?? data.groundZ(x: t.x, y: t.y) ?? 0
            let h = Float(max(2, t.heightM ?? 8)), cr = Float(max(0.8, t.crownR ?? 2))
            let base = yUp([t.x, t.y, z])
            let tr = ModelEntity(mesh: cylinder, materials: [trunk])
            tr.scale = SIMD3(0.18, h * 0.55, 0.18)
            tr.position = base + SIMD3(0, h * 0.275, 0)
            let crown = ModelEntity(mesh: sphere, materials: [t.look == .ghost ? ghost : t.look == .corrected ? corrected : solid])
            crown.scale = SIMD3(cr, min(cr, h * 0.45), cr)
            crown.position = base + SIMD3(0, h - min(cr, h * 0.45), 0)
            treeNode.addChild(tr)
            treeNode.addChild(crown)
        }
    }

    private func rebuildTerrain() {
        guard let d = data.dem, !terrainBuilding else { return }
        let key = "\(d.origin):\(d.w)x\(d.h):\(d.res)"
        guard key != terrainKey else { return }
        terrainKey = key
        terrainBuilding = true
        Task.detached(priority: .utility) { [weak self] in
            let step = Map3DShapes.terrainStep(w: d.w, h: d.h)
            let m = Map3DShapes.terrain(origin: d.origin, res: d.res, w: d.w, h: d.h, ground: d.ground, step: step)
            await self?.showTerrain(m)
        }
    }

    private func showTerrain(_ m: (positions: [Float], indices: [UInt32])) {
        terrainBuilding = false
        terrain.children.removeAll()
        guard !m.indices.isEmpty else { return }
        var pos = [SIMD3<Float>]()
        pos.reserveCapacity(m.positions.count / 3)
        var i = 0
        while i + 2 < m.positions.count { pos.append(SIMD3(m.positions[i], m.positions[i + 1], m.positions[i + 2] - 0.3)); i += 3 }
        var nrm = [SIMD3<Float>](repeating: .zero, count: pos.count)
        var t = 0
        while t + 2 < m.indices.count {
            let a = Int(m.indices[t]), b = Int(m.indices[t + 1]), c = Int(m.indices[t + 2])
            let n = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
            nrm[a] += n; nrm[b] += n; nrm[c] += n
            t += 3
        }
        var desc = MeshDescriptor(name: "map3d.terrain")
        desc.positions = MeshBuffers.Positions(pos)
        desc.normals = MeshBuffers.Normals(nrm.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 0, 1) })
        desc.primitives = .triangles(m.indices)
        guard let res = try? MeshResource.generate(from: [desc]) else { return }
        let mat = SimpleMaterial(color: UIColor(red: 0.42, green: 0.5, blue: 0.36, alpha: 0.85), roughness: 1, isMetallic: false)
        terrain.addChild(ModelEntity(mesh: res, materials: [mat]))
        model.log.event("map3d_terrain", ["triangles": .int(m.indices.count / 3)])
    }

    private func rebuildRoute() {
        let sim = model.serverSim
        let route = sim.selectedRoute ?? []
        let key = route.map { $0.prefix(3).map { String(format: "%.1f", $0) }.joined(separator: ",") }.joined(separator: ";")
        guard key != routeKey else { return }
        routeKey = key
        routeNode.children.removeAll()
        guard route.count >= 2 else { return }
        let mat = Self.unlit(.cyan, opacity: 0.85)
        let pts = route.filter { $0.count >= 3 }.map { yUp($0) + SIMD3(0, 0.08, 0) }
        for i in 0..<(pts.count - 1) { routeNode.addChild(Self.segment(pts[i], pts[i + 1], 0.05, mat)) }
    }

    // MARK: bodies (15 Hz)

    func tickBodies(cutZ: Double?) {
        var seen = Set<String>()
        var pos: [String: (p: SIMD3<Float>, pick: Pick)] = [:]
        for b in model.serverSim.bodyInfos() {
            if let c = cutZ, b.pose[2] >= c { continue }
            let key = "s:" + b.id
            seen.insert(key)
            let col: UIColor = b.drone ? .systemTeal : (b.rover || b.role == .robot) ? .systemBlue : b.role == .object ? .brown : .orange
            let p = yUp(b.pose) + SIMD3(0, 0.25, 0)
            place(key, at: p, colour: b.selected ? .cyan : col, radius: b.selected ? 0.34 : 0.25)
            pos[key] = (p, .server(b.id, b.title))
        }
        let layer = model.controller.mapLayer
        for b in model.controller.sim.bodyInfos() {
            guard let m = layer.toMap(world: b.world) else { continue }
            if let c = cutZ, m[2] >= c { continue }
            let key = "l:\(b.id)"
            seen.insert(key)
            let p = yUp(m)
            place(key, at: p, colour: b.selected ? .cyan : (b.role == .robot ? .systemBlue : .orange), radius: b.selected ? 0.3 : 0.2)
            pos[key] = (p, .local(b.id))
        }
        for (k, e) in bodies where !seen.contains(k) {
            e.removeFromParent()
            bodies[k] = nil
        }
        bodyPos = pos
    }

    private func place(_ key: String, at p: SIMD3<Float>, colour: UIColor, radius: Float) {
        let e: ModelEntity
        if let x = bodies[key] { e = x } else {
            e = ModelEntity(mesh: sphere, materials: [Self.unlit(colour)])
            bodyNode.addChild(e)
            bodies[key] = e
        }
        e.position = p
        if e.scale.x != radius {
            e.scale = SIMD3(repeating: radius)
            e.model?.materials = [Self.unlit(colour)]
        }
    }

    /// The body / camera nearest to a view ray (within a radius that grows with the distance).
    func pick(origin o: SIMD3<Float>, dir d: SIMD3<Float>) -> Pick? {
        var best: (Float, Pick)?
        func consider(_ p: SIMD3<Float>, _ pk: Pick, base: Float) {
            let t = simd_dot(p - o, d)
            guard t > 0 else { return }
            let miss = simd_length(p - (o + d * t))
            guard miss < max(base, t * 0.035) else { return }
            if best == nil || t < best!.0 { best = (t, pk) }
        }
        for (_, b) in bodyPos { consider(b.p, b.pick, base: 0.5) }
        if model.showCameras {
            for c in cameraPos where c.entity.isEnabled { consider(c.p, .camera(c.title, c.sub), base: 0.35) }
        }
        return best?.1
    }

    static func segment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float, _ m: RealityKit.Material) -> ModelEntity {
        let d = simd_distance(a, b)
        let e = ModelEntity(mesh: .generateBox(size: SIMD3(t, t, max(d, 0.001))), materials: [m])
        e.position = (a + b) / 2
        if d > 1e-4 { e.look(at: b, from: e.position, relativeTo: nil) }
        return e
    }
}

// MARK: - scene view

struct Map3DSceneView: UIViewRepresentable {
    let vm: Map3DModel

    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        v.environment.background = .color(UIColor(red: 0.07, green: 0.09, blue: 0.11, alpha: 1))
        v.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableHDR, .disableGroundingShadows,
                           .disableAREnvironmentLighting]
        let anchor = AnchorEntity(world: matrix_identity_float4x4)
        anchor.addChild(vm.world)
        let cam = PerspectiveCamera()
        cam.camera.fieldOfViewInDegrees = vm.camera.fovy * 180 / .pi
        cam.camera.near = 0.05
        cam.camera.far = 2000
        anchor.addChild(cam)
        v.scene.addAnchor(anchor)
        context.coordinator.cam = cam
        context.coordinator.update()
        context.coordinator.listener = vm.camera.listen { [weak coord = context.coordinator] in coord?.update() }
        vm.camera.attach(to: v)
        vm.attach(v)
        return v
    }

    func updateUIView(_ v: ARView, context: Context) {}

    static func dismantleUIView(_ v: ARView, coordinator: Coordinator) {
        if let id = coordinator.listener { coordinator.camera.unlisten(id) }
        v.scene.anchors.removeAll()
    }

    func makeCoordinator() -> Coordinator { Coordinator(camera: vm.camera) }

    final class Coordinator {
        let camera: ViewerCamera
        var cam: PerspectiveCamera?
        var listener: UUID?
        init(camera: ViewerCamera) { self.camera = camera }
        func update() { cam?.look(at: camera.target, from: camera.eye, relativeTo: nil) }
    }
}

// MARK: - the screen

struct Map3DView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var data: MapPlanData
    @StateObject private var vm: Map3DModel

    init(model: AppModel, data: MapPlanData) {
        self.data = data
        _vm = StateObject(wrappedValue: Map3DModel(model: model, data: data))
    }

    var body: some View {
        ZStack {
            Map3DSceneView(vm: vm).ignoresSafeArea()
            CommandRingOverlay(server: model.serverSim.ui, local: model.controller.sim.ui,
                               projector: { [vm] m in vm.project(map: m) })
            VStack(spacing: 8) {
                topBar
                if let h = vm.hint {
                    Text(h).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                if vm.fly { flyControls } else { orbitHint }
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { model.showMap3D = false } label: {
                Image(systemName: "map").font(.headline).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Back to the 2D map")
            VStack(alignment: .leading, spacing: 0) {
                Text("3D map").font(.headline).foregroundStyle(.white)
                Text(vm.statusText).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(data.levels) { l in
                    Button { vm.sliceID = l.id } label: {
                        Text(l.level == nil ? "Yd" : l.label).font(.subheadline.weight(.semibold)).frame(width: 38, height: 40)
                            .foregroundStyle(vm.sliceID == l.id ? Color.black : Color.white)
                            .background(vm.sliceID == l.id ? Color.cyan : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l.level == nil ? "Everything (yard and every storey)" : "Up to \(l.title)")
                    .accessibilityAddTraits(vm.sliceID == l.id ? .isSelected : [])
                }
            }
            .padding(2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var orbitHint: some View {
        Text("Drag to turn · two fingers to pan · pinch to zoom · tap a body to select it")
            .font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
    }

    private var flyControls: some View {
        HStack(alignment: .bottom) {
            JoystickPad(title: "move", onChange: { vm.drone.input.move = $0 }, radius: 56)
            Spacer()
            VStack(spacing: 10) {
                HoldButton(systemImage: "arrow.up") { vm.climb($0, 1) }
                    .accessibilityLabel("Up")
                HoldButton(systemImage: "arrow.down") { vm.climb($0, -1) }
                    .accessibilityLabel("Down")
            }
        }
        .padding(.bottom, 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            tool(vm.fly ? "Fly" : "Orbit", vm.fly ? "airplane" : "rotate.3d", on: vm.fly) { vm.fly.toggle() }
                .accessibilityHint(vm.fly ? "Switch to orbit" : "Switch to fly: left stick moves, drag to look")
            if vm.fly {
                tool(vm.speed.title, vm.speed.icon, on: false) { vm.speed = vm.speed.next }
                    .accessibilityLabel("Speed \(vm.speed.title)")
                tool("Gyro", "gyroscope", on: vm.gyro) { vm.gyro.toggle() }
            }
            tool("Mesh", "cube.transparent", on: model.meshLive) { model.meshLive.toggle() }
            tool("Cams", "video", on: model.showCameras) { model.showCameras.toggle() }
            tool("Doors", "door.left.hand.open", on: model.arDoors) { model.arDoors.toggle() }
            tool("Reset", "arrow.counterclockwise", on: false) { vm.resetView() }
        }
    }

    private func tool(_ title: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(on ? Color.black : Color.white)
            .background(on ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
    }
}
