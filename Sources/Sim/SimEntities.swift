import Combine
import RealityKit
import UIKit
import SnailSightCore

// SnailSight sim visuals (plan §7 S). Ground frame (x, y) ↔ ARKit world (x, h, −y); heading θ = rotation about +Y.
// 9.8: every body has a `body` child scaled by its Sim scale (global, default 50 %, or its own override); models come
// from the catalog (Resources/SimModels/catalog.json) and load lazily, per file, the first time something needs them.

enum SimFrame {
    static func ground(_ p: SIMD3<Float>) -> V2 { V2(Double(p.x), Double(-p.z)) }
    static func world(_ g: V2, y: Float) -> SIMD3<Float> { SIMD3(Float(g.x), y, Float(-g.y)) }
    static func yaw(_ theta: Double) -> simd_quatf { simd_quatf(angle: Float(theta), axis: SIMD3(0, 1, 0)) }
    static func d3(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
    static func f3(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
}

/// Builds RealityKit meshes from SnailSightCore `BodyPart`s. Sizes are FULL extents (generateBox semantics); a
/// cylinder's radius is size.x / 2 — the scale contract pinned by SimScaleTests.
enum PartMesh {
    static func entity(_ p: BodyPart, material: RealityKit.Material) -> ModelEntity {
        let s = SimFrame.f3(p.size)
        switch p.shape {
        case .box(let r):
            return ModelEntity(mesh: .generateBox(size: s, cornerRadius: Float(r)), materials: [material])
        case .cylinderZ, .cylinderY:
            let along: Float = p.shape == .cylinderZ ? s.z : s.y
            let radius = s.x / 2
            let e: ModelEntity
            if #available(iOS 18.0, *) {
                e = ModelEntity(mesh: .generateCylinder(height: along, radius: radius), materials: [material])
                if p.shape == .cylinderZ { e.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)) }
            } else {
                e = ModelEntity(mesh: .generateBox(size: s, cornerRadius: min(radius, along / 2) * 0.9), materials: [material])
            }
            return e
        }
    }
}

/// Bundled USDZ templates, loaded on demand (9.8: 9.7 preloaded every clip of every species at Sim on; with 35
/// catalog items that would cost memory and heat for things nobody spawned). Callers get the template as soon as it
/// is loaded — immediately if it already is.
final class SimModelLibrary {
    private var templates: [String: Entity] = [:]
    private var waiting: [String: [(Entity) -> Void]] = [:]
    private var subs: [String: AnyCancellable] = [:]
    private(set) var failed = Set<String>()
    var onLoaded: ((String, Entity, Double) -> Void)?          // file, template, ms
    var onError: ((String, String) -> Void)?

    func loaded(_ file: String) -> Entity? { templates[file] }

    func request(_ file: String, _ done: @escaping (Entity) -> Void) {
        if let t = templates[file] { done(t); return }
        guard !failed.contains(file) else { return }
        waiting[file, default: []].append(done)
        guard subs[file] == nil else { return }
        let name = (file as NSString).deletingPathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz") else {
            failed.insert(file)
            waiting[file] = nil
            onError?(file, "not in the app bundle")
            return
        }
        let t0 = CACurrentMediaTime()
        subs[file] = Entity.loadAsync(contentsOf: url)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] done in
                guard let self else { return }
                if case .failure(let e) = done {
                    self.failed.insert(file)
                    self.waiting[file] = nil
                    self.subs[file] = nil
                    self.onError?(file, "\(e)")
                }
            }, receiveValue: { [weak self] ent in
                guard let self else { return }
                self.templates[file] = ent
                self.subs[file] = nil
                self.onLoaded?(file, ent, (CACurrentMediaTime() - t0) * 1000)
                let cbs = self.waiting.removeValue(forKey: file) ?? []
                for cb in cbs { cb(ent) }
            })
    }
}

/// 10.6: THE model + clip player of every animal / object drawing — the local sim's SimAnimal and the shared server
/// sim's ServerSimBody both use it, so the two paths cannot diverge again (10.5.213 drew server bodies as boxes).
/// One cloned USDZ per clip under `body`; `show(_:)` enables one and plays its animation; `lockPhase` keeps the
/// playing clip at the server's phase (ONE master world, API §5.9.10).
final class SimClipRig {
    let body: Entity
    private(set) var clips: [String: Entity] = [:]
    private var durations: [String: Double] = [:]
    private(set) var current: String?
    private var playback: AnimationPlaybackController?
    private var lastSync = 0.0
    var onAttached: (() -> Void)?

    init(body: Entity) { self.body = body }

    var isEmpty: Bool { clips.isEmpty }
    var available: Set<String> { Set(clips.keys) }

    /// Add one clip's model (a clone of the loaded template), hidden until shown.
    func attach(clip: String, template: Entity) {
        guard clips[clip] == nil else { return }
        let c = template.clone(recursive: true)
        c.isEnabled = false
        body.addChild(c)
        clips[clip] = c
        current = nil
        onAttached?()
    }

    /// Request every file of a catalog item from the shared library (logs: sim_model_load via the library,
    /// sim_model_fallback here when the item has no files).
    func load(_ item: SimCatalogItem, library: SimModelLibrary, log: (String, [String: LogValue]) -> Void) {
        let files = item.files ?? [:]
        if files.isEmpty { log("sim_model_fallback", ["kind": .string(item.key), "why": .string("no model files in the catalog")]) }
        for (clip, file) in files {
            library.request(file) { [weak self] t in self?.attach(clip: clip, template: t) }
        }
    }

    /// Show this clip (no-op when it already shows); the animation loops.
    func show(_ key: String, transition: TimeInterval = 0.25) {
        guard key != current, let e = clips[key] else { return }
        for (k, c) in clips { c.isEnabled = (k == key) }
        current = key
        playback?.stop()
        playback = nil
        if let a = e.availableAnimations.first {
            durations[key] = a.definition.duration
            playback = e.playAnimation(a.repeat(), transitionDuration: transition, startsPaused: false)
        }
        lastSync = 0
    }

    /// Keep the playing clip at the server's phase: at most once a second, only when off by > 80 ms.
    func lockPhase(clipT0: Double?, rate: Double?, serverNow: Double?, now: Double) {
        guard let key = current, let c = playback, let d = durations[key], d > 0.05, clipT0 != nil, serverNow != nil,
              now - lastSync >= 1.0 else { return }
        lastSync = now
        let want = SimSharedClip.time(clipT0: clipT0, rate: rate, serverNow: serverNow, duration: d)
        let cur = c.time.truncatingRemainder(dividingBy: d)
        let err = abs(want - cur)
        if min(err, d - err) > 0.08 { c.time = want }
    }

    func stop() { playback?.stop() }
}

/// RobosnailBob drawn from `RobotModel.parts` (the real Q6 Edge 2.0 base + the URDF sensor head; 0.82 × 0.62 ×
/// 0.61 m at 100 %). Drive wheels spin with each side's ground speed (spokes make it visible); a soft contact shadow
/// grounds it. 9.8: the drawing is built at 100 % under `body`, scaled by `scale`; the drive profile (footprint, step,
/// speeds) is the same profile scaled by the same factor.
final class SimRobot {
    let entity = Entity()
    private let body = Entity()
    var drive: DiffDrive
    var floorY: Float
    var support: SupportState
    var odometer = 0.0
    var agenda = RobotAgenda()
    var follower: PathFollower?
    private(set) var scale: Double
    var scaleOverride: Double?
    private let leftWheel = Entity(), rightWheel = Entity()
    private var spinL: Float = 0, spinR: Float = 0

    init(pose: DrivePose, floorY: Float, scale: Double) {
        self.scale = scale
        drive = DiffDrive(profile: RobotProfile.robosnailbob.scaled(scale), pose: pose)
        self.floorY = floorY
        support = SupportState(bottom: Double(floorY))
        entity.name = "sim.robosnailbob"
        entity.addChild(body)
        build()
        body.scale = SIMD3(repeating: Float(scale))
        render(dt: 0)
    }

    func setScale(_ s: Double) {
        guard abs(s - scale) > 1e-6 else { return }
        scale = s
        drive.profile = RobotProfile.robosnailbob.scaled(s)
        drive.bump()
        body.scale = SIMD3(repeating: Float(s))
    }

    static func material(_ m: PartMaterial) -> RealityKit.Material {
        switch m {
        case .body: return SimpleMaterial(color: UIColor(red: 0.77, green: 0.31, blue: 0.78, alpha: 1), roughness: 0.45,
                                          isMetallic: false)                    // Garage snailbob-twin colour
        case .dark: return SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), roughness: 0.8, isMetallic: false)
        case .light: return SimpleMaterial(color: UIColor(red: 0.88, green: 0.86, blue: 0.80, alpha: 1), roughness: 0.6,
                                           isMetallic: false)
        case .grey: return SimpleMaterial(color: UIColor(white: 0.55, alpha: 1), roughness: 0.5, isMetallic: true)
        }
    }

    private func build() {
        let p = RobotProfile.robosnailbob
        for part in RobotModel.parts(p) {
            let mesh = PartMesh.entity(part, material: Self.material(part.material))
            if part.name == "wheel.left" || part.name == "wheel.right" {
                let pivot = part.name == "wheel.left" ? leftWheel : rightWheel
                pivot.position = SimFrame.f3(part.center)
                body.addChild(pivot)
                pivot.addChild(mesh)
                // three spokes on the outer face so the spin is visible
                let outer = Float(part.center.z < 0 ? -1 : 1) * Float(part.size.z / 2 + 0.002)
                for k in 0..<3 {
                    let spoke = ModelEntity(mesh: .generateBox(size: SIMD3(Float(part.size.x) * 0.9, 0.04, 0.006)),
                                            materials: [Self.material(.light)])
                    spoke.position = SIMD3(0, 0, outer)
                    spoke.orientation = simd_quatf(angle: Float(k) * .pi / 3, axis: SIMD3(0, 0, 1))
                    pivot.addChild(spoke)
                }
            } else {
                mesh.position = SimFrame.f3(part.center) + mesh.position
                body.addChild(mesh)
            }
        }
        body.addChild(SimShadow.make(length: Float(p.length), width: Float(p.width)))
    }

    var position: V2 { drive.pose.position }
    /// Drawn size at the current scale (length, height, width).
    var size: SIMD3<Double> { RobotModel.bounds(RobotModel.parts()).extents * scale }
    var velocity: V2 { SimMath.unit(drive.pose.theta) * drive.v }

    func render(dt: Double) {
        entity.position = SimFrame.world(drive.pose.position, y: floorY)
        entity.orientation = SimFrame.yaw(drive.pose.theta)
        let w = drive.wheelSpeeds, r = Float(drive.profile.wheelRadius)
        // rolling forward (+x) turns the wheel clockwise seen from its +z side: negative angle about +z
        spinL -= Float(w.left * dt) / r
        spinR -= Float(w.right * dt) / r
        spinL = spinL.truncatingRemainder(dividingBy: 2 * .pi)
        spinR = spinR.truncatingRemainder(dividingBy: 2 * .pi)
        leftWheel.orientation = simd_quatf(angle: spinL, axis: SIMD3(0, 0, 1))
        rightWheel.orientation = simd_quatf(angle: spinR, axis: SIMD3(0, 0, 1))
    }
}

/// Soft dark footprint under a body so it reads as standing ON the floor (without one, AR objects look like they
/// float nearer the camera and bigger than they are).
enum SimShadow {
    static func make(length: Float, width: Float) -> ModelEntity {
        var m = UnlitMaterial(color: .black)
        m.blending = .transparent(opacity: 0.32)
        let e = ModelEntity(mesh: .generatePlane(width: length + 0.06, depth: width + 0.06,
                                                 cornerRadius: min(length, width) * 0.35), materials: [m])
        e.position.y = 0.003
        e.name = "shadow"
        return e
    }
}

/// One animal: brain (pure, SnailSightCore) + a body with one cloned USDZ per clip (one animation per file, as
/// built by tools/ilidar_build/build_sim_assets.py); only the clip for the current gait is enabled and playing.
/// 9.8 (owner on 9.7.75: after relaunch + relocalize the rabbit / deer showed only their contact shadow): 9.7 enabled a
/// clip only from render(), which ran only while the sim ticked — restored during iOS "serious" heat the sim never
/// ticked, so the clips that loaded afterwards stayed disabled. Now attaching a clip shows it at once, whatever the sim
/// is doing, and the controller renders every frame even while paused.
final class SimAnimal {
    let id: Int
    let item: SimCatalogItem
    let entity = ModelEntity()          // 9.9: HasPhysics (kinematic / knocked rigid body)
    private let body = Entity()
    var brain: AnimalBrain
    var floorY: Float
    var support: SupportState
    private(set) var scale: Double
    var scaleOverride: Double?
    private lazy var rig = SimClipRig(body: body)
    private var shownHeading: Double
    // 9.9 physical body (owner on 9.8.91: "I don't see good collision detection for things like if an animal is
    // kicked"): kinematic while the brain drives it, dynamic while knocked (SnailSightCore Knock / Impact).
    var knock = KnockState()
    var lockRotation = true
    var lastSafeY: Float
    var lastHitAt = 0.0
    var hitFrom: V2?
    private var recoverFrom = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private var recoverFromPos = SIMD3<Float>.zero
    private(set) var recoverTo = SIMD3<Float>.zero
    private(set) var recoverHeading = 0.0
    static let agentGroup = CollisionGroup(rawValue: 1 << 21)
    static let knockedGroup = CollisionGroup(rawValue: 1 << 22)

    init(id: Int, item: SimCatalogItem, brain: AnimalBrain, floorY: Float, scale: Double) {
        self.id = id
        self.item = item
        self.brain = brain
        self.floorY = floorY
        self.scale = scale
        support = SupportState(bottom: Double(floorY))
        lastSafeY = floorY
        shownHeading = brain.state.heading
        entity.name = "sim.\(item.key).\(id)"
        entity.addChild(body)
        let s = item.size
        body.addChild(SimShadow.make(length: Float(s.x) * 0.8, width: Float(s.z) * 1.2))
        body.scale = SIMD3(repeating: Float(scale))
        applyPhysics()
    }

    var isKnocked: Bool { knock.active }

    /// Collision shape (capsule / box per species size × scale, SnailSightCore.AnimalShape), feet at y = 0.
    private func shapeResource() -> ShapeResource {
        switch AnimalShape.choose(size: size) {
        case .capsule(let r, let h):
            return ShapeResource.generateCapsule(height: Float(h), radius: Float(r))
                .offsetBy(translation: SIMD3(0, Float(h / 2), 0))
        case .box(let b):
            return ShapeResource.generateBox(size: SimFrame.f3(b)).offsetBy(translation: SIMD3(0, Float(b.y / 2), 0))
        }
    }

    /// Kinematic agent body (only knocked bodies collide with it) or, while airborne, a dynamic rigid body that hits
    /// the scene mesh, objects, other animals and other knocked animals.
    func applyPhysics() {
        let airborne = knock.phase == .airborne
        let sh = shapeResource()
        entity.collision = CollisionComponent(
            shapes: [sh], mode: .default,
            filter: airborne ? CollisionFilter(group: Self.knockedGroup, mask: .all)
                             : CollisionFilter(group: Self.agentGroup, mask: Self.knockedGroup))
        let mat = PhysicsMaterialResource.generate(staticFriction: 0.7, dynamicFriction: 0.5, restitution: 0.15)
        var pb = PhysicsBodyComponent(massProperties: PhysicsMassProperties(shape: sh, mass: Float(max(0.01, massKg))),
                                      material: mat, mode: airborne ? .dynamic : .kinematic)
        pb.isContinuousCollisionDetectionEnabled = airborne
        if airborne && lockRotation { pb.isRotationLocked = (x: true, y: false, z: true) }      // slides upright
        entity.physicsBody = pb
        if entity.physicsMotion == nil { entity.physicsMotion = PhysicsMotionComponent() }
    }

    var physicsVelocity: SIMD3<Float> { entity.physicsMotion?.linearVelocity ?? .zero }
    var physicsSpin: SIMD3<Float> { entity.physicsMotion?.angularVelocity ?? .zero }

    /// World centre of the body (its origin is the model's feet; tumbling moves the centre, not the feet).
    var bodyCentre: SIMD3<Float> { entity.convert(position: SIMD3(0, Float(size.y / 2), 0), to: nil) }

    /// Knocked (controller already ran Knock.begin): dynamic now, with this velocity / spin.
    func launch(velocity v: SIMD3<Float>, spin w: SIMD3<Float>) {
        applyPhysics()
        var m = PhysicsMotionComponent()
        m.linearVelocity = v
        m.angularVelocity = w
        entity.physicsMotion = m
    }

    /// At rest after a knock (phase = recovering): kinematic again, stand up over `recoverTime` onto `surfaceY`.
    func startRecovery(surfaceY: Float?) {
        recoverFrom = entity.orientation
        recoverFromPos = entity.position
        let fwd = entity.convert(direction: SIMD3<Float>(1, 0, 0), to: nil)
        recoverHeading = Knock.uprightHeading(forward: SimFrame.d3(fwd), fallback: brain.state.heading)
        let c = bodyCentre
        recoverTo = SIMD3(c.x, surfaceY ?? min(recoverFromPos.y, c.y), c.z)
        applyPhysics()
        entity.physicsMotion = PhysicsMotionComponent()
    }

    /// Stood up: the brain takes over where it is.
    func finishRecovery() {
        brain.place(at: SimFrame.ground(recoverTo), heading: recoverHeading)
        floorY = recoverTo.y
        support = SupportState(bottom: Double(floorY))
        lastSafeY = floorY
        render()
    }

    /// Picked up mid-knock (drag): upright, kinematic, brain-driven again at once.
    func cancelKnock() {
        guard knock.active else { return }
        let c = bodyCentre
        knock = KnockState()
        applyPhysics()
        entity.physicsMotion = PhysicsMotionComponent()
        brain.place(at: SimFrame.ground(c))
    }

    var species: String { item.key }
    var kind: SimKind { SimKind(key: item.key, role: .animal) }
    /// Drawn size at the current scale (length, height, width).
    var size: SIMD3<Double> { item.size * scale }
    var massKg: Double { item.massKg * scale * scale * scale }
    var velocity: V2 { SimMath.unit(brain.state.heading) * brain.state.speed }
    var hasModel: Bool { !rig.isEmpty }

    func setScale(_ s: Double) {
        guard abs(s - scale) > 1e-6 else { return }
        scale = s
        body.scale = SIMD3(repeating: Float(s))
        brain.setProfile(SpeciesProfile.from(item).scaled(s))
        applyPhysics()
    }

    func attach(clip: String, template: Entity) {
        rig.attach(clip: clip, template: template)
        showClip()                          // visible now, even if the sim is not ticking (the 9.7.75 bug)
    }

    func render() {
        switch knock.phase {
        case .airborne:                      // the rigid body moves it
            showClip()
            return
        case .recovering:                    // standing back up
            let f = Float(Knock.recoverFraction(knock))
            entity.position = recoverFromPos + (recoverTo - recoverFromPos) * f
            entity.orientation = simd_slerp(recoverFrom, SimFrame.yaw(recoverHeading), f)
            showClip()
            return
        case .none: break
        }
        let s = brain.state
        entity.position = SimFrame.world(s.pos, y: floorY)
        shownHeading = s.heading
        entity.orientation = SimFrame.yaw(shownHeading)
        showClip()
    }

    private func showClip() {
        guard !rig.isEmpty, let want = SimClips.pick(brain.state.gait, available: rig.available) ?? rig.available.sorted().first
        else { return }
        rig.show(want)
    }
}

/// 9.8 interactive object: a RealityKit dynamic rigid body (collision primitive from the catalog's measured size and
/// shape, mass / friction / bounciness from the catalog) that falls, rolls and settles on the LiDAR scene mesh, and is
/// pushed by the robot and animals (SimPush), grabbed and thrown by the user, and put to sleep when it rests.
final class SimObject {
    let id: Int
    let item: SimCatalogItem
    let entity = ModelEntity()
    private let body = Entity()
    private(set) var scale: Double
    var scaleOverride: Double?
    var asleep = false
    var held = false
    var restFor = 0.0
    var lastSafeY: Float
    private(set) var hasModel = false

    init(id: Int, item: SimCatalogItem, scale: Double, spawnY: Float) {
        self.id = id
        self.item = item
        self.scale = scale
        lastSafeY = spawnY
        entity.name = "sim.obj.\(item.key).\(id)"
        entity.addChild(body)
        body.scale = SIMD3(repeating: Float(scale))
        applyPhysics(mode: .dynamic)
        if #available(iOS 18.0, *) { entity.components.set(GroundingShadowComponent(castsShadow: true)) }
    }

    var kind: SimKind { SimKind(key: item.key, role: .object) }
    var size: SIMD3<Double> { item.size * scale }
    var massKg: Double { max(0.01, item.physicsOrDefault.massKg * scale * scale * scale) }

    func setScale(_ s: Double) {
        guard abs(s - scale) > 1e-6 else { return }
        scale = s
        body.scale = SIMD3(repeating: Float(s))
        applyPhysics(mode: held ? .kinematic : (asleep ? .static : .dynamic))
    }

    func attach(template: Entity) {
        guard !hasModel else { return }
        let c = template.clone(recursive: true)
        body.addChild(c)
        hasModel = true
    }

    /// Collision primitive in the body frame (model feet at y = 0, length along +x).
    private func shape() -> ShapeResource {
        let s = SimFrame.f3(size)
        let p = item.physicsOrDefault
        switch p.shape {
        case .sphere:
            let r = max(0.005, max(s.x, max(s.y, s.z)) / 2)
            return ShapeResource.generateSphere(radius: r).offsetBy(translation: SIMD3(0, s.y / 2, 0))
        case .cylinder:
            if #available(iOS 18.0, *) {
                let r = max(0.005, max(s.x, s.z) / 2)
                return ShapeResource.generateConvex(from: MeshResource.generateCylinder(height: max(0.01, s.y), radius: r))
                    .offsetBy(translation: SIMD3(0, s.y / 2, 0))
            }
            return ShapeResource.generateBox(size: s).offsetBy(translation: SIMD3(0, s.y / 2, 0))
        case .box, .convex:
            return ShapeResource.generateBox(size: SIMD3(max(0.01, s.x), max(0.01, s.y), max(0.01, s.z)))
                .offsetBy(translation: SIMD3(0, s.y / 2, 0))
        }
    }

    func applyPhysics(mode: PhysicsBodyMode) {
        let p = item.physicsOrDefault
        let sh = shape()
        entity.collision = CollisionComponent(shapes: [sh], mode: .default,
                                              filter: CollisionFilter(group: SimObject.group, mask: .all))
        let mat = PhysicsMaterialResource.generate(staticFriction: Float(p.friction),
                                                   dynamicFriction: Float(p.friction) * 0.8,
                                                   restitution: Float(p.restitution))
        var pb = PhysicsBodyComponent(massProperties: PhysicsMassProperties(shape: sh, mass: Float(massKg)),
                                      material: mat, mode: mode)
        pb.isContinuousCollisionDetectionEnabled = true      // small fast things over thin LiDAR surfaces
        entity.physicsBody = pb
        if entity.physicsMotion == nil { entity.physicsMotion = PhysicsMotionComponent() }
    }

    static let group = CollisionGroup(rawValue: 1 << 20)

    var velocity: SIMD3<Float> { entity.physicsMotion?.linearVelocity ?? .zero }
    var speed: Double { Double(simd_length(velocity)) }

    func setVelocity(_ v: SIMD3<Float>, angular: SIMD3<Float>? = nil) {
        var m = entity.physicsMotion ?? PhysicsMotionComponent()
        m.linearVelocity = v
        if let a = angular { m.angularVelocity = a }
        entity.physicsMotion = m
    }

    func setMode(_ mode: PhysicsBodyMode) {
        guard var pb = entity.physicsBody, pb.mode != mode else { return }
        pb.mode = mode
        entity.physicsBody = pb
    }

    /// World centre of the body (the origin is the model's feet).
    var center: SIMD3<Float> { entity.convert(position: SIMD3(0, Float(size.y) / 2, 0), to: nil) }
    var isUpright: Bool { entity.convert(direction: SIMD3<Float>(0, 1, 0), to: nil).y > 0.9 }

    /// Footprint for SimPush (a bounding circle; height band from how it lies).
    func pushBody() -> PushObject {
        let c = center, s = size
        let half = isUpright ? s.y / 2 : max(s.x, max(s.y, s.z)) * 0.35
        let r = isUpright ? 0.5 * max(s.x, s.z) : 0.5 * max(s.x, max(s.y, s.z))
        let v = velocity
        return PushObject(center: SimFrame.ground(c), radius: r, bottom: Double(c.y) - half, top: Double(c.y) + half,
                          velocity: V2(Double(v.x), Double(-v.z)), massKg: massKg)
    }
}

/// Selection highlight: a glowing (unlit) wireframe box around the body plus a camera-facing label.
final class SimHighlight {
    let entity = Entity()
    private let box = Entity()
    private let labelHolder = Entity()
    private var text = ""
    private var size = SIMD3<Float>(repeating: 0)

    init() {
        entity.name = "sim.highlight"
        entity.addChild(box)
        entity.addChild(labelHolder)
    }

    func setSize(_ s: SIMD3<Double>) {
        let f = SimFrame.f3(s) + SIMD3(repeating: 0.03)
        guard simd_length(f - size) > 0.002 else { return }
        size = f
        for c in Array(box.children) { c.removeFromParent() }
        let mat = UnlitMaterial(color: UIColor(red: 0.2, green: 0.95, blue: 1.0, alpha: 1))
        let t: Float = 0.006
        let h = f / 2
        for sy in [-1, 1] as [Float] { for sz in [-1, 1] as [Float] {           // edges along x
            let e = ModelEntity(mesh: .generateBox(size: SIMD3(f.x, t, t)), materials: [mat])
            e.position = SIMD3(0, sy * h.y, sz * h.z); box.addChild(e)
        } }
        for sx in [-1, 1] as [Float] { for sz in [-1, 1] as [Float] {           // edges along y
            let e = ModelEntity(mesh: .generateBox(size: SIMD3(t, f.y, t)), materials: [mat])
            e.position = SIMD3(sx * h.x, 0, sz * h.z); box.addChild(e)
        } }
        for sx in [-1, 1] as [Float] { for sy in [-1, 1] as [Float] {           // edges along z
            let e = ModelEntity(mesh: .generateBox(size: SIMD3(t, t, f.z)), materials: [mat])
            e.position = SIMD3(sx * h.x, sy * h.y, 0); box.addChild(e)
        } }
        labelHolder.position = SIMD3(0, h.y + 0.08, 0)
    }

    func setText(_ s: String) {
        guard s != text else { return }
        text = s
        for c in Array(labelHolder.children) { c.removeFromParent() }
        labelHolder.addChild(SimLabel.make(s))
    }

    /// Body centre + orientation; the label turns to face the camera and keeps a readable size.
    func place(center: SIMD3<Float>, orientation: simd_quatf, camera: SIMD3<Float>) {
        entity.position = center
        entity.orientation = orientation
        let p = labelHolder.position(relativeTo: nil)
        let d = camera - p
        let flat = SIMD3<Float>(d.x, 0, d.z)
        if simd_length(flat) > 1e-3 {
            let ang = atan2(flat.x, flat.z)
            labelHolder.setOrientation(simd_quatf(angle: ang, axis: SIMD3(0, 1, 0)), relativeTo: nil)
        }
        let s = max(0.6, min(3.0, simd_length(d)))
        labelHolder.setScale(SIMD3(repeating: s), relativeTo: nil)
    }
}

enum SimLabel {
    /// Text on a dark rounded plate, facing +z (billboarded by the caller). ~2.4 cm tall at scale 1.
    static func make(_ text: String, size: CGFloat = 0.022, color: UIColor = .white) -> Entity {
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.0005,
                                             font: .systemFont(ofSize: size, weight: .semibold),
                                             containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
        let t = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        let b = t.visualBounds(relativeTo: nil)
        t.position = SIMD3(-b.center.x, -b.center.y, 0.001)
        var plate = UnlitMaterial(color: .black)
        plate.blending = .transparent(opacity: 0.55)
        let bg = ModelEntity(mesh: .generatePlane(width: b.extents.x + Float(size) * 0.8,
                                                  height: b.extents.y + Float(size) * 0.5,
                                                  cornerRadius: Float(size) * 0.25), materials: [plate])
        let holder = Entity()
        holder.addChild(bg)
        holder.addChild(t)
        return holder
    }
}

/// On-screen 1 m scale reference (owner 9.3.65): a yellow 1.000 m bar with 10 cm ticks lying on the floor beside the
/// robot / the selected body (or where you pointed), so its size can be judged against a known length. It is NOT
/// affected by the Sim scale (ScaleReference.lengthM).
final class SimScaleRef {
    let entity = Entity()
    private let label = Entity()

    init() {
        entity.name = "sim.scale1m"
        let L = Float(ScaleReference.lengthM)
        let bar = ModelEntity(mesh: .generateBox(size: SIMD3(L, 0.004, 0.03)),
                              materials: [UnlitMaterial(color: .systemYellow)])
        bar.position = SIMD3(0, 0.002, 0)
        entity.addChild(bar)
        let black = UnlitMaterial(color: .black)
        for k in 0...10 {
            let major = k % 5 == 0
            let tick = ModelEntity(mesh: .generateBox(size: SIMD3(0.004, 0.006, major ? 0.05 : 0.032)), materials: [black])
            tick.position = SIMD3(Float(k) * Float(ScaleReference.tickM) - L / 2, 0.004, 0)
            entity.addChild(tick)
        }
        label.addChild(SimLabel.make("1 m", size: 0.03, color: .systemYellow))
        label.position = SIMD3(0, 0.06, 0)
        entity.addChild(label)
    }

    /// Lay it along `heading` on the floor at `center` (ground), at floor height `y`.
    func place(center: V2, heading: Double, y: Float, camera: SIMD3<Float>) {
        entity.position = SimFrame.world(center, y: y)
        entity.orientation = SimFrame.yaw(heading)
        let p = label.position(relativeTo: nil)
        let d = camera - p
        if simd_length(SIMD3(d.x, 0, d.z)) > 1e-3 {
            label.setOrientation(simd_quatf(angle: atan2(d.x, d.z), axis: SIMD3(0, 1, 0)), relativeTo: nil)
        }
    }
}
