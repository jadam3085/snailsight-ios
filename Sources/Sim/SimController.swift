import ARKit
import Combine
import RealityKit
import UIKit
import SnailSightCore

/// RealityKit physics queries against the LiDAR scene mesh (needs scene-understanding `.collision`). Answers the pure
/// logic's "is this step free" for animals and the floor / support probes for everyone. Never invents a floor: no
/// mesh under a point = not free. Sim objects are in their own collision group and never answer these queries.
final class SceneQuery: SimWorld {
    private let scene: RealityKit.Scene
    /// Floor height (ARKit y) of the agent currently being stepped, and its body ray heights above that floor.
    var refFloorY: Float = 0
    var bodyHeights: [Float] = [0.12, 0.4]
    var maxStep: Float = 0.12
    var maxDrop: Float = 0.15
    /// 9.9: a fleeing animal may hop down a table / shelf edge up to `hopDown` (ElevatedNav); calm ones never walk off.
    var mayHop = false
    var hopDown: Float = 0
    /// Rays cast since the last stats line (thermal evidence).
    var rays = 0

    init(scene: RealityKit.Scene) { self.scene = scene }

    /// Floor under a ground point, searched from 0.35 m above `nearY` down to `below` (0.45 m) below it.
    func floor(at g: V2, nearY: Float, below: Float = 0.45) -> Float? {
        rays += 1
        let o = SimFrame.world(g, y: nearY + 0.35)
        return scene.raycast(origin: o, direction: SIMD3(0, -1, 0), length: 0.35 + below, query: .nearest,
                             mask: .sceneUnderstanding, relativeTo: nil).first?.position.y
    }

    /// First surface straight down from `top` (up to `length`).
    func surfaceBelow(_ g: V2, top: Float, length: Float = 5) -> Float? {
        rays += 1
        return scene.raycast(origin: SimFrame.world(g, y: top), direction: SIMD3(0, -1, 0), length: length,
                             query: .nearest, mask: .sceneUnderstanding, relativeTo: nil).first?.position.y
    }

    /// Support probe fan for a body (9.4): centre + four inset corners of its footprint, each the first surface going
    /// down from `top` (up to 5 m). Feeds SupportPhysics.supportHeight.
    func supportHits(center: V2, yaw: Double, halfL: Double, halfW: Double, top: Float) -> [Double?] {
        let f = SimMath.unit(yaw), l = SimMath.unit(yaw + .pi / 2)
        var pts = [center]
        for (a, b) in [(1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0)] {
            pts.append(center + f * (a * halfL * 0.6) + l * (b * halfW * 0.6))
        }
        return pts.map { g in surfaceBelow(g, top: top).map { Double($0) } }
    }

    func isFree(from a: V2, to b: V2, radius: Double) -> Bool {
        let d = b - a
        let len = SimMath.length(d)
        guard len > 1e-6 else { return true }
        let u = d / len
        let dir = SIMD3<Float>(Float(u.x), 0, Float(-u.y))
        let side = V2(-u.y, u.x) * radius                       // body edges, so thin legs are not missed
        for (i, h) in bodyHeights.enumerated() {
            let starts = i == 0 ? [a] : [a, a + side, a - side]
            for s in starts {
                rays += 1
                let o = SimFrame.world(s, y: refFloorY + h)
                if !scene.raycast(origin: o, direction: dir, length: Float(len + radius), query: .any,
                                  mask: .sceneUnderstanding, relativeTo: nil).isEmpty { return false }
            }
        }
        let deep = mayHop ? max(0.45, hopDown + 0.1) : 0.45
        let f = floor(at: b, nearY: refFloorY, below: deep)
        let e = ElevatedNav.classify(currentFloor: Double(refFloorY), newFloor: f.map { Double($0) },
                                     maxStep: Double(maxStep), maxDrop: Double(maxDrop), hopDown: Double(hopDown),
                                     mayHop: mayHop)
        return ElevatedNav.passable(e)
    }
}

/// What the selection bar shows for the selected body.
struct SimSelection: Equatable {
    var id: Int
    var kind: SimKind
    var title: String
    var detail: String
    var symbol: String
    var scale: Double
    var scaleIsOverride: Bool
}

/// SwiftUI state of the sim selection bar (kept out of AppModel; the bar observes it directly).
final class SimUI: ObservableObject {
    @Published var selection: SimSelection?
    @Published var pending: SimCommand?
    @Published var prompt: String?
    @Published var patrolPoints = 0
    @Published var scaleRef = false
    @Published var objectCount = 0
}

/// The spawn catalog bundled with the app (Resources/SimModels/catalog.json), or the three 9.7 animals.
enum SimCatalogStore {
    static let shared: SimCatalog = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let c = try? SimCatalog.decode(data), !c.items.isEmpty
        else { return .builtIn }
        return c
    }()
}

/// S1 local sim (plan §7 S): RobosnailBob driven by the joystick with real limits, colliding with the real house via
/// RealityKit convex casts against the scene mesh; catalog animals running the snailCOP-derived behaviours.
/// 9.4: real-size robot, support re-checks when the LiDAR mesh changes, tap-to-select with commands, A* on the scene
/// mesh, a 1 m scale reference. 9.8: Sim scale (global + per body), the catalog (17 animals, 18 objects), objects as
/// rigid bodies on the scene mesh (pushed by the robot / animals, poked, grabbed and thrown, sleeping at rest), a heat
/// budget instead of freezing at SERIOUS, and lazy model loading that shows a model the moment it arrives.
/// Everything lives in the ARKit world frame of this session.
final class SimController: NSObject, UIGestureRecognizerDelegate {
    private unowned let model: AppModel
    private let arView: ARView
    private let root = AnchorEntity(world: matrix_identity_float4x4)
    private let query: SceneQuery
    let catalog = SimCatalogStore.shared
    let library = SimModelLibrary()                     // 10.5: shared with the server sim's drawing (ServerSimClient)
    private var updateSub: Cancellable?
    private var uiSubs: [AnyCancellable] = []
    private(set) var robot: SimRobot?
    private var animals: [SimAnimal] = []
    private var objects: [SimObject] = []
    private var accRobot = 0.0, accAnimals = 0.0, accSleep = 0.0
    private var nextID = 1
    private let shaper = StickShaper()
    private var stick = V2.zero
    private(set) var enabled = false
    private var pausedForRecording = false
    private var lastBlockLog: TimeInterval = 0
    private var lastStats: TimeInterval = 0
    private var lastRescue: TimeInterval = 0
    private var stats = (blocks: 0, cliffs: 0, noFloor: 0, spooks: 0, falls: 0, overlaps: 0, plans: 0, pushes: 0,
                         throws: 0, pokes: 0, rescues: 0, hits: 0, knocks: 0, kicks: 0, recovers: 0)
    private var tickMs = (sum: 0.0, max: 0.0, n: 0)
    private var lastNote: String?
    private var lastPublish: TimeInterval = 0
    private var modelErrorsShown = 0

    // 9.4 support physics (robot, animals, placed cubes; objects are RealityKit rigid bodies)
    private enum BodyRef: Hashable { case robot, animal(Int), cube(UUID) }
    private let meshSource = SimMeshSource()
    private var meshQueue = MeshChangeQueue(interval: 0.25, settleDelay: 0.2)
    private var awake = Set<BodyRef>()
    private var cubeSupport: [UUID: SupportState] = [:]
    /// Cubes seen RESTING on the mesh at least once. Only those may fall: a cube placed on a surface the LiDAR mesh has
    /// not caught yet (a thin shelf, glass) must not drop through it to the floor below.
    private var cubeConfirmed = Set<UUID>()
    private var lastSweep: TimeInterval = 0
    private var sweepCursor = 0
    /// Placed 10 cm cubes (SceneRenderer): (anchor id, the holder that carries cube + cross + label).
    var cubeSource: (() -> [(UUID, Entity)])?

    // selection + commands
    let ui = SimUI()
    static let robotID = 0
    private let highlight = SimHighlight()
    private let scaleRef = SimScaleRef()
    private var scaleRefStatic: (V2, Double, Float)?
    private var markers: [Entity] = []
    private var patrolPts: [V2] = []
    private var lastSelectionText: TimeInterval = 0
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private var dragging: (id: Int, start: Double, tracker: ThrowTracker)?
    private var grab: (id: Int, planeY: Float, tracker: ThrowTracker)?
    // 9.9 surfaces + physical animals
    private var floorEstimate = FloorEstimate()
    private var collisionSub: Cancellable?
    private var lastPairHit: [String: Double] = [:]
    private var robotDragNoted = false
    /// A standable surface under a screen point: where it is and what it is (floor / table top / shelf).
    struct StandHit {
        var point: SIMD3<Float>
        var kind: SurfaceKind
    }
    /// What it takes to put deleted objects back (undo, 9.9).
    struct ObjectSnapshot {
        let key: String
        let position: SIMD3<Float>
        let orientation: simd_quatf
        let scaleOverride: Double?
    }
    /// Objects were deleted (✕, long-press, list, Clear cubes): the AR controller offers Undo for 5 s.
    var onObjectsDeleted: (([ObjectSnapshot], String) -> Void)?

    // P2a persistent places: every robot / animal has a named ARAnchor ("sim.<uid>") at its home spot, saved in the
    // place's world map; animals have a home area (room bounds) they roam or pace in. Objects are not saved.
    private struct Persist {
        var uid: String
        var anchor: ARAnchor
        var homeSource: HomeSource
        var homeTries = 0
    }
    private var persist: [Int: Persist] = [:]
    private let homeOutline = Entity()
    /// Hidden + frozen while a saved place relocalizes: nothing is drawn at a guessed position.
    var gated = false { didSet { if gated != oldValue { applyVisibility(); publish() } } }
    /// Spawn / move / delete / behaviour change → PlaceController auto-save.
    var onEntitiesChanged: (() -> Void)?
    var entityCount: Int { animals.count + (robot == nil ? 0 : 1) }

    // 9.4 robot autonomy
    private var robotPlanToken = 0
    private var robotPlanInFlight = false
    private var lastRobotPlan: TimeInterval = 0
    private var robotBlockedFor = 0.0
    private var robotReplans = 0

    static let skin = 0.01                                  // keep 1 cm off walls

    init(model: AppModel, arView: ARView) {
        self.model = model
        self.arView = arView
        query = SceneQuery(scene: arView.scene)
        super.init()
        root.name = "sim.root"
        highlight.entity.isEnabled = false
        root.addChild(highlight.entity)
        scaleRef.entity.isEnabled = false
        root.addChild(scaleRef.entity)
        homeOutline.isEnabled = false
        root.addChild(homeOutline)
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        uiSubs.append(ui.$scaleRef.dropFirst().sink { [weak self] on in self?.scaleRefChanged(on) })
        library.onLoaded = { [weak self] file, ent, ms in self?.modelLoaded(file, ent, ms) }
        library.onError = { [weak self] file, err in
            guard let self else { return }
            let kind = self.catalog.items.first { ($0.files ?? [:]).values.contains(file) }?.key ?? file
            self.model.log.event("sim_model_load", ["kind": .string(kind), "file": .string(file), "ok": .bool(false),
                                                    "err": .string(err)])
            if self.modelErrorsShown < 2 {
                self.modelErrorsShown += 1
                self.model.flash("Model \(file) could not load", seconds: 2)
            }
        }
    }

    // MARK: scale + budget

    private var globalScale: Double { SimScale.clampGlobal(model.simScale) }
    private var budget: SimBudget { model.controller.heatBudget }

    /// Settings slider moved (or restored): every body without its own override follows.
    func globalScaleChanged() {
        let s = globalScale
        if let r = robot, r.scaleOverride == nil { r.setScale(s); r.render(dt: 0); awake.insert(.robot) }
        for a in animals where a.scaleOverride == nil { a.setScale(s); a.render(); awake.insert(.animal(a.id)) }
        for o in objects where o.scaleOverride == nil { o.setScale(s); wake(o) }
        refreshSelection()
        model.log.event("sim_scale", ["global": .double(s), "robot": .bool(robot != nil), "animals": .int(animals.count),
                                      "objects": .int(objects.count)])
        publish()
    }

    /// Why the sim is not stepping (nil = running).
    private var pauseReason: String? {
        guard enabled, !pausedForRecording, !gated else { return "hidden" }
        if case .normal = model.tracking {} else { return "tracking" }
        if !budget.running { return "heat" }
        return nil
    }

    /// The scene mesh must carry collision shapes while the sim is on (raycasts / convex casts).
    var needsCollision: Bool { enabled && !pausedForRecording }
    /// …and take part in physics while there are objects to fall on it.
    /// 9.9: animals are physics bodies too (kinematic, dynamic when knocked), so the mesh takes part while any exist.
    var needsPhysics: Bool { needsCollision && (!objects.isEmpty || !animals.isEmpty) }

    private var hasBodies: Bool { robot != nil || !animals.isEmpty || !objects.isEmpty || !(cubeSource?().isEmpty ?? true) }

    // MARK: mode

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            arView.scene.addAnchor(root)
            updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
                self?.tick(min(e.deltaTime, 0.1))
            }
            arView.addGestureRecognizer(pan)
            collisionSub = arView.scene.subscribe(to: CollisionEvents.Began.self) { [weak self] e in
                self?.collided(e.entityA, e.entityB)
            }
            wakeAll()
            model.flash("Sim on: aim the + at the floor, tap Spawn · tap a body to command it", seconds: 3)
        } else {
            updateSub?.cancel()
            updateSub = nil
            collisionSub?.cancel()
            collisionSub = nil
            arView.removeGestureRecognizer(pan)
            root.removeFromParent()
            stick = .zero
            endGrab(throwIt: false)
            select(nil)
            cancelPending()
            meshSource.reset()
        }
        applyVisibility()
        model.controller.applyRenderSettings()
        model.log.event(on ? "sim_on" : "sim_off", ["robot": .bool(robot != nil), "animals": .int(animals.count),
                                                    "objects": .int(objects.count), "scale": .double(globalScale)])
    }

    /// Recording owns the thermal/memory budget (9.1.61 AdaptiveCapture): sim pauses and hides unless allowed.
    func recordingChanged(_ recording: Bool) {
        let pause = recording && !model.simAllowWhileRecording
        guard pause != pausedForRecording else { return }
        pausedForRecording = pause
        applyVisibility()
        stick = .zero
        if enabled {
            model.controller.applyRenderSettings()
            model.log.event("sim_pause", ["paused": .bool(pause), "reason": .string("recording")])
            if pause { model.flash("Sim paused while recording", seconds: 2) }
            if !pause { wakeAll() }                         // the world may have changed meanwhile
        }
        publish()
    }

    func setStick(_ v: SIMD2<Double>) { stick = v }

    private func applyVisibility() { root.isEnabled = !pausedForRecording && !gated && !remoteAuthority }

    /// 10.1 S2: the map server's shared sim is authoritative (ServerSimClient): the local bodies are hidden and frozen
    /// (tick only steps a visible root) and come back as they were when the phone falls back to the local sim.
    var remoteAuthority = false {
        didSet {
            guard remoteAuthority != oldValue else { return }
            stick = .zero
            if remoteAuthority { select(nil); cancelPending() }
            applyVisibility()
            publish()
        }
    }

    /// The local robot's floor point in ARKit world (Robot path starts there).
    var robotWorldPosition: SIMD3<Float>? { robot.map { SimFrame.world($0.position, y: $0.floorY) } }

    /// "Clear sim": everything goes, including the anchors (the next save of the place has no animals).
    func clear() {
        for p in persist.values { arView.session.remove(anchor: p.anchor) }
        removeAllBodies()
        model.log.event("sim_clear")
        onEntitiesChanged?()
        model.controller.applyRenderSettings()
    }

    /// Drop every body without touching the session (a session re-run removes the anchors itself).
    func removeAllBodies() {
        endGrab(throwIt: false)
        robot?.entity.removeFromParent()
        robot = nil
        for a in animals { a.entity.removeFromParent() }
        animals.removeAll()
        for o in objects { o.entity.removeFromParent() }
        objects.removeAll()
        ui.objectCount = 0
        persist.removeAll()
        awake.removeAll()
        stick = .zero
        select(nil)
        cancelPending()
        clearMarkers()
        publish()
    }

    private func canSpawn() -> Bool {
        guard gated else { return true }
        model.flash("Wait for LOCALIZED first (or Places ▸ Start new place)", seconds: 2.5)
        return false
    }

    // MARK: spawn

    /// 9.9 (owner: "spawn or move or toss an animal on top of things like a shelf or table"): the first LiDAR-mesh
    /// surface under a screen point, kept only when it faces up (SurfaceClass: ≤ 25° from level); else ARKit's
    /// estimated horizontal plane. nil (with `refusal`) when the mesh there is a wall / underside / slope.
    private func standHit(at pt: CGPoint) -> StandHit? {
        refusal = nil
        let camY = Double(cameraPosition.y)
        if let ray = arView.ray(through: pt),
           let h = arView.scene.raycast(origin: ray.origin, direction: ray.direction, length: 8, query: .nearest,
                                        mask: .sceneUnderstanding, relativeTo: nil).first {
            query.rays += 1
            let n = SimFrame.d3(h.normal), y = Double(h.position.y)
            guard SurfaceClass.standable(SurfaceClass.classify(normal: n, height: y, floorY: floorEstimate.y)) else {
                refusal = SurfaceClass.classify(normal: n, height: y, floorY: floorEstimate.y)
                return nil
            }
            floorEstimate.note(surfaceY: y, cameraY: camY)
            return StandHit(point: h.position, kind: SurfaceClass.classify(normal: n, height: y, floorY: floorEstimate.y))
        }
        guard let p = floorHit(at: pt) else { return nil }
        floorEstimate.note(surfaceY: Double(p.y), cameraY: camY)
        return StandHit(point: p, kind: SurfaceClass.classify(normal: SIMD3(0, 1, 0), height: Double(p.y),
                                                              floorY: floorEstimate.y))
    }
    private var refusal: SurfaceKind?

    private func standHint() -> String {
        switch refusal {
        case .wall?: return "That's a wall: aim the + at the floor, a table top or a shelf"
        case .ceiling?, .steep?: return "Not a flat surface: aim at the floor, a table top or a shelf"
        default: return "Aim the + at the floor or a table first (sweep the phone over it)"
        }
    }

    private var spawnPoint: CGPoint?                     // 10.6 Spawn mode: the tapped floor point

    private func centreStandHit() -> StandHit? {
        guard let h = standHit(at: spawnPoint ?? CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)) else {
            model.flash(standHint())
            return nil
        }
        return h
    }

    /// May RobosnailBob stand here? Floor yes; a table / shelf only if big enough for its footprint (a small NavGrid at
    /// the surface height, inflated by its radius) and light enough at this scale (RobotSurface). Async (mesh grid).
    private func robotSurface(_ h: StandHit, scale s: Double, done: @escaping (RobotSurface.Verdict) -> Void) {
        let mass = 60 * s * s * s
        let quick = RobotSurface.check(kind: h.kind, robotMassKg: mass, fits: true)
        guard h.kind == .elevated, quick == .ok else { done(quick); return }
        let prof = RobotProfile.robosnailbob.scaled(s)
        let g = SimFrame.ground(h.point)
        let half = max(0.6, prof.agentRadius + 0.4)
        let spec = GridSpec(center: g, half: half, cell: 0.04)
        let y = Double(h.point.y)
        let region = Bounds3(min: SIMD3(g.x - half, y - 1, -g.y - half), max: SIMD3(g.x + half, y + prof.height + 0.5, -g.y + half))
        let anchors = meshSource.anchors(in: arView.session, near: region)
        DispatchQueue.global(qos: .userInitiated).async {
            var b = NavGridBuilder(spec: spec, refFloor: y, maxStep: 0.03, maxDrop: 0.04, bodyHeight: prof.height)
            SimMeshSource.addTriangles(of: anchors, to: &b)
            let fits = RobotSurface.fits(b.build(inflate: prof.agentRadius), at: g)
            let v = RobotSurface.check(kind: h.kind, robotMassKg: mass, fits: fits)
            DispatchQueue.main.async { done(v) }
        }
    }

    private func logSurface(_ who: String, _ h: StandHit, verdict: String? = nil) {
        var ev: [String: LogValue] = ["who": .string(who), "kind": .string(h.kind.rawValue),
                                      "y": .double((Double(h.point.y) * 1000).rounded() / 1000)]
        if let f = floorEstimate.y { ev["above_floor_m"] = .double(((Double(h.point.y) - f) * 1000).rounded() / 1000) }
        if let v = verdict { ev["verdict"] = .string(v) }
        model.log.event("sim_surface", ev)
    }

    /// Floor point under the screen centre (scene mesh or estimated plane), or nil with a hint.
    private func centreFloorHit() -> SIMD3<Float>? {
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let p = floorHit(at: c) else {
            model.flash("Aim the + at the floor first (sweep the phone over it)")
            return nil
        }
        return p
    }

    private func floorHit(at pt: CGPoint) -> SIMD3<Float>? {
        guard let hit = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .horizontal).first else { return nil }
        let t = hit.worldTransform.columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    /// Any surface under the screen point (table tops included), for dropping objects.
    private func surfaceHit(at pt: CGPoint) -> SIMD3<Float>? {
        guard let hit = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .any).first else { return nil }
        let t = hit.worldTransform.columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    private var cameraGround: (pos: V2, heading: Double) {
        let m = arView.cameraTransform.matrix
        let fwd = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        return (SimFrame.ground(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)),
                atan2(Double(-fwd.z), Double(fwd.x)))
    }

    private var cameraPosition: SIMD3<Float> { arView.cameraTransform.translation }

    /// Spawn picker entry point; `at`: the floor point tapped in Spawn mode (else the + at the screen centre).
    func spawn(_ item: SimCatalogItem, at pt: CGPoint? = nil) {
        spawnPoint = pt
        defer { spawnPoint = nil }
        model.log.event("sim_spawn_request", ["kind": .string(item.key), "mode": .string("local")])
        if item.isAnimal { spawnAnimal(item) } else { spawnObject(item) }
        model.noteSpawned(item.key)
    }

    func spawnRobot(at pt: CGPoint? = nil) {
        spawnPoint = pt
        defer { spawnPoint = nil }
        guard enabled, canSpawn(), let h = centreStandHit() else { return }
        let override = robot?.scaleOverride
        let heading = cameraGround.heading
        robotSurface(h, scale: SimScale.effective(global: globalScale, override: override)) { [weak self] v in
            guard let self, self.enabled else { return }
            self.logSurface("robot", h, verdict: v.rawValue)
            if v != .ok {
                self.model.flash(RobotSurface.hint(v, robotMassKg: 60 * pow(SimScale.effective(global: self.globalScale,
                                                                                               override: override), 3)) ?? "",
                                 seconds: 3)
                return
            }
            self.finishSpawnRobot(at: h.point, heading: heading, override: override, surface: h.kind)
        }
    }

    private func finishSpawnRobot(at p: SIMD3<Float>, heading: Double, override: Double?, surface: SurfaceKind) {
        let g = SimFrame.ground(p)
        placeRobot(at: g, floorY: p.y, heading: heading, override: override)   // facing away from you
        setAnchor(Self.robotID, at: p)
        onEntitiesChanged?()
        let r = robot!, e = r.size
        model.log.event("sim_spawn", ["kind": .string("robosnailbob"), "pos": .doubles([g.x, g.y, Double(p.y)]),
                                      "size_m": .doubles([e.x, e.z, e.y]), "scale": .double(r.scale),
                                      "surface": .string(surface.rawValue)])
        model.flash(String(format: "RobosnailBob at %@: %.2f × %.2f m, max %.2f m/s", SimScale.label(r.scale), e.x, e.z,
                           r.drive.profile.maxSpeed), seconds: 3)
        publish()
    }

    @discardableResult
    private func placeRobot(at g: V2, floorY: Float, heading: Double, override: Double? = nil) -> SimRobot {
        robot?.entity.removeFromParent()
        let r = SimRobot(pose: DrivePose(x: g.x, y: g.y, theta: heading), floorY: floorY,
                         scale: SimScale.effective(global: globalScale, override: override))
        r.scaleOverride = override
        root.addChild(r.entity)
        robot = r
        awake.insert(.robot)
        return r
    }

    /// P2a: a new animal roams the room it is put in (bounds from the LiDAR floor, refined in the background).
    private func spawnAnimal(_ item: SimCatalogItem) {
        guard enabled, canSpawn(), let h = centreStandHit() else { return }
        let p = h.point
        logSurface(item.key, h)
        var seedGen = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000) &+ UInt64(nextID))
        let a = addAnimal(item, at: SimFrame.ground(p), floorY: p.y, heading: seedGen.uniform(-.pi, .pi), override: nil)
        setAnchor(a.id, at: p)
        a.brain.setHome(Poly.circle(center: a.brain.state.pos, radius: RoomBounds.fallbackRadius))
        a.brain.setOrder(.roam)
        computeHome(a.id)
        onEntitiesChanged?()
    }

    /// Objects drop from just above the surface under the + (a table top works), so they visibly fall and settle.
    private func spawnObject(_ item: SimCatalogItem) {
        guard enabled, canSpawn() else { return }
        guard let p = centreStandHit()?.point else { return }
        let n = max(1, item.spawnCount ?? 1)
        guard objects.count + n <= budget.maxObjects else {
            model.flash("\(objects.count) objects is the limit right now: delete some or Clear sim", seconds: 2.5)
            return
        }
        let s = globalScale
        let e = item.size * s
        var gen = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000) &+ UInt64(nextID))
        let yaw = cameraGround.heading + .pi / 2 + gen.uniform(-0.4, 0.4)
        var first: SimObject?
        for k in 0..<n {
            // a set (blocks) stacks as a little pyramid: 3 + 2 + 1
            let row = k < 3 ? 0 : k < 5 ? 1 : 2
            let col = k < 3 ? Double(k) - 1 : k < 5 ? Double(k - 3) - 0.5 : 0
            let along = SimMath.unit(yaw) * (col * e.x * 1.05)
            let g = SimFrame.ground(p) + along
            let y = p.y + Float(0.12 + Double(row) * e.y * 1.15)
            let o = addObject(item, at: SimFrame.world(g, y: y), yaw: yaw + gen.uniform(-0.1, 0.1), override: nil)
            if first == nil { first = o }
        }
        model.log.event("sim_spawn", ["kind": .string(item.key), "id": .int(first?.id ?? -1), "count": .int(n),
                                      "pos": .doubles([Double(p.x), Double(p.y), Double(p.z)]),
                                      "size_m": .doubles([e.x, e.y, e.z]), "scale": .double(s),
                                      "mass_kg": .double((first?.massKg ?? 0) * 1000 / 1000)])
        model.controller.applyRenderSettings()               // the mesh joins physics with the first object
        publish()
    }

    @discardableResult
    private func addObject(_ item: SimCatalogItem, at w: SIMD3<Float>, yaw: Double, override: Double?) -> SimObject {
        let o = SimObject(id: nextID, item: item, scale: SimScale.effective(global: globalScale, override: override),
                          spawnY: w.y)
        nextID += 1
        o.scaleOverride = override
        o.entity.position = w
        o.entity.orientation = SimFrame.yaw(yaw)
        root.addChild(o.entity)
        objects.append(o)
        ui.objectCount = objects.count
        if let f = item.file(clip: "static") ?? item.files?.values.sorted().first {
            library.request(f) { [weak o] t in o?.attach(template: t) }
        }
        return o
    }

    // MARK: P2a anchors, home areas, save / restore

    private static func translation(_ p: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(p.x, p.y, p.z, 1)
        return m
    }

    /// Ground yaw of an anchor (θ such that the anchor's +x is (cos θ, 0, −sin θ) in ARKit).
    private static func yaw(_ m: simd_float4x4) -> Double { atan2(Double(-m.columns.0.z), Double(m.columns.0.x)) }

    /// (Re)place a body's anchor at a floor point, keeping its uid.
    private func setAnchor(_ id: Int, at p: SIMD3<Float>) {
        let old = persist[id]
        if let o = old { arView.session.remove(anchor: o.anchor) }
        let uid = old?.uid ?? UUID().uuidString
        let a = ARAnchor(name: SimEntityRecord.anchorPrefix + uid, transform: Self.translation(p))
        arView.session.add(anchor: a)
        persist[id] = Persist(uid: uid, anchor: a, homeSource: old?.homeSource ?? .radius, homeTries: 0)
    }

    /// The anchor's latest transform (ARKit refines anchors as the map improves).
    private func anchorTransform(_ a: ARAnchor) -> simd_float4x4 {
        arView.session.currentFrame?.anchors.first { $0.identifier == a.identifier }?.transform ?? a.transform
    }

    /// Room bounds around an animal's anchor from the LiDAR floor (flood fill that stops at doors, RoomBounds), off the
    /// main thread. While the floor is not scanned enough it keeps the 1.5 m circle and tries again (3×, 8 s apart).
    private func computeHome(_ id: Int) {
        guard let pr = persist[id], let a0 = animal(id) else { return }
        let m = anchorTransform(pr.anchor)
        let spawn = SimFrame.ground(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
        let floorY = Double(m.columns.3.y)
        let half = RoomBounds.maxRadius + 0.5
        let spec = GridSpec(center: spawn, half: half, cell: 0.1)
        let region = Bounds3(min: SIMD3(spawn.x - half, floorY - 1, -spawn.y - half),
                             max: SIMD3(spawn.x + half, floorY + 1.6, -spawn.y + half))
        let anchors = meshSource.anchors(in: arView.session, near: region)
        let uid = pr.uid
        let s = a0.scale
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let t0 = CACurrentMediaTime()
            var b = NavGridBuilder(spec: spec, refFloor: floorY, maxStep: AnimalReach.maxStep(scale: s),
                                   maxDrop: AnimalReach.maxDrop(scale: s), bodyHeight: 1.0)
            SimMeshSource.addTriangles(of: anchors, to: &b)
            let grid = b.build(inflate: RoomBounds.doorClose, clearAround: spawn, clearRadius: 0.3)
            let (poly, src) = RoomBounds.home(grid: grid, spawn: spawn)
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                guard let self, let a = self.animal(id), var p = self.persist[id], p.uid == uid else { return }
                a.brain.setHome(poly)
                if case .pace = a.brain.order {
                    a.brain.setOrder(.pace(RoomPatrol.loop(home: poly, from: a.brain.state.pos)))
                }
                p.homeSource = src
                p.homeTries += 1
                self.persist[id] = p
                self.model.log.event("sim_home", ["id": .int(id), "kind": .string(a.species), "source": .string(src.rawValue),
                                                  "area_m2": .double((Poly.area(poly) * 10).rounded() / 10),
                                                  "vertices": .int(poly.count), "anchors": .int(anchors.count),
                                                  "ms": .double(ms.rounded()), "try": .int(p.homeTries)])
                if self.ui.selection?.id == id { self.showHome(id) }
                if src == .radius && p.homeTries < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.computeHome(id) }
                } else {
                    self.onEntitiesChanged?()
                }
            }
        }
    }

    /// Records for the place file: anchor-relative home areas, pace loops, headings and per-body scale overrides.
    func snapshot() -> [SimEntityRecord] {
        var out: [SimEntityRecord] = []
        let room = model.placeCtl.activeName
        func pose(_ p: Persist) -> (V2, Double, [Double]) {
            let m = anchorTransform(p.anchor)
            let w = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            return (SimFrame.ground(w), Self.yaw(m), [Double(w.x), Double(w.y), Double(w.z)])
        }
        if let r = robot, let p = persist[Self.robotID] {
            let (_, yaw, xyz) = pose(p)
            out.append(SimEntityRecord(id: p.uid, kind: "robot", behaviour: "manual",
                                       heading: SimMath.wrap(r.drive.pose.theta - yaw), anchor: xyz, room: room,
                                       scale: r.scaleOverride))
        }
        for a in animals {
            guard let p = persist[a.id] else { continue }
            let (g, yaw, xyz) = pose(p)
            var loop: [V2]?
            if case .pace(let l) = a.brain.order { loop = Poly.untransform(l, yaw: yaw, offset: g) }
            out.append(SimEntityRecord(
                id: p.uid, kind: a.species, behaviour: SimEntityRecord.behaviour(of: a.brain.order),
                heading: SimMath.wrap(a.brain.state.heading - yaw), anchor: xyz,
                home: a.brain.home.map { HomeArea.relative($0, source: p.homeSource, name: room, anchor: g, yaw: yaw) },
                paceLoop: loop, room: room, scale: a.scaleOverride))
        }
        return out
    }

    /// After LOCALIZED: re-spawn each saved body at its anchor (now where it was in the room) with its home area,
    /// behaviour and scale override, moving at once. Returns (restored, missing anchor or unknown kind).
    func restore(_ records: [SimEntityRecord], anchors: [ARAnchor]) -> (Int, Int) {
        removeAllBodies()
        var byName: [String: ARAnchor] = [:]
        for a in anchors { if let n = a.name { byName[n] = a } }
        var ok = 0, missing = 0
        for r in records {
            guard let an = byName[r.anchorName] else { missing += 1; continue }
            let m = an.transform
            let w = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let g = SimFrame.ground(w)
            let yaw = Self.yaw(m)
            if r.kind == "robot" {
                placeRobot(at: g, floorY: w.y, heading: r.heading + yaw, override: r.scale)
                persist[Self.robotID] = Persist(uid: r.id, anchor: an, homeSource: .radius, homeTries: 3)
                ok += 1
            } else if let item = catalog.item(r.kind), item.isAnimal {
                let a = addAnimal(item, at: g, floorY: w.y, heading: r.heading + yaw, override: r.scale)
                persist[a.id] = Persist(uid: r.id, anchor: an, homeSource: r.home?.source ?? .radius, homeTries: 3)
                if let h = r.home { a.brain.setHome(h.world(anchor: g, yaw: yaw)) }
                a.brain.setOrder(r.order(worldLoop: r.paceLoop.map { Poly.transform($0, yaw: yaw, offset: g) }))
                if r.home == nil || r.home?.source == .radius { persist[a.id]?.homeTries = 0; computeHome(a.id) }
                ok += 1
            } else {
                missing += 1
            }
        }
        wakeAll()
        publish()
        return (ok, missing)
    }

    /// Move / drag ended: the anchor (home spot) follows, and an animal gets the room it is now in.
    private func rehome(_ id: Int) {
        guard let i = info(id), id == Self.robotID || animal(id) != nil else { return }     // objects are not saved
        setAnchor(id, at: SimFrame.world(i.ground, y: i.floorY))
        if animal(id) != nil { computeHome(id) }
        onEntitiesChanged?()
    }

    /// Selected animal: its home area drawn as a thin cyan outline on the floor.
    private func showHome(_ id: Int?) {
        for c in homeOutline.children.map({ $0 }) { c.removeFromParent() }
        guard let id, let a = animal(id), let poly = a.brain.home, poly.count >= 3 else {
            homeOutline.isEnabled = false
            return
        }
        var mat = UnlitMaterial(color: UIColor(red: 0.2, green: 0.95, blue: 1.0, alpha: 1))
        mat.blending = .transparent(opacity: 0.7)
        let y = a.floorY + 0.01
        for k in 0..<poly.count {
            let p = poly[k], q = poly[(k + 1) % poly.count]
            let len = SimMath.length(q - p)
            guard len > 0.01 else { continue }
            let seg = ModelEntity(mesh: .generateBox(size: SIMD3(Float(len), 0.006, 0.02)), materials: [mat])
            seg.position = SimFrame.world((p + q) / 2, y: y)
            seg.orientation = SimFrame.yaw(SimMath.heading(q - p))
            homeOutline.addChild(seg)
        }
        if case .pace(let loop) = a.brain.order {
            for w in loop {
                let dot = ModelEntity(mesh: .generateSphere(radius: 0.025), materials: [mat])
                dot.position = SimFrame.world(w, y: y + 0.025)
                homeOutline.addChild(dot)
            }
        }
        homeOutline.isEnabled = true
    }

    @discardableResult
    private func addAnimal(_ item: SimCatalogItem, at g: V2, floorY: Float, heading: Double, override: Double?) -> SimAnimal {
        let id = nextID
        nextID += 1
        let s = SimScale.effective(global: globalScale, override: override)
        var seedGen = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000) &+ UInt64(id))
        let brain = AnimalBrain(profile: SpeciesProfile.from(item).scaled(s), pos: g, heading: heading, seed: seedGen.next())
        let a = SimAnimal(id: id, item: item, brain: brain, floorY: floorY, scale: s)
        a.scaleOverride = override
        root.addChild(a.entity)
        animals.append(a)
        for (clip, file) in item.files ?? [:] {
            library.request(file) { [weak a] t in a?.attach(clip: clip, template: t) }
        }
        a.render()
        awake.insert(.animal(id))
        if animals.count == 1 { model.controller.applyRenderSettings() }   // 9.9: the mesh joins physics
        let e = a.size
        model.log.event("sim_spawn", ["kind": .string(item.key), "id": .int(id), "pos": .doubles([g.x, g.y, Double(floorY)]),
                                      "size_m": .doubles([e.x, e.y, e.z]), "scale": .double(s)])
        publish()
        return a
    }

    // MARK: models (bundled USDZ, Resources/SimModels, loaded on demand)

    /// The owner's 2× question, answered on the phone: RealityKit's own bounds of every loaded model vs the catalog's
    /// measured size (both at 100 %). A ratio far from 1 here would be a unit / skeleton problem in the file.
    private func modelLoaded(_ file: String, _ ent: Entity, _ ms: Double) {
        let b = ent.visualBounds(relativeTo: nil)
        let owner = catalog.items.first { ($0.files ?? [:]).values.contains(file) }
        var ev: [String: LogValue] = ["file": .string(file), "ms": .double(ms.rounded()),
                                      "bounds_m": .doubles([Double(b.extents.x), Double(b.extents.y), Double(b.extents.z)]),
                                      "min_y": .double(Double(b.min.y))]
        if let o = owner {
            let s = o.size
            ev["catalog_m"] = .doubles([s.x, s.y, s.z])
            if s.y > 0 { ev["ratio_h"] = .double((Double(b.extents.y) / s.y * 100).rounded() / 100) }
        }
        ev["ok"] = .bool(true)
        ev["kind"] = .string(owner?.key ?? (file as NSString).deletingPathExtension)
        model.log.event("sim_model_load", ev)                // 10.6 (was sim_model): every load, local or server body
    }

    // MARK: mesh changes (ARSessionDelegate → here, only while the sim is on)

    func meshChanged(_ a: ARMeshAnchor) {
        guard enabled, let r = meshSource.changed(a), hasBodies else { return }
        meshQueue.mark(r, now: CACurrentMediaTime())
    }

    func meshRemoved(_ id: UUID) {
        guard enabled, let r = meshSource.removed(id), hasBodies else { return }
        meshQueue.mark(r, now: CACurrentMediaTime())
    }

    private func wakeAll() {
        if robot != nil { awake.insert(.robot) }
        for a in animals { awake.insert(.animal(a.id)) }
        for (id, _) in cubeSource?() ?? [] { awake.insert(.cube(id)) }
        for o in objects { wake(o) }
    }

    private func wake(_ o: SimObject) {
        o.restFor = 0
        guard o.asleep, !o.held else { return }
        o.asleep = false
        o.setMode(.dynamic)
    }

    // MARK: tick

    private func tick(_ dt: Double) {
        guard enabled else { return }
        let t0 = CACurrentMediaTime()
        let now = Date().timeIntervalSince1970
        if root.isEnabled {
            if pauseReason == nil { step(dt) }
            stepKnocked(dt)
            // render every frame even when not stepping: a body restored while paused (heat / tracking) must still
            // show its model (9.7.75 "only its shadow")
            robot?.render(dt: pauseReason == nil ? dt : 0)
            for a in animals { a.render() }
            updateOverlays()
        }
        let ms = (CACurrentMediaTime() - t0) * 1000
        tickMs.sum += ms; tickMs.n += 1; tickMs.max = max(tickMs.max, ms)
        if now - lastStats >= 10 { lastStats = now; logStats() }
        if now - lastPublish >= 0.25 { lastPublish = now; publish() }
    }

    private func step(_ dt: Double) {
        let b = budget
        if let r = robot {
            r.drive.setCommand(robotCommand(r))
            accRobot += dt
            let h = 1 / max(10, b.robotHz)
            var n = 0
            while accRobot >= h && n < 6 { stepRobot(r, dt: h); accRobot -= h; n += 1 }
            if n == 6 { accRobot = 0 }
        }
        accAnimals += dt
        let ha = 1 / max(5, b.animalHz)
        let regions = meshQueue.take(now: CACurrentMediaTime())
        if !regions.isEmpty { wakeObjects(over: regions) }
        var n = 0
        var pending = regions
        while accAnimals >= ha && n < 4 {
            stepAnimals(dt: ha)
            stepSupport(dt: ha, regions: pending)
            pending = []
            accAnimals -= ha
            n += 1
        }
        if n == 4 { accAnimals = 0 }                        // a long stall: drop the backlog, never fast-forward
        if !objects.isEmpty {
            resolveContacts()
            accSleep += dt
            if accSleep >= 0.1 { stepSleep(dt: accSleep); accSleep = 0 }
            let now = CACurrentMediaTime()
            if now - lastRescue >= 1 { lastRescue = now; rescueFallen() }
        }
    }

    private func stepAnimals(dt: Double) {
        let cam = cameraGround.pos
        var threats = [Threat(pos: cam, kind: .person)]
        if let r = robot { threats.append(Threat(pos: r.position, kind: .robot)) }
        let rr = robot?.drive.profile.agentRadius ?? 0
        for (i, a) in animals.enumerated() where !a.isKnocked {
            var others: [(pos: V2, radius: Double)] = []
            // 9.9: only bodies at its own level (one on the table and one under it do not block each other)
            func level(_ y: Float, _ h: Double) -> Bool { abs(Double(y - a.floorY)) < max(h, a.size.y) * 0.8 }
            if let r = robot, level(r.floorY, r.size.y) { others.append((r.position, rr)) }
            for (j, b) in animals.enumerated() where j != i && level(b.floorY, b.size.y) {
                others.append((b.brain.state.pos, b.brain.profile.radius))
            }
            // heavy objects are walked round; light ones are bumped and pushed (resolveContacts)
            let m = a.massKg
            for o in objects where o.massKg > m * SimPush.animalPushRatio {
                let pb = o.pushBody()
                others.append((pb.center, pb.radius))
            }
            let h = a.size.y
            query.refFloorY = a.floorY
            query.bodyHeights = AnimalReach.bodyHeights(height: h).map { Float($0) }
            query.maxStep = Float(AnimalReach.maxStep(scale: a.scale))
            query.maxDrop = Float(AnimalReach.maxDrop(scale: a.scale))
            query.mayHop = a.brain.isFleeing
            query.hopDown = Float(ElevatedNav.hopDown(height: h, scale: a.scale))
            let wasDash = a.brain.state.phase == .dash
            let wasOrder = a.brain.order
            a.brain.step(dt: dt, world: query, threats: threats, others: others, leader: cam)
            if !wasDash && a.brain.state.phase == .dash {
                stats.spooks += 1
                model.log.event("sim_spook", ["id": .int(a.id), "kind": .string(a.species)])
            }
            if case .goTo = wasOrder, a.brain.order == .graze {
                model.log.event("sim_arrived", ["id": .int(a.id), "kind": .string(a.species)])
                if ui.selection?.id == a.id { clearMarkers() }
            }
            if !a.support.falling {
                if let f = query.floor(at: a.brain.state.pos, nearY: a.floorY) {
                    a.floorY += (f - a.floorY) * 0.3
                    a.support.bottom = Double(a.floorY)
                } else {
                    awake.insert(.animal(a.id))       // hopped off an edge (or the mesh went): support decides / falls
                }
            }
        }
        query.mayHop = false
    }

    // MARK: 9.9 physical animals (knocks, kicks, tosses)

    /// Something hit an animal with this velocity change (world, m/s). Logged as `sim_hit`; a big enough change knocks
    /// it over (dynamic rigid body), a small one only startles it. `force` = kicks / tosses always knock.
    private func hitAnimal(_ a: SimAnimal, dv raw: SIMD3<Double>, source: HitSource, by: String, from: V2?,
                           force: Bool = false, impactSpeed: Double? = nil) {
        let now = CACurrentMediaTime()
        if !force && now - a.lastHitAt < 0.4 { return }                 // one contact, one hit
        a.lastHitAt = now
        let knocks = force || Impact.shouldKnock(raw)
        let dvl = (raw.x * raw.x + raw.y * raw.y + raw.z * raw.z).squareRoot()
        var ev: [String: LogValue] = ["id": .int(a.id), "kind": .string(a.species), "source": .string(source.rawValue),
                                      "by": .string(by), "dv": .double((dvl * 100).rounded() / 100),
                                      "impulse_ns": .double((Impact.impulse(massKg: a.massKg, dv: raw) * 1000).rounded() / 1000),
                                      "mass_kg": .double((a.massKg * 1000).rounded() / 1000), "knocked": .bool(knocks),
                                      "tumble": .bool(knocks && Impact.tumbles(raw)),
                                      "y": .double((Double(a.entity.position.y) * 100).rounded() / 100)]
        if let f = floorEstimate.y { ev["above_floor_m"] = .double(((Double(a.floorY) - f) * 100).rounded() / 100) }
        if let s = impactSpeed { ev["speed"] = .double((s * 100).rounded() / 100) }
        model.log.event("sim_hit", ev)
        stats.hits += 1
        guard knocks else {
            if let f = from, dvl > 0.05 || (impactSpeed ?? 0) > 0.8 { a.brain.startle(from: f) }
            return
        }
        if a.knock.phase != .airborne { a.support = SupportState(bottom: Double(a.floorY)) }
        let dv = Impact.withLift(raw)
        var v = SimFrame.f3(dv)
        if a.knock.phase == .airborne { v += a.physicsVelocity }
        else { let w = a.velocity; v += SIMD3(Float(w.x), 0, Float(-w.y)) }
        Knock.begin(&a.knock, source: source, y: Double(a.entity.position.y), tumble: Impact.tumbles(dv))
        a.hitFrom = from
        a.lockRotation = !a.knock.tumbled
        a.launch(velocity: v, spin: a.knock.tumbled ? SimFrame.f3(Impact.spin(dv, height: a.size.y)) : .zero)
        awake.remove(.animal(a.id))
        stats.knocks += 1
        if dragging?.id == a.id { dragging = nil }
    }

    /// Every frame: knocked animals follow their rigid body; at rest they stand back up (Knock) and their brain resumes.
    private func stepKnocked(_ dt: Double) {
        for a in animals where a.isKnocked {
            switch a.knock.phase {
            case .airborne:
                let c = a.bodyCentre
                a.brain.place(at: SimFrame.ground(c))
                if a.entity.position.y < a.lastSafeY - 2.5 { rescueAnimal(a); continue }   // through a mesh hole
                let ar = Float(max(a.size.x, a.size.z))
                for o in objects where o.asleep && simd_distance(o.center, c) < ar + Float(max(o.size.x, o.size.z)) {
                    wake(o)
                }
                let ev = Knock.step(&a.knock, dt: dt, speed: Double(simd_length(a.physicsVelocity)),
                                    spin: Double(simd_length(a.physicsSpin)))
                if case .settled(let timedOut) = ev {
                    let surf = query.surfaceBelow(SimFrame.ground(c), top: c.y + 0.1, length: 3)
                    a.startRecovery(surfaceY: surf)
                    model.log.event("sim_knock_settle", ["id": .int(a.id), "kind": .string(a.species),
                                                         "timed_out": .bool(timedOut), "found_surface": .bool(surf != nil),
                                                         "y": .double((Double(a.recoverTo.y) * 100).rounded() / 100)])
                }
            case .recovering:
                if Knock.step(&a.knock, dt: dt, speed: 0, spin: 0) == .recovered { finishRecovery(a) }
            case .none:
                break
            }
        }
    }

    private func finishRecovery(_ a: SimAnimal) {
        let startY = a.knock.startY, tumbled = a.knock.tumbled, hits = a.knock.hits, src = a.knock.source
        let homeBefore = persist[a.id].map { anchorTransform($0.anchor).columns.3 }
        a.finishRecovery()
        stats.recovers += 1
        var ev: [String: LogValue] = ["id": .int(a.id), "kind": .string(a.species), "source": .string(src.rawValue),
                                      "drop_m": .double(((startY - Double(a.floorY)) * 100).rounded() / 100),
                                      "tumbled": .bool(tumbled), "hits": .int(hits)]
        if let f = floorEstimate.y { ev["above_floor_m"] = .double(((Double(a.floorY) - f) * 100).rounded() / 100) }
        model.log.event("sim_recover", ev)
        if let f = a.hitFrom, a.brain.order != .stay { a.brain.startle(from: f) }     // then back to its order
        awake.insert(.animal(a.id))
        // knocked to another place (off the table, across the room): that is its new home spot
        if let h = homeBefore {
            let moved = SimMath.length(a.brain.state.pos - SimFrame.ground(SIMD3(h.x, h.y, h.z)))
            if moved > 0.8 || abs(h.y - a.floorY) > 0.2 { rehome(a.id) }
        }
        if ui.selection?.id == a.id { refreshSelection() }
    }

    /// Fell through a hole in the mesh: back on the first surface under where it last stood.
    private func rescueAnimal(_ a: SimAnimal) {
        let g = a.brain.state.pos
        let f = query.surfaceBelow(g, top: a.lastSafeY + 0.5, length: 3) ?? a.lastSafeY
        a.knock = KnockState()
        a.applyPhysics()
        a.entity.physicsMotion = PhysicsMotionComponent()
        a.floorY = f
        a.support = SupportState(bottom: Double(f))
        a.render()
        stats.rescues += 1
        model.log.event("sim_rescue", ["id": .int(a.id), "kind": .string(a.species), "to_y": .double(Double(f))])
    }

    /// RealityKit contact: a knocked animal flying into another animal knocks it too (chain), a sleeping object it
    /// lands on wakes up.
    private func collided(_ x: Entity, _ y: Entity) {
        func animalOf(_ e: Entity) -> SimAnimal? { animals.first { $0.entity === e } }
        for (p, q) in [(x, y), (y, x)] {
            guard let k = animalOf(p), k.knock.phase == .airborne else { continue }
            if let o = objects.first(where: { $0.entity === q }) { wake(o); continue }
            guard let b = animalOf(q), !b.isKnocked else { continue }
            let key = "\(k.id)-\(b.id)"
            let now = CACurrentMediaTime()
            if now - (lastPairHit[key] ?? 0) < 0.5 { continue }
            lastPairHit[key] = now
            var n = SimFrame.d3(b.bodyCentre - k.bodyCentre)
            let nl = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            guard nl > 1e-4 else { continue }
            n /= nl
            let v = SimFrame.d3(k.physicsVelocity)
            let closing = v.x * n.x + v.y * n.y + v.z * n.z
            guard closing > 0.3 else { continue }
            hitAnimal(b, dv: Impact.deltaV(hitterMass: k.massKg, animalMass: b.massKg, closingSpeed: closing, normal: n),
                      source: .animal, by: k.species, from: k.brain.state.pos, impactSpeed: closing)
        }
    }

    // MARK: objects (9.8)

    /// Robot and animals push the objects they touch; a thrown object bounces off them (and startles an animal).
    private func resolveContacts() {
        var agents: [(agent: PushAgent, animal: SimAnimal?)] = []
        if let r = robot {
            let p = r.drive.profile
            agents.append((agent: PushAgent(center: r.position, yaw: r.drive.pose.theta, halfLength: p.length / 2,
                                            halfWidth: p.width / 2, bottom: Double(r.floorY), height: p.height,
                                            velocity: r.velocity, massKg: 60 * pow(r.scale, 3), kinematic: true),
                           animal: nil))
        }
        for a in animals where !a.isKnocked {
            let s = a.size
            agents.append((agent: PushAgent(center: a.brain.state.pos, yaw: a.brain.state.heading, halfLength: s.x * 0.4,
                                            halfWidth: s.z * 0.5, bottom: Double(a.floorY), height: s.y,
                                            velocity: a.velocity, massKg: a.massKg, kinematic: false),
                           animal: a))
        }
        guard !agents.isEmpty else { return }
        for o in objects where !o.held {
            var ob = o.pushBody()
            for (ag, an) in agents {
                let reach = max(ag.halfLength, ag.halfWidth) + ob.radius
                guard SimMath.length(ob.center - ag.center) < reach * 1.5 else { continue }
                let agentStill = SimMath.length(ag.velocity) < 0.03
                if agentStill, SimMath.length(ob.velocity) > 0.3, let hit = SimPush.bounce(object: ob, off: ag) {
                    wake(o)
                    apply(hit, to: o)
                    stats.hits += 1
                    if let a = an, hit.impactSpeed > 0.3 {
                        // 9.9: momentum into the animal (object → animal is −normal); heavy / fast enough = knocked over
                        let n = SIMD3<Double>(-hit.normal.x, 0, hit.normal.y)
                        hitAnimal(a, dv: Impact.deltaV(hitterMass: ob.massKg, animalMass: a.massKg,
                                                       closingSpeed: hit.impactSpeed, normal: n),
                                  source: .object, by: o.item.key, from: ob.center, impactSpeed: hit.impactSpeed)
                    }
                    ob = o.pushBody()
                    continue
                }
                guard let res = SimPush.resolve(agent: ag, object: ob), !res.blocksAgent else { continue }
                if agentStill && res.impactSpeed < 0.01 && o.asleep { continue }      // resting side by side
                wake(o)
                apply(res, to: o)
                stats.pushes += 1
                ob = o.pushBody()
            }
        }
        // 9.9: an object you are holding, swung into an animal, hits it (its speed = your finger's)
        if let gr = grab, let o = object(gr.id) {
            let v = gr.tracker.velocity(at: CACurrentMediaTime())
            var ob = o.pushBody()
            ob.velocity = V2(v.x, -v.z)
            if SimMath.length(ob.velocity) > 0.4 {
                for (ag, an) in agents {
                    guard let a = an, let hit = SimPush.bounce(object: ob, off: ag) else { continue }
                    let n = SIMD3<Double>(-hit.normal.x, 0, hit.normal.y)
                    hitAnimal(a, dv: Impact.deltaV(hitterMass: max(ob.massKg, 0.5), animalMass: a.massKg,
                                                   closingSpeed: hit.impactSpeed, normal: n),
                              source: .object, by: o.item.key + " (held)", from: ob.center, impactSpeed: hit.impactSpeed)
                }
            }
        }
    }

    private func apply(_ r: PushResult, to o: SimObject) {
        if SimMath.length(r.offset) > 1e-5 {
            o.entity.position += SIMD3(Float(r.offset.x), 0, Float(-r.offset.y))
        }
        let v = o.velocity
        o.setVelocity(SIMD3(Float(r.velocity.x), v.y, Float(-r.velocity.y)))
    }

    /// Rest → sleep (static body), cap on awake bodies, moving bodies wake their sleeping neighbours, air drag on
    /// light balls (the catalog's linear_damping).
    private func stepSleep(dt: Double) {
        var acts = objects.map { BodyActivity(id: $0.id, speed: $0.asleep ? 0 : $0.speed, restFor: $0.restFor,
                                              asleep: $0.asleep, held: $0.held) }
        let slept = Set(SimSleep.update(&acts, dt: dt, policy: SleepPolicy(maxActive: budget.maxActiveObjects)))
        var moving: [(pos: SIMD3<Double>, radius: Double)] = []
        var sleeping: [(id: Int, pos: SIMD3<Double>, radius: Double)] = []
        for (o, act) in zip(objects, acts) {
            o.restFor = act.restFor
            if slept.contains(o.id) {
                o.asleep = true
                o.setVelocity(.zero, angular: .zero)
                o.setMode(.static)
                o.lastSafeY = o.entity.position(relativeTo: nil).y
            }
            let r = 0.5 * simd_length(SimFrame.f3(o.size))
            let c = SimFrame.d3(o.center)
            if o.asleep { sleeping.append((id: o.id, pos: c, radius: Double(r))) }
            else if o.speed > 0.1 || o.held { moving.append((pos: c, radius: Double(r))) }
            if !o.asleep, let d = o.item.physics?.linearDamping, d > 0 {
                let v = o.velocity
                let k = Float(max(0, 1 - d * dt))
                o.setVelocity(SIMD3(v.x * k, v.y, v.z * k))
            }
        }
        if !moving.isEmpty, !sleeping.isEmpty {
            for id in SimSleep.neighboursToWake(moving: moving, sleeping: sleeping) {
                if let o = objects.first(where: { $0.id == id }) { wake(o) }
            }
        }
    }

    /// The mesh under sleeping objects changed (a table moved, a box taken away): wake them so they can fall.
    private func wakeObjects(over regions: [Bounds3]) {
        let cols = objects.map { o -> Bounds3 in
            let c = SimFrame.d3(o.center), s = o.size
            return SupportWake.column(center: c, halfXZ: max(s.x, s.z) / 2, bottom: c.y - s.y / 2, top: c.y + s.y / 2)
        }
        for i in SupportWake.affected(columns: cols, regions: regions) { wake(objects[i]) }
    }

    /// Safety net for tunnelling through the noisy mesh: an object far below where it last rested goes back onto the
    /// first surface under where it is (or where it last rested).
    private func rescueFallen() {
        for o in objects where !o.asleep && !o.held {
            let p = o.entity.position(relativeTo: nil)
            if o.speed < 0.05 && p.y > o.lastSafeY - 0.6 { o.lastSafeY = p.y; continue }
            guard p.y < o.lastSafeY - 2.0 else { continue }
            let g = SimFrame.ground(p)
            let top = o.lastSafeY + 0.5
            let f = query.surfaceBelow(g, top: top, length: 3)
            let y = (f ?? o.lastSafeY) + 0.05
            o.entity.position = SIMD3(p.x, y, p.z)
            o.setVelocity(.zero, angular: .zero)
            stats.rescues += 1
            model.log.event("sim_rescue", ["id": .int(o.id), "kind": .string(o.item.key), "from_y": .double(Double(p.y)),
                                           "to_y": .double(Double(y)), "found_floor": .bool(f != nil)])
        }
    }

    // MARK: support physics (9.4)

    /// Wake bodies over changed mesh, step the awake ones (probe → fall / land / pop up), let resting ones sleep.
    /// Thermal: probes run only for awake bodies (5 short rays each), the mesh queue coalesces bursts to ≤ 4 Hz, and a
    /// slow backstop sweep re-checks ≤ 3 sleeping bodies every few seconds (budget).
    private func stepSupport(dt: Double, regions: [Bounds3]) {
        let now = CACurrentMediaTime()
        let cubes = cubeSource?() ?? []
        let liveCubes = Set(cubes.map { $0.0 })
        cubeSupport = cubeSupport.filter { liveCubes.contains($0.key) }
        cubeConfirmed = cubeConfirmed.filter { liveCubes.contains($0) }
        awake = awake.filter { if case .cube(let id) = $0 { return liveCubes.contains(id) } else { return true } }
        var refs: [BodyRef] = []
        var columns: [Bounds3] = []
        func addColumn(_ ref: BodyRef, _ c: SIMD3<Double>, _ half: Double, _ bottom: Double, _ top: Double) {
            refs.append(ref)
            columns.append(SupportWake.column(center: c, halfXZ: half, bottom: bottom, top: top))
        }
        if let r = robot {
            let e = r.size
            addColumn(.robot, SimFrame.d3(SimFrame.world(r.position, y: r.floorY)), max(e.x, e.z) / 2,
                      Double(r.floorY), Double(r.floorY) + e.y)
        }
        for a in animals {
            let e = a.size
            addColumn(.animal(a.id), SimFrame.d3(SimFrame.world(a.brain.state.pos, y: a.floorY)), e.x / 2,
                      Double(a.floorY), Double(a.floorY) + e.y)
        }
        for (id, body) in cubes {
            let p = SimFrame.d3(body.position(relativeTo: nil))
            addColumn(.cube(id), p, 0.08, p.y, p.y + 0.1)
        }
        if !regions.isEmpty {
            for i in SupportWake.affected(columns: columns, regions: regions) { awake.insert(refs[i]) }
        }
        if now - lastSweep >= budget.sweepEveryS, !refs.isEmpty {     // backstop: a missed or merged update
            lastSweep = now
            for k in 0..<min(3, refs.count) { awake.insert(refs[(sweepCursor + k) % refs.count]) }
            sweepCursor = (sweepCursor + 3) % max(refs.count, 1)
        }
        guard !awake.isEmpty else { return }
        let cubeBodies = Dictionary(cubes, uniquingKeysWith: { a, _ in a })
        for ref in awake {
            var settled = true
            switch ref {
            case .robot:
                guard let r = robot else { awake.remove(ref); continue }
                let p = r.drive.profile
                let hits = query.supportHits(center: r.position, yaw: r.drive.pose.theta, halfL: p.length / 2,
                                             halfW: p.width / 2, top: Float(r.support.bottom + p.maxStep + 0.02))
                let ev = SupportPhysics.step(&r.support, support: SupportPhysics.supportHeight(hits: hits), dt: dt,
                                             popUp: p.maxStep)
                r.floorY = Float(r.support.bottom)
                supportEvent(ev, kind: "robosnailbob", id: Self.robotID)
                settled = !r.support.falling
            case .animal(let id):
                guard let a = animals.first(where: { $0.id == id }), !a.isKnocked else { awake.remove(ref); continue }
                let e = a.size
                let up = AnimalReach.maxStep(scale: a.scale)
                let hits = query.supportHits(center: a.brain.state.pos, yaw: a.brain.state.heading, halfL: e.x / 2,
                                             halfW: e.z / 2, top: Float(a.support.bottom + up + 0.02))
                let ev = SupportPhysics.step(&a.support, support: SupportPhysics.supportHeight(hits: hits), dt: dt, popUp: up)
                a.floorY = Float(a.support.bottom)
                supportEvent(ev, kind: a.species, id: id)
                settled = !a.support.falling
            case .cube(let id):
                guard let body = cubeBodies[id] else { awake.remove(ref); continue }
                // only cubes standing on near-level surfaces (Geo.placementTransform levels ≤ 20°); wall cubes stick
                guard body.convert(direction: SIMD3<Float>(0, 1, 0), to: nil).y > 0.94 else { awake.remove(ref); continue }
                let w = body.position(relativeTo: nil)
                var s = cubeSupport[id] ?? SupportState(bottom: Double(w.y))
                let hits = query.supportHits(center: SimFrame.ground(w), yaw: 0, halfL: 0.05, halfW: 0.05,
                                             top: Float(s.bottom + 0.04))
                let sup = SupportPhysics.supportHeight(hits: hits)
                if let f = sup, abs(f - s.bottom) <= SupportPhysics.restTolerance * 2 { cubeConfirmed.insert(id) }
                guard cubeConfirmed.contains(id) || s.falling else { awake.remove(ref); continue }
                let ev = SupportPhysics.step(&s, support: sup, dt: dt, popUp: 0.02)
                cubeSupport[id] = s
                if abs(Float(s.bottom) - w.y) > 1e-4 { body.setPosition(SIMD3(w.x, Float(s.bottom), w.z), relativeTo: nil) }
                supportEvent(ev, kind: "cube", id: -1)
                settled = !s.falling
            }
            if settled { awake.remove(ref) }
        }
    }

    private func supportEvent(_ ev: SupportEvent, kind: String, id: Int) {
        switch ev {
        case .landed(let drop) where drop > 0.03:
            stats.falls += 1
            model.log.event("sim_support", ["kind": .string(kind), "id": .int(id), "event": .string("landed"),
                                            "drop_m": .double((drop * 1000).rounded() / 1000)])
        case .poppedUp(let rise) where rise > 0.02:
            model.log.event("sim_support", ["kind": .string(kind), "id": .int(id), "event": .string("pop_up"),
                                            "rise_m": .double((rise * 1000).rounded() / 1000)])
        case .unsupported:
            model.log.event("sim_support", ["kind": .string(kind), "id": .int(id), "event": .string("no_mesh_below")])
        default: break
        }
    }

    // MARK: robot

    /// Joystick, or the autonomous task (Go to / Follow me / Patrol) through the path follower. Moving the stick always
    /// takes control back.
    private func robotCommand(_ r: SimRobot) -> DriveCommand {
        let stickActive = SimMath.length(stick) > shaper.deadzone
        if r.agenda.isAutonomous && stickActive {
            model.log.event("sim_cmd", ["id": .int(Self.robotID), "kind": .string("robot"), "cmd": .string("manual"),
                                        "from": .string(r.agenda.task.name)])
            r.agenda.stickMoved()
            r.follower = nil
            clearMarkers()
        }
        guard r.agenda.isAutonomous else { return shaper.command(stick, profile: r.drive.profile) }
        let now = CACurrentMediaTime()
        if r.agenda.task == .follow, !robotPlanInFlight, now - lastRobotPlan > 2 {
            let me = cameraGround.pos
            if SimMath.length(me - (r.follower?.goal ?? .zero)) > 0.4 || r.follower == nil { requestRobotPlan() }
        }
        guard var f = r.follower else { return .stop }               // waiting for a plan
        if let c = f.command(pose: r.drive.pose, profile: r.drive.profile) {
            r.follower = f
            return c
        }
        // arrived
        r.follower = nil
        let task = r.agenda.task
        r.agenda.arrived()
        switch task {
        case .goTo:
            model.log.event("sim_arrived", ["id": .int(Self.robotID), "kind": .string("robot")])
            model.flash("RobosnailBob arrived", seconds: 1.5)
            clearMarkers()
        case .patrol: requestRobotPlan()
        default: break
        }
        return .stop
    }

    /// Plan the robot to its current goal on the scene-mesh grid (background), then follow it.
    private func requestRobotPlan() {
        guard let r = robot, let goal = r.agenda.goal(phone: cameraGround.pos) else { return }
        robotPlanToken += 1
        let token = robotPlanToken
        robotPlanInFlight = true
        lastRobotPlan = CACurrentMediaTime()
        let p = r.drive.profile
        let stop = r.agenda.stopDistance
        plan(from: r.position, to: goal, floorY: r.floorY, radius: p.agentRadius, maxStep: p.maxStep, maxDrop: p.maxDrop,
             bodyHeight: p.height, cell: max(0.04, min(0.08, p.agentRadius / 3)), kind: "robot") { [weak self] result in
            guard let self, let r = self.robot, token == self.robotPlanToken else { return }
            self.robotPlanInFlight = false
            switch result {
            case .success(let path):
                r.follower = PathFollower(path: path, stopDistance: stop)
                self.robotBlockedFor = 0
            case .failure(let why):
                if r.agenda.task == .follow { r.follower = nil; return }         // try again on the next refresh
                r.agenda.stop()
                r.follower = nil
                self.clearMarkers()
                self.model.flash(Self.planText(why), seconds: 2.5)
            }
        }
    }

    static func planText(_ f: PlanFailure) -> String {
        switch f {
        case .startOutside, .goalOutside: return "Too far: tap a point within ~6 m"
        case .goalBlocked: return "Can't stand there (wall, furniture or a drop)"
        case .noPath: return "No way there on the scanned floor: sweep the phone over the floor between"
        }
    }

    /// A* on a grid built from the scene mesh around start and goal (≤ 7 m half-size), off the main thread.
    private func plan(from: V2, to: V2, floorY: Float, radius: Double, maxStep: Double, maxDrop: Double,
                      bodyHeight: Double, cell: Double, kind: String,
                      done: @escaping (Result<[V2], PlanFailure>) -> Void) {
        let mid = (from + to) / 2
        let half = min(7, max(3, SimMath.length(to - from) / 2 + 2))
        let spec = GridSpec(center: mid, half: half, cell: cell)
        let region = Bounds3(min: SIMD3(mid.x - half, Double(floorY) - 2, -mid.y - half),
                             max: SIMD3(mid.x + half, Double(floorY) + bodyHeight + 1, -mid.y + half))
        let anchors = meshSource.anchors(in: arView.session, near: region)
        let refFloor = Double(floorY)
        stats.plans += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = CACurrentMediaTime()
            var b = NavGridBuilder(spec: spec, refFloor: refFloor, maxStep: maxStep, maxDrop: maxDrop, bodyHeight: bodyHeight)
            SimMeshSource.addTriangles(of: anchors, to: &b)
            let grid = b.build(inflate: radius, clearAround: from, clearRadius: radius + 0.1)
            let result = AStar.plan(grid, from: from, to: to)
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                var ev: [String: LogValue] = ["kind": .string(kind), "ms": .double(ms.rounded()), "anchors": .int(anchors.count),
                                              "cells": .int(spec.nx * spec.ny)]
                switch result {
                case .success(let path):
                    ev["ok"] = .bool(true)
                    ev["length_m"] = .double((AStar.length(path) * 100).rounded() / 100)
                    ev["waypoints"] = .int(path.count)
                case .failure(let why):
                    ev["ok"] = .bool(false)
                    ev["reason"] = .string(why.rawValue)
                }
                self?.model.log.event("sim_plan", ev)
                done(result)
            }
        }
    }

    private func stepRobot(_ r: SimRobot, dt: Double) {
        r.drive.updateVelocities(dt: dt)
        let cur = r.drive.pose
        let next = r.drive.propose(dt: dt)
        let move = next.position - cur.position
        guard SimMath.length(move) > 1e-7 else { r.drive.commit(next); return }   // turning in place
        guard !r.support.falling else { r.drive.commit(DrivePose(x: cur.x, y: cur.y, theta: cur.theta)); return }
        var (allowed, hitWall) = sweep(r, from: cur.position, move: move, theta: next.theta)
        // other agents: the robot never drives through an animal (objects it pushes: resolveContacts); 9.9: driving
        // into one at speed knocks it (Impact), and only animals at the robot's level count
        let level = animals.filter { abs(Double($0.floorY - r.floorY)) < max($0.size.y, r.size.y) * 0.8 }
        let others = level.map { (pos: $0.brain.state.pos, radius: $0.brain.profile.radius) }
        let rr = r.drive.profile.agentRadius
        for a in level where !a.isKnocked {
            guard SimCollide.agentBlocked(from: cur.position, to: cur.position + allowed, radius: rr,
                                          others: [(pos: a.brain.state.pos, radius: a.brain.profile.radius)]) else { continue }
            let d = a.brain.state.pos - cur.position
            let dl = SimMath.length(d)
            guard dl > 1e-6 else { continue }
            let closing = SimMath.dot(r.velocity, d / dl)
            guard closing > 0.05 else { continue }
            hitAnimal(a, dv: Impact.deltaV(hitterMass: 60 * pow(r.scale, 3), animalMass: a.massKg, closingSpeed: closing,
                                           normal: SIMD3(d.x / dl, 0, -d.y / dl)),
                      source: .robot, by: "robosnailbob", from: cur.position, impactSpeed: closing)
        }
        if SimCollide.agentBlocked(from: cur.position, to: cur.position + allowed, radius: rr, others: others) {
            allowed = .zero
            hitWall = true
        }
        // floor ahead (direction of travel, front/back edge): step up = wall, drop = cliff, no mesh = stop
        let dir = SimMath.dot(move, SimMath.unit(cur.theta)) >= 0 ? 1.0 : -1.0
        let edge = cur.position + allowed + SimMath.unit(next.theta) * (dir * r.drive.profile.length / 2)
        let check = StepCheck.classify(currentFloor: Double(r.floorY),
                                       newFloor: query.floor(at: edge, nearY: r.floorY).map { Double($0) },
                                       maxStep: r.drive.profile.maxStep, maxDrop: r.drive.profile.maxDrop)
        if check != .ok {
            r.drive.commit(DrivePose(x: cur.x, y: cur.y, theta: next.theta))
            r.drive.bump()
            blocked(check.rawValue, at: edge)
            robotStalled(r, dt: dt)
            return
        }
        if SimMath.length(allowed) < 1e-7 {
            r.drive.commit(DrivePose(x: cur.x, y: cur.y, theta: next.theta))
            r.drive.bump()
            if hitWall { blocked("wall", at: cur.position) }
            robotStalled(r, dt: dt)
            return
        }
        let np = cur.position + allowed
        r.drive.commit(DrivePose(x: np.x, y: np.y, theta: next.theta))
        r.odometer += SimMath.length(allowed)
        if let f = query.floor(at: np, nearY: r.floorY) {
            r.floorY += (f - r.floorY) * 0.3
            r.support.bottom = Double(r.floorY)
        }
        if hitWall { blocked("slide", at: np) }
        if SimMath.length(allowed) > 0.5 * SimMath.length(move) { robotBlockedFor = 0 }
    }

    /// Autonomous robot blocked: replan after 1.5 s (the mesh may show the gap better now), give up after 3 tries.
    private func robotStalled(_ r: SimRobot, dt: Double) {
        guard r.agenda.isAutonomous else { return }
        robotBlockedFor += dt
        guard robotBlockedFor > 1.5, !robotPlanInFlight else { return }
        robotBlockedFor = 0
        robotReplans += 1
        if robotReplans > 3 {
            robotReplans = 0
            r.agenda.stop()
            r.follower = nil
            clearMarkers()
            model.log.event("sim_cmd", ["id": .int(Self.robotID), "kind": .string("robot"), "cmd": .string("stop"),
                                        "reason": .string("stuck")])
            model.flash("RobosnailBob is stuck: stopped", seconds: 2)
        } else {
            requestRobotPlan()
        }
    }

    /// Convex cast of the robot's footprint box (from step height to the mast top) against the scene mesh; on a hit,
    /// move up to the contact and slide the rest along the surface. Returns the allowed move and whether it touched.
    /// 9.4 (owner log 2026-10-13: robot spawned and never moved, 790 "wall" blocks in 30 s): when the full box ALREADY
    /// overlaps the mesh at the start every cast hit at distance 0 and trapped it. Now an inset box decides; if even
    /// that starts inside the mesh, the robot may drive (out) rather than freeze forever. 9.8: sizes follow the scale.
    private func sweep(_ r: SimRobot, from a: V2, move: V2, theta: Double) -> (V2, Bool) {
        let p = r.drive.profile
        let h = Float(max(0.03, p.height - p.maxStep - 0.01))
        let y = r.floorY + Float(p.maxStep) + 0.005 + h / 2
        let inset = Float(min(0.05, p.width * 0.15))
        let full = ShapeResource.generateBox(size: SIMD3(Float(p.length - 2 * Self.skin), h, Float(p.width - 2 * Self.skin)))
        let small = ShapeResource.generateBox(size: SIMD3(max(0.02, Float(p.length) - 2 * inset), max(0.02, h - 0.04),
                                                          max(0.02, Float(p.width) - 2 * inset)))
        let q = SimFrame.yaw(theta)
        func cast(_ shape: ShapeResource, _ from: V2, _ to: V2) -> CollisionCastHit? {
            query.rays += 1
            return arView.scene.convexCast(convexShape: shape, fromPosition: SimFrame.world(from, y: y), fromOrientation: q,
                                           toPosition: SimFrame.world(to, y: y), toOrientation: q, query: .nearest,
                                           mask: .sceneUnderstanding, relativeTo: nil).first
        }
        func limit(_ from: V2, _ m: V2) -> (V2, V2?) {          // (allowed part, wall normal if hit)
            let len = SimMath.length(m)
            guard len > 1e-9, var hit = cast(full, from, from + m) else { return (m, nil) }
            if hit.distance < 1e-3 {
                guard let h2 = cast(small, from, from + m) else { return (m, nil) }
                if h2.distance < 1e-3 { noteOverlap(at: from); return (m, nil) }
                hit = h2
            }
            var n = V2(Double(hit.normal.x), Double(-hit.normal.z))
            if SimMath.length(n) < 0.2 { n = -m / len }            // floor/ceiling-ish normal: treat as head-on
            n /= SimMath.length(n)
            let dist = Double(hit.distance)
            if dist <= 1e-4 && SimMath.dot(m, n) >= 0 { return (m, nil) }   // already touching, moving away
            let frac = SimMath.clamp((dist - Self.skin) / len, 0, 1)
            return (m * frac, n)
        }
        let (first, n1) = limit(a, move)
        guard let n = n1 else { return (first, false) }
        let rest = SimCollide.slide(move - first, normal: n)
        let (second, _) = limit(a + first, rest)
        return (first + second, true)
    }

    private var lastOverlapLog: TimeInterval = 0
    private func noteOverlap(at g: V2) {
        stats.overlaps += 1
        let now = Date().timeIntervalSince1970
        guard now - lastOverlapLog >= 5 else { return }
        lastOverlapLog = now
        model.log.event("sim_overlap", ["at": .doubles([g.x, g.y]), "count": .int(stats.overlaps)])
    }

    private func blocked(_ reason: String, at g: V2) {
        switch reason {
        case "cliff": stats.cliffs += 1
        case "noFloor": stats.noFloor += 1
        default: stats.blocks += 1
        }
        let now = Date().timeIntervalSince1970
        guard reason != "slide", now - lastBlockLog >= 2 else { return }
        lastBlockLog = now
        model.log.event("sim_block", ["reason": .string(reason), "at": .doubles([g.x, g.y])])
        switch reason {
        case "cliff": note("Robot stopped: drop ahead")
        case "noFloor": note("Robot stopped: no floor mesh ahead, sweep the phone over the floor")
        case "wall": note("Bump")
        default: break
        }
    }

    private func note(_ s: String) {
        model.flash(s, seconds: 1.5)
    }

    // MARK: selection

    private struct BodyInfo {
        var kind: SimKind
        var ground: V2
        var floorY: Float
        var yaw: Double
        var size: SIMD3<Double>
        var center: SIMD3<Float>
        var orientation: simd_quatf
        var title: String
        var symbol: String
        var scale: Double
        var scaleOverride: Double?
    }

    private func info(_ id: Int) -> BodyInfo? {
        if id == Self.robotID, let r = robot {
            let s = r.size
            return BodyInfo(kind: .robot, ground: r.position, floorY: r.floorY, yaw: r.drive.pose.theta, size: s,
                            center: SimFrame.world(r.position, y: r.floorY + Float(s.y / 2)),
                            orientation: SimFrame.yaw(r.drive.pose.theta), title: SimKind.robot.label, symbol: "car.side",
                            scale: r.scale, scaleOverride: r.scaleOverride)
        }
        if let a = animal(id) {
            let s = a.size
            return BodyInfo(kind: a.kind, ground: a.brain.state.pos, floorY: a.floorY, yaw: a.brain.state.heading,
                            size: s, center: SimFrame.world(a.brain.state.pos, y: a.floorY + Float(s.y / 2)),
                            orientation: SimFrame.yaw(a.brain.state.heading), title: "\(a.item.label) #\(id)",
                            symbol: a.item.symbol, scale: a.scale, scaleOverride: a.scaleOverride)
        }
        if let o = object(id) {
            let p = o.entity.position(relativeTo: nil)
            let fwd = o.entity.convert(direction: SIMD3<Float>(1, 0, 0), to: nil)
            return BodyInfo(kind: o.kind, ground: SimFrame.ground(p), floorY: p.y,
                            yaw: atan2(Double(-fwd.z), Double(fwd.x)), size: o.size, center: o.center,
                            orientation: o.entity.orientation(relativeTo: nil), title: "\(o.item.label) #\(id)",
                            symbol: o.item.symbol, scale: o.scale, scaleOverride: o.scaleOverride)
        }
        return nil
    }

    private var allIDs: [Int] { (robot == nil ? [] : [Self.robotID]) + animals.map { $0.id } + objects.map { $0.id } }

    private func pick(at pt: CGPoint) -> Int? {
        guard let ray = arView.ray(through: pt) else { return nil }
        let bodies = allIDs.compactMap { id -> PickBody? in
            guard let i = info(id) else { return nil }
            if object(id) != nil {                       // tumbling objects: their world AABB
                guard let o = object(id) else { return nil }
                let b = o.entity.visualBounds(relativeTo: nil)
                let ext = o.hasModel && b.extents.x > 0 ? SimFrame.d3(b.extents) : i.size
                return PickBody(id: id, center: SimFrame.d3(o.hasModel ? b.center : i.center), size: ext, yaw: 0)
            }
            return PickBody(id: id, center: SimFrame.d3(i.center), size: i.size, yaw: i.yaw)
        }
        return SimPick.pick(origin: SimFrame.d3(ray.origin), dir: SimFrame.d3(ray.direction), bodies: bodies)
    }

    /// Taps while the sim is on (ARSessionController forwards them first). true = handled here.
    func handleTap(_ pt: CGPoint) -> Bool {
        guard enabled, !pausedForRecording else { return false }
        if let c = ui.pending {
            guard let h = standHit(at: pt) else {
                model.flash(standHint())
                return true
            }
            applyPoint(c, h)
            return true
        }
        if let id = pick(at: pt) {
            if let o = object(id) { poke(o) }
            select(id)
            return true
        }
        if ui.selection != nil {                    // tap on empty floor = deselect (does not also drop a cube)
            select(nil)
            return true
        }
        return false
    }

    /// A tap on an object: a little shove away from you (and a hop).
    private func poke(_ o: SimObject) {
        wake(o)
        let d = Poke.velocityChange(cameraToObject: SimFrame.d3(o.center - cameraPosition)) * max(0.5, o.scale)
        let v = o.velocity
        o.setVelocity(v + SimFrame.f3(d), angular: SIMD3(Float.random(in: -3...3), Float.random(in: -3...3),
                                                           Float.random(in: -3...3)))
        stats.pokes += 1
        model.log.event("sim_poke", ["id": .int(o.id), "kind": .string(o.item.key)])
    }

    private func select(_ id: Int?) {
        if ui.pending != nil { cancelPending() }
        guard let id, let i = info(id) else {
            if let old = ui.selection { model.log.event("sim_select", ["id": .int(old.id), "cleared": .bool(true)]) }
            ui.selection = nil
            highlight.entity.isEnabled = false
            showHome(nil)
            return
        }
        showHome(id)
        highlight.setSize(i.size)
        highlight.entity.isEnabled = true
        ui.selection = selection(id, i)
        model.log.event("sim_select", ["id": .int(id), "kind": .string(i.kind.rawValue),
                                       "pos": .doubles([i.ground.x, i.ground.y, Double(i.floorY)]),
                                       "size_m": .doubles([i.size.x, i.size.y, i.size.z]), "scale": .double(i.scale)])
    }

    private func refreshSelection() {
        guard let sel = ui.selection, let i = info(sel.id) else { return }
        highlight.setSize(i.size)
        ui.selection = selection(sel.id, i)
    }

    static func dims(_ s: SIMD3<Double>) -> String {
        let m = max(s.x, max(s.y, s.z))
        if m < 0.6 { return String(format: "%.0f × %.0f × %.0f cm", s.x * 100, s.z * 100, s.y * 100) }
        return String(format: "%.2f × %.2f × %.2f m", s.x, s.z, s.y)
    }

    private func selection(_ id: Int, _ i: BodyInfo) -> SimSelection {
        var task = ""
        if id == Self.robotID, let r = robot { task = r.agenda.task.name }
        else if let a = animal(id) { task = a.brain.order.name }
        else if let o = object(id) {
            task = o.held ? "held" : o.asleep ? "resting" : o.speed > 0.05 ? "moving" : "settling"
            task += String(format: " · %@", o.massKg < 1 ? String(format: "%.0f g", o.massKg * 1000)
                                                         : String(format: "%.1f kg", o.massKg))
        }
        return SimSelection(id: id, kind: i.kind, title: i.title, detail: "\(Self.dims(i.size)) · \(task)",
                            symbol: i.symbol, scale: i.scale, scaleIsOverride: i.scaleOverride != nil)
    }

    /// Highlight, label and the 1 m reference follow their bodies every frame.
    private func updateOverlays() {
        let cam = cameraPosition
        if let sel = ui.selection {
            if let i = info(sel.id) {
                highlight.place(center: i.center, orientation: i.orientation, camera: cam)
                let now = Date().timeIntervalSince1970
                if now - lastSelectionText >= 0.5 {
                    lastSelectionText = now
                    let s = selection(sel.id, i)
                    highlight.setText(s.title)
                    if s != ui.selection { ui.selection = s }
                }
            } else {
                select(nil)                                        // deleted elsewhere
            }
        }
        if ui.scaleRef {
            if let id = ui.selection?.id ?? (robot != nil ? Self.robotID : nil), let i = info(id) {
                let right = SimMath.unit(i.yaw - .pi / 2)
                scaleRef.place(center: i.ground + right * (i.size.z / 2 + 0.15), heading: i.yaw, y: i.floorY, camera: cam)
                scaleRef.entity.isEnabled = true
            } else if let s = scaleRefStatic {
                scaleRef.place(center: s.0, heading: s.1, y: s.2, camera: cam)
                scaleRef.entity.isEnabled = true
            } else {
                scaleRef.entity.isEnabled = false
            }
        }
    }

    private func scaleRefChanged(_ on: Bool) {
        scaleRef.entity.isEnabled = on
        scaleRefStatic = nil
        if on, let p = centreFloorHit() {
            scaleRefStatic = (SimFrame.ground(p), cameraGround.heading + .pi / 2, p.y)     // across your view
        }
        var ev: [String: LogValue] = ["on": .bool(on)]
        if on, let r = robot {      // the owner's 2× check in numbers: robot box vs the 1.000 m bar
            ev["robot_m"] = .doubles([r.size.x, r.size.z, r.size.y])
            ev["robot_scale"] = .double(r.scale)
            ev["bar_m"] = .double(ScaleReference.lengthM)
        }
        model.log.event("sim_scale_ref", ev)
        if on { updateOverlays() }
    }

    // MARK: per-body scale (selection bar −/+)

    func adjustSelectedScale(up: Bool?) {
        guard let sel = ui.selection, let i = info(sel.id) else { return }
        let new: Double? = up.map { SimScale.step(i.scale, up: $0) }        // nil = back to the global scale
        let s = SimScale.effective(global: globalScale, override: new)
        if sel.id == Self.robotID, let r = robot { r.scaleOverride = new; r.setScale(s); r.render(dt: 0); awake.insert(.robot) }
        else if let a = animal(sel.id) { a.scaleOverride = new; a.setScale(s); a.render(); awake.insert(.animal(a.id)) }
        else if let o = object(sel.id) { o.scaleOverride = new; o.setScale(s); wake(o) }
        refreshSelection()
        model.log.event("sim_scale", ["id": .int(sel.id), "kind": .string(sel.kind.rawValue),
                                      "scale": .double(s), "override": .bool(new != nil)])
        if !sel.kind.isObject { onEntitiesChanged?() }
    }

    // MARK: commands

    func command(_ c: SimCommand) {
        guard let sel = ui.selection else { return }
        if c.needsPoint {
            ui.pending = c
            patrolPts = []
            ui.patrolPoints = 0
            clearMarkers()
            switch c {
            case .move: ui.prompt = "Tap where it should go (or drag it)"
            case .goTo: ui.prompt = "Tap the floor: \(sel.kind == .robot ? "RobosnailBob drives" : "it walks") there"
            default: ui.prompt = "Tap patrol points on the floor, then Start"
            }
            return
        }
        var ev: [String: LogValue] = ["id": .int(sel.id), "kind": .string(sel.kind.rawValue), "cmd": .string(c.rawValue)]
        switch c {
        case .rotateLeft, .rotateRight: rotate(sel.id, by: c == .rotateLeft ? .pi / 4 : -.pi / 4)
        case .delete: delete(sel.id)
        case .duplicate:
            if let newID = duplicate(sel.id) { ev["new_id"] = .int(newID) } else { ev["ok"] = .bool(false) }
        case .follow:
            if sel.id == Self.robotID, let r = robot {
                r.agenda.follow()
                r.follower = nil
                robotReplans = 0
                requestRobotPlan()
            } else { animal(sel.id)?.brain.setOrder(.follow) }
        case .stop:
            if let r = robot { r.agenda.stop(); r.follower = nil; clearMarkers() }
        case .flee, .graze, .stay, .wander:
            let order: AnimalOrder = c == .flee ? .flee : c == .graze ? .graze : c == .stay ? .stay : .wander
            animal(sel.id)?.brain.setOrder(order, person: cameraGround.pos)
            clearMarkers()
        case .roam, .pace:                                   // P2a: live in this room
            if let a = animal(sel.id) {
                if a.brain.home == nil {
                    a.brain.setHome(Poly.circle(center: a.brain.state.pos, radius: RoomBounds.fallbackRadius))
                    computeHome(sel.id)
                }
                if c == .roam { a.brain.setOrder(.roam) }
                else if let h = a.brain.home { a.brain.setOrder(.pace(RoomPatrol.loop(home: h, from: a.brain.state.pos))) }
                ev["home_m2"] = .double((Poly.area(a.brain.home ?? []) * 10).rounded() / 10)
                showHome(sel.id)
            }
            clearMarkers()
        case .move, .goTo, .patrol: break
        }
        model.log.event("sim_cmd", ev)
        if c != .follow && c != .stop && !sel.kind.isObject { onEntitiesChanged?() }
    }

    func cancelPending() {
        ui.pending = nil
        ui.prompt = nil
        ui.patrolPoints = 0
        patrolPts = []
    }

    /// Patrol: start cycling the tapped points.
    func startPatrol() {
        guard let r = robot, ui.selection?.id == Self.robotID else { cancelPending(); return }
        let pts = patrolPts
        cancelPending()
        guard pts.count >= 2 else { model.flash("Tap at least two patrol points"); return }
        r.agenda.patrol(pts)
        r.follower = nil
        robotReplans = 0
        requestRobotPlan()
        model.log.event("sim_cmd", ["id": .int(Self.robotID), "kind": .string("robot"), "cmd": .string("patrol"),
                                    "points": .doubles(pts.flatMap { [$0.x, $0.y] })])
    }

    private func applyPoint(_ c: SimCommand, _ h: StandHit) {
        guard let sel = ui.selection else { cancelPending(); return }
        let p = h.point
        let g = SimFrame.ground(p)
        switch c {
        case .move:
            cancelPending()
            let doMove = { [weak self] in
                guard let self else { return }
                self.teleport(sel.id, to: g, floorY: p.y)
                self.rehome(sel.id)
                self.model.log.event("sim_cmd", ["id": .int(sel.id), "kind": .string(sel.kind.rawValue), "cmd": .string("move"),
                                                 "target": .doubles([g.x, g.y, Double(p.y)]), "surface": .string(h.kind.rawValue)])
            }
            if sel.id == Self.robotID, let r = robot {      // 9.9: a table only if big / strong enough
                robotSurface(h, scale: r.scale) { [weak self] v in
                    self?.logSurface("robot", h, verdict: v.rawValue)
                    if v == .ok { doMove() }
                    else { self?.model.flash(RobotSurface.hint(v, robotMassKg: 60 * pow(r.scale, 3)) ?? "", seconds: 3) }
                }
            } else {
                doMove()
            }
        case .goTo:
            cancelPending()
            setMarkers([p])
            model.log.event("sim_cmd", ["id": .int(sel.id), "kind": .string(sel.kind.rawValue), "cmd": .string("goTo"),
                                        "target": .doubles([g.x, g.y, Double(p.y)])])
            if sel.id == Self.robotID, let r = robot {
                r.agenda.goTo(g)
                r.follower = nil
                robotReplans = 0
                requestRobotPlan()
            } else if let a = animal(sel.id) {
                let pr = a.brain.profile
                let id = a.id
                plan(from: a.brain.state.pos, to: g, floorY: a.floorY, radius: pr.radius,
                     maxStep: AnimalReach.maxStep(scale: a.scale), maxDrop: AnimalReach.maxDrop(scale: a.scale),
                     bodyHeight: a.size.y, cell: max(0.04, min(0.06, pr.radius / 2)), kind: a.species) { [weak self] result in
                    guard let self, let a = self.animal(id) else { return }
                    switch result {
                    case .success(let path): a.brain.setOrder(.goTo(path))
                    case .failure(let why):
                        self.clearMarkers()
                        self.model.flash(Self.planText(why), seconds: 2.5)
                    }
                }
            }
        case .patrol:
            patrolPts.append(g)
            ui.patrolPoints = patrolPts.count
            addMarker(p)
            ui.prompt = "Patrol: \(patrolPts.count) point\(patrolPts.count == 1 ? "" : "s") · tap more, then Start"
        default:
            cancelPending()
        }
    }

    private func animal(_ id: Int) -> SimAnimal? { animals.first { $0.id == id } }
    private func object(_ id: Int) -> SimObject? { objects.first { $0.id == id } }

    private func teleport(_ id: Int, to g: V2, floorY: Float) {
        if id == Self.robotID, let r = robot {
            r.drive.commit(DrivePose(x: g.x, y: g.y, theta: r.drive.pose.theta))
            r.drive.bump()
            r.floorY = floorY
            r.support = SupportState(bottom: Double(floorY))
            if r.agenda.isAutonomous { r.agenda.stop(); r.follower = nil; clearMarkers() }
            r.render(dt: 0)
            awake.insert(.robot)
        } else if let a = animal(id) {
            a.cancelKnock()
            a.brain.teleport(to: g)
            a.floorY = floorY
            a.lastSafeY = floorY
            a.support = SupportState(bottom: Double(floorY))
            a.render()
            awake.insert(.animal(id))
        } else if let o = object(id) {
            o.entity.position = SimFrame.world(g, y: floorY + 0.05)
            o.setVelocity(.zero, angular: .zero)
            o.lastSafeY = floorY
            wake(o)
        }
    }

    private func rotate(_ id: Int, by d: Double) {
        if id == Self.robotID, let r = robot {
            let p = r.drive.pose
            r.drive.commit(DrivePose(x: p.x, y: p.y, theta: p.theta + d))
            r.render(dt: 0)
        } else if let a = animal(id) {
            a.brain.teleport(to: a.brain.state.pos, heading: a.brain.state.heading + d)
            a.render()
        } else if let o = object(id) {
            o.entity.setOrientation(SimFrame.yaw(d) * o.entity.orientation(relativeTo: nil), relativeTo: nil)
            wake(o)
        }
    }

    /// 10.5: a body deleted on the shared server sim (by this phone or any other client): the local copy goes too, so
    /// no bulk save / hand-off import / saved place brings it back (owner 10.4.212: the robot reappeared). true = found.
    @discardableResult
    func removeBody(uid: String) -> Bool {
        guard let id = persist.first(where: { $0.value.uid == uid })?.key else { return false }
        delete(id)
        model.log.event("sim_remove_local", ["uid": .string(uid), "id": .int(id)])
        return true
    }

    private func delete(_ id: Int) {
        if let p = persist.removeValue(forKey: id) { arView.session.remove(anchor: p.anchor) }
        if id == Self.robotID {
            robot?.entity.removeFromParent()
            robot = nil
            stick = .zero
            awake.remove(.robot)
        } else if let i = animals.firstIndex(where: { $0.id == id }) {
            animals[i].entity.removeFromParent()
            animals.remove(at: i)
            awake.remove(.animal(id))
        } else if objects.contains(where: { $0.id == id }) {
            deleteObjects([id], via: "command")
            return
        }
        clearMarkers()
        select(nil)
        publish()
    }

    // MARK: 9.9 object deletion + undo, cubes

    /// Delete objects; the AR controller offers Undo for 5 s (onObjectsDeleted).
    @discardableResult
    func deleteObjects(_ ids: [Int], via: String) -> [ObjectSnapshot] {
        var snaps: [ObjectSnapshot] = []
        for id in ids {
            guard let i = objects.firstIndex(where: { $0.id == id }) else { continue }
            let o = objects[i]
            if grab?.id == id { grab = nil }
            snaps.append(ObjectSnapshot(key: o.item.key, position: o.entity.position(relativeTo: nil),
                                        orientation: o.entity.orientation(relativeTo: nil), scaleOverride: o.scaleOverride))
            o.entity.removeFromParent()
            objects.remove(at: i)
            if ui.selection?.id == id { select(nil) }
        }
        guard !snaps.isEmpty else { return [] }
        ui.objectCount = objects.count
        if objects.isEmpty { model.controller.applyRenderSettings() }
        model.log.event("sim_delete", ["count": .int(snaps.count), "kinds": .string(snaps.map { $0.key }.joined(separator: ",")),
                                       "via": .string(via)])
        let label = snaps.count == 1 ? "Deleted \(catalog.item(snaps[0].key)?.label ?? snaps[0].key)"
                                     : "Deleted \(snaps.count) sim objects"
        onObjectsDeleted?(snaps, label)
        publish()
        return snaps
    }

    /// Undo: the objects come back where they were (awake, so they settle again).
    func restoreObjects(_ snaps: [ObjectSnapshot]) {
        guard enabled else { return }
        for s in snaps {
            guard let item = catalog.item(s.key), objects.count < budget.maxObjects else { continue }
            let o = addObject(item, at: s.position, yaw: 0, override: s.scaleOverride)
            o.entity.setOrientation(s.orientation, relativeTo: nil)
        }
        model.controller.applyRenderSettings()
        publish()
    }

    /// The selection bar's ✕ (objects).
    func deleteSelected() {
        guard let id = ui.selection?.id, object(id) != nil else { return }
        deleteObjects([id], via: "bar_x")
    }

    /// Sim objects that count as cubes (blocks, crate, cardboard box) for the Cubes list / Clear cubes.
    var cubeObjects: [(id: Int, title: String, detail: String)] {
        objects.filter { SimCubes.isCube($0.item) }.map { o in
            (o.id, "\(o.item.label) #\(o.id)", Self.dims(o.size))
        }
    }

    /// The object (any kind) under a screen point, for long-press delete.
    func objectID(at pt: CGPoint) -> Int? {
        guard enabled, !pausedForRecording, let id = pick(at: pt), object(id) != nil else { return nil }
        return id
    }

    func isCubeObject(_ id: Int) -> Bool { object(id).map { SimCubes.isCube($0.item) } ?? false }

    /// Same kind beside it (to its right, else its left), on the floor found there. Returns the new id.
    private func duplicate(_ id: Int) -> Int? {
        guard let i = info(id), i.kind != .robot else { return nil }
        for side in [-1.0, 1.0] {
            let g = i.ground + SimMath.unit(i.yaw + side * .pi / 2) * (max(i.size.z, i.size.x * 0.5) + 0.15)
            guard let f = query.floor(at: g, nearY: i.floorY) else { continue }
            if let o = object(id) {
                guard objects.count < budget.maxObjects else { model.flash("Object limit reached"); return nil }
                let n = addObject(o.item, at: SimFrame.world(g, y: f + 0.1), yaw: i.yaw, override: o.scaleOverride)
                select(n.id)
                return n.id
            }
            guard let a = animal(id) else { return nil }
            let n = addAnimal(a.item, at: g, floorY: f, heading: i.yaw, override: a.scaleOverride)
            setAnchor(n.id, at: SimFrame.world(g, y: f))
            n.brain.setHome(Poly.circle(center: g, radius: RoomBounds.fallbackRadius))
            n.brain.setOrder(.roam)
            computeHome(n.id)
            select(n.id)
            return n.id
        }
        model.flash("No floor beside it to put a copy")
        return nil
    }

    // MARK: drag: move a body, or grab / throw an object

    /// Where the finger first touched (a fast flick has already moved when the pan is recognised).
    private func touchStart(_ g: UIPanGestureRecognizer) -> CGPoint {
        let p = g.location(in: arView), t = g.translation(in: arView)
        return CGPoint(x: p.x - t.x, y: p.y - t.y)
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if remoteAuthority {                            // 10.5: the shared server sim owns every body (drag / kick)
            guard g === pan, let pg = g as? UIPanGestureRecognizer else { return false }
            return model.serverSim.panShouldBegin(start: touchStart(pg), now: pg.location(in: arView), arView: arView)
        }
        guard g === pan, let pg = g as? UIPanGestureRecognizer, enabled, !pausedForRecording, ui.pending == nil else {
            return false
        }
        return pick(at: touchStart(pg)) != nil || pick(at: g.location(in: arView)) != nil
    }

    /// 9.9: drag an animal over any surface (floor, table top, shelf) and it stands there; let go with a throw and it
    /// is tossed (lands on whatever it hits); a quick flick on it is a kick. The robot drags along the floor only
    /// (Move puts it on a big table). Objects: grab and throw as in 9.8.
    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        if remoteAuthority { model.serverSim.handlePan(g, arView: arView); return }
        let pt = g.location(in: arView)
        // 10.6: the trash can (bottom centre) while dragging; dropping a body on it deletes it (same as the server sim)
        switch g.state {
        case .began:
            model.simDragging = true
            model.simDragHot = false
        case .changed:
            let hot = SimTrash.hit(x: Double(pt.x), y: Double(pt.y), viewWidth: Double(arView.bounds.width),
                                   viewHeight: Double(arView.bounds.height))
            if hot != model.simDragHot { model.simDragHot = hot }
        case .ended, .cancelled, .failed:
            let hot = model.simDragHot && g.state == .ended
            model.simDragging = false
            model.simDragHot = false
            if hot, let id = grab?.id ?? dragging?.id {
                if grab != nil { endGrab(throwIt: false) }
                dragging = nil
                model.log.event("sim_delete_request", ["id": .int(id), "via": .string("trash"), "mode": .string("local")])
                delete(id)
                onEntitiesChanged?()
                return
            }
        default: break
        }
        let now = CACurrentMediaTime()
        switch g.state {
        case .began:
            let id = pick(at: touchStart(g)) ?? pick(at: pt)
            if let id, let o = object(id) {
                beginGrab(o)
                if ui.selection?.id != id { select(id) }
                moveGrab(to: pt)
                return
            }
            guard let id else { dragging = nil; return }
            animal(id)?.cancelKnock()
            dragging = (id, now, ThrowTracker())
            robotDragNoted = false
            if ui.selection?.id != id { select(id) }
        case .changed:
            if grab != nil { moveGrab(to: pt); return }
            guard var d = dragging, let h = standHit(at: pt) else { return }
            if d.id == Self.robotID && h.kind != .floor {
                if !robotDragNoted { robotDragNoted = true; model.flash("RobosnailBob drags on the floor: use Move to put it on a big table") }
                return
            }
            teleport(d.id, to: SimFrame.ground(h.point), floorY: h.point.y)
            d.tracker.add(SimFrame.d3(h.point), at: now)
            dragging = d
        case .ended, .cancelled, .failed:
            if grab != nil { endGrab(throwIt: g.state == .ended); return }
            guard let d = dragging else { return }
            dragging = nil
            if g.state == .ended, let a = animal(d.id) {
                let sv = g.velocity(in: arView)
                let m = arView.cameraTransform.matrix
                let fwd = -SIMD3<Double>(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z))
                let t = g.translation(in: arView)
                let short = (t.x * t.x + t.y * t.y).squareRoot() < 160
                if short, let kv = Kick.velocity(screenVelocity: SIMD2(Double(sv.x), Double(sv.y)), duration: now - d.start,
                                                 cameraForward: fwd) {
                    stats.kicks += 1
                    hitAnimal(a, dv: kv, source: .kick, by: "finger", from: cameraGround.pos, force: true)
                    return
                }
                let v = d.tracker.releaseVelocity(at: now)
                if v.x * v.x + v.y * v.y + v.z * v.z > 0 {
                    hitAnimal(a, dv: v, source: .fling, by: "finger", from: cameraGround.pos, force: true)
                    return
                }
            }
            if let i = info(d.id) {
                model.log.event("sim_cmd", ["id": .int(d.id), "kind": .string(i.kind.rawValue), "cmd": .string("move"),
                                            "via": .string("drag"),
                                            "target": .doubles([i.ground.x, i.ground.y, Double(i.floorY)])])
                rehome(d.id)
            }
        default: break
        }
    }

    private func beginGrab(_ o: SimObject) {
        wake(o)
        o.held = true
        o.setMode(.kinematic)
        o.setVelocity(.zero, angular: .zero)
        let y = o.entity.position(relativeTo: nil).y + 0.03
        grab = (o.id, y, ThrowTracker())
    }

    /// The object follows the finger on a horizontal plane at its height (lift it off a table and it hovers there
    /// until you let go: then it falls).
    private func moveGrab(to pt: CGPoint) {
        guard var gr = grab, let o = object(gr.id), let ray = arView.ray(through: pt) else { return }
        let d = ray.direction
        guard abs(d.y) > 1e-3 else { return }
        let t = (gr.planeY - ray.origin.y) / d.y
        guard t > 0.05 else { return }
        var p = ray.origin + d * min(t, 6)
        if t > 6 { p.y = gr.planeY }
        o.entity.setPosition(p, relativeTo: nil)
        gr.tracker.add(SimFrame.d3(p), at: CACurrentMediaTime())
        grab = gr
    }

    private func endGrab(throwIt: Bool) {
        guard let gr = grab else { return }
        grab = nil
        guard let o = object(gr.id) else { return }
        o.held = false
        o.setMode(.dynamic)
        let v = throwIt ? gr.tracker.releaseVelocity(at: CACurrentMediaTime()) : .zero
        o.setVelocity(SimFrame.f3(v), angular: .zero)
        o.restFor = 0
        let speed = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        if speed > 0 { stats.throws += 1 }
        model.log.event("sim_throw", ["id": .int(o.id), "kind": .string(o.item.key),
                                      "speed": .double((speed * 100).rounded() / 100)])
    }

    // MARK: goal / patrol markers

    private func markerEntity() -> Entity {
        let e = Entity()
        let m = UnlitMaterial(color: UIColor(red: 0.2, green: 0.95, blue: 1.0, alpha: 1))
        let pin = ModelEntity(mesh: .generateBox(size: SIMD3(0.01, 0.18, 0.01)), materials: [m])
        pin.position.y = 0.09
        let head = ModelEntity(mesh: .generateSphere(radius: 0.022), materials: [m])
        head.position.y = 0.19
        var dm = UnlitMaterial(color: UIColor(red: 0.2, green: 0.95, blue: 1.0, alpha: 1))
        dm.blending = .transparent(opacity: 0.35)
        let disc = ModelEntity(mesh: .generatePlane(width: 0.15, depth: 0.15, cornerRadius: 0.075), materials: [dm])
        disc.position.y = 0.004
        e.addChild(pin); e.addChild(head); e.addChild(disc)
        return e
    }

    private func addMarker(_ p: SIMD3<Float>) {
        let e = markerEntity()
        e.position = p
        root.addChild(e)
        markers.append(e)
    }

    private func setMarkers(_ pts: [SIMD3<Float>]) {
        clearMarkers()
        for p in pts { addMarker(p) }
    }

    private func clearMarkers() {
        for m in markers { m.removeFromParent() }
        markers.removeAll()
    }

    // MARK: stats + HUD

    private func logStats() {
        let awakeObjects = objects.filter { !$0.asleep }.count
        var ev: [String: LogValue] = ["animals": .int(animals.count), "blocks": .int(stats.blocks),
                                      "cliffs": .int(stats.cliffs), "no_floor": .int(stats.noFloor),
                                      "spooks": .int(stats.spooks), "fps": .double(model.fps),
                                      "thermal": .string(model.thermal), "objects": .int(objects.count),
                                      "objects_awake": .int(awakeObjects), "pushes": .int(stats.pushes),
                                      "throws": .int(stats.throws), "pokes": .int(stats.pokes),
                                      "hits": .int(stats.hits), "rescues": .int(stats.rescues),
                                      "knocks": .int(stats.knocks), "kicks": .int(stats.kicks),
                                      "recovers": .int(stats.recovers),
                                      "knocked_now": .int(animals.filter { $0.isKnocked }.count),
                                      "falls": .int(stats.falls), "overlaps": .int(stats.overlaps),
                                      "plans": .int(stats.plans), "awake": .int(awake.count),
                                      "scale": .double(globalScale), "tier": .string(budget.tier.rawValue),
                                      "rays_per_s": .double(Double(query.rays) / 10),
                                      "tick_ms_avg": .double(tickMs.n > 0 ? (tickMs.sum / Double(tickMs.n) * 100).rounded() / 100 : 0),
                                      "tick_ms_max": .double((tickMs.max * 100).rounded() / 100),
                                      "paused": .string(pauseReason ?? "")]
        query.rays = 0
        tickMs = (sum: 0, max: 0, n: 0)
        if let r = robot {
            ev["robot_m"] = .double(r.odometer)
            ev["robot_pos"] = .doubles([r.position.x, r.position.y, Double(r.floorY)])
            ev["robot_task"] = .string(r.agenda.task.name)
        }
        model.log.event("sim_stats", ev)
    }

    /// HUD line (throttled by SwiftUI diffing: only changes when the text changes).
    private func publish() {
        var s: String
        if pausedForRecording { s = "Sim paused (recording)" }
        else if gated { s = "Sim waits: trying a saved place" }
        else if enabled, let why = pauseReason {
            s = why == "heat" ? "Sim paused: iOS reports critical heat" : "Sim paused: tracking limited, move slowly"
        } else {
            var parts: [String] = []
            if let r = robot {
                parts.append(String(format: "robot %.2f m/s", abs(r.drive.v)) + (r.agenda.isAutonomous ? " (\(r.agenda.task.name))" : ""))
            }
            if !animals.isEmpty { parts.append("\(animals.count) animal\(animals.count == 1 ? "" : "s")") }
            if !objects.isEmpty { parts.append("\(objects.count) object\(objects.count == 1 ? "" : "s")") }
            s = parts.joined(separator: " · ")
        }
        if s != lastNote {
            lastNote = s
            model.simStatus = s
        }
        if model.simRobot != (robot != nil) { model.simRobot = robot != nil }
    }
}

// MARK: - 12.0 UI shell: the near-you list, the Map and the command ring read / drive the local sim here

/// A local-sim body (ARKit world frame).
struct LocalSimBodyInfo: Identifiable, Equatable {
    var id: Int
    var title: String
    var role: SimKind.Role
    var world: SIMD3<Float>
    var selected: Bool
}

extension SimController {
    func bodyInfos() -> [LocalSimBodyInfo] {
        guard enabled, !pausedForRecording else { return [] }
        return allIDs.compactMap { id in
            guard let i = info(id) else { return nil }
            return LocalSimBodyInfo(id: id, title: i.title, role: i.kind.role, world: i.center, selected: ui.selection?.id == id)
        }
    }

    /// The selected body's centre in the world frame (the command ring sits around it).
    var selectedWorld: SIMD3<Float>? { ui.selection.flatMap { info($0.id)?.center } }

    func select(id: Int?) { select(id) }

    /// Map tap: the selected body goes to (or, with Move pending, is put at) this floor point (world frame).
    func goTo(world p: SIMD3<Float>) {
        guard ui.selection != nil else { return }
        applyPoint(ui.pending == .move ? .move : .goTo, StandHit(point: p, kind: .floor))
    }
}
