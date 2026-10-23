// SnailSight 10.5: one body of the shared server sim, drawn with the SAME bundled models + clips as the local sim
// (owner on 10.4.212: "the animals are not rendering properly" — server bodies were brown boxes at twice the size).
// ONE master world (API §5.9.10): the server says pose, heading, clip, clip start (server time), rate and action; this
// view only plays that clip at that phase (SimSharedClip) — no AnimalBrain runs for a server body. Every client
// (another phone, the robot, a headset later) computes the same clip time from the same server clock, so legs line up.
// Map frame (z up, heading about +z): `root` is placed / turned there; `upright` turns the y-up model content into it.
import RealityKit
import UIKit
import SnailSightCore

final class ServerSimBody {
    let id: String
    let visual: SimServerVisual
    let root = Entity()
    private let upright = Entity()
    private let body = Entity()
    let tag: Entity
    private lazy var rig = SimClipRig(body: body)            // the SAME model / clip player as the local SimAnimal
    private var robot: SimRobot?
    // 10.8 X-ray (API §5.9.11): while hidden behind a wall / on another storey the body's own (animated) model draws
    // with a see-through unlit material that ignores depth; a distance / storey badge floats above it.
    private(set) var height = 0.5
    private var originals: [ObjectIdentifier: [any Material]] = [:]
    private(set) var ghosted = false
    private var ghostedClip: String?
    private var ghostedParts = 0
    private(set) var badge: Entity?
    private(set) var badgeText: String?
    // 12.9: a model that is not on this phone yet (no cache, no server) shows a box of its size; the first clip that
    // attaches replaces it (and a pending live swap commits when the new body has something to show)
    private var placeholder: Entity?
    private var readyWaiters: [() -> Void] = []

    /// `label`: the tag drawn above it (shown while selected). `height`: its drawn height (m) for the tag.
    init(id: String, visual: SimServerVisual, snap s: SimEntitySnap, library: SimModelLibrary, catalog: SimCatalog,
         label: Entity, log: @escaping (String, [String: LogValue]) -> Void) {
        self.id = id
        self.visual = visual
        tag = label
        root.name = "serversim.\(id)"
        upright.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))     // model +y -> map +z
        root.addChild(upright)
        upright.addChild(body)
        var height = 0.5
        switch visual {
        case .animal(let key, let scale):
            body.scale = SIMD3(repeating: Float(scale))
            if let item = catalog.item(key) {
                let sz = item.size
                body.addChild(SimShadow.make(length: Float(sz.x) * 0.8, width: Float(sz.z) * 1.2))
                height = sz.y * scale
                addPlaceholder(sz)
                rig.load(item, library: library, log: log)
            } else {
                log("sim_model_fallback", ["kind": .string(key), "why": .string("not in the bundled catalog")])
            }
        case .object(let key, let scale):
            body.scale = SIMD3(repeating: Float(scale))
            if let item = catalog.item(key) {
                height = item.size.y * scale
                addPlaceholder(item.size)
                if let f = item.file(clip: "static") ?? item.files?.values.sorted().first {
                    library.request(f) { [weak self] t in self?.rig.attach(clip: "static", template: t) }
                } else {
                    log("sim_model_fallback", ["kind": .string(key), "why": .string("no model files in the catalog")])
                }
            }
        case .rcCar(let scale):
            // 12.5: the bundled Kenney toy car stretched to the RC car's 0.45 × 0.16 × 0.25 m at the body's scale
            let toy = catalog.item("toycar")
            let k = RCCar.modelScale(model: toy?.sizeM, scale: scale)
            body.scale = SIMD3<Float>(Float(k[0]), Float(k[1]), Float(k[2]))
            let ts = toy?.size ?? SIMD3(RCCar.toycarSizeM[0], RCCar.toycarSizeM[1], RCCar.toycarSizeM[2])
            body.addChild(SimShadow.make(length: Float(ts.x) * 0.9, width: Float(ts.z) * 1.1))
            addPlaceholder(SIMD3(ts.x, ts.y, ts.z))
            height = RCCar.sizeM[1] * scale
            let file = toy?.file(clip: "static") ?? RCCar.modelFile
            library.request(file) { [weak self] t in self?.rig.attach(clip: "static", template: t) }
        case .robot(let scale):
            let r = SimRobot(pose: DrivePose(x: 0, y: 0, theta: 0), floorY: 0, scale: scale)      // the real model
            robot = r
            upright.addChild(r.entity)
            height = r.size.y
        case .drone, .box:
            if visual == .box {
                log("sim_model_fallback", ["kind": .string(s.kind), "why": .string("kind not in the bundled catalog")])
            }
            for m in Self.boxes(s) { root.addChild(m) }
            height = s.dims.flatMap { $0.count == 3 ? $0[2] : nil } ?? (s.isDrone ? 0.1 : 0.5)
        }
        tag.position = SIMD3<Float>(0, 0, Float(height) + 0.12)
        tag.isEnabled = false
        root.addChild(tag)
        self.height = height
        rig.onAttached = { [weak self] in self?.modelArrived() }
    }

    /// Code-drawn bodies (RobosnailBob, drone, unknown-kind boxes) are ready at once; model bodies when a clip attached.
    var isReady: Bool {
        switch visual {
        case .robot, .drone, .box: return true
        default: return !rig.isEmpty
        }
    }

    /// Run `done` once there is something real to show (live swap: load the new model, then replace the old body).
    func whenReady(_ done: @escaping () -> Void) {
        if isReady { done() } else { readyWaiters.append(done) }
    }

    private func modelArrived() {
        placeholder?.removeFromParent()
        placeholder = nil
        let w = readyWaiters
        readyWaiters = []
        for f in w { f() }
    }

    /// A translucent box of the model's size (length, height, width at 100 %) under the scaled `body`.
    private func addPlaceholder(_ size: SIMD3<Double>) {
        guard placeholder == nil else { return }
        let m = SimpleMaterial(color: UIColor(red: 0.75, green: 0.7, blue: 0.6, alpha: 0.55), roughness: 0.7, isMetallic: false)
        let sz = SIMD3<Float>(Float(max(size.x, 0.05)), Float(max(size.y, 0.05)), Float(max(size.z, 0.05)))
        let e = ModelEntity(mesh: .generateBox(size: sz, cornerRadius: min(sz.x, sz.y, sz.z) * 0.2), materials: [m])
        e.position = SIMD3<Float>(0, sz.y / 2, 0)
        e.name = "placeholder"
        body.addChild(e)
        placeholder = e
    }

    // MARK: X-ray ghost + badge

    /// The ghost look: unlit cyan, 45 % opaque, drawn on top of walls / floors (no depth test, no depth write).
    static let ghostMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.35, green: 0.92, blue: 1.0, alpha: 1))
        m.blending = .transparent(opacity: 0.45)
        m.readsDepth = false
        m.writesDepth = false
        return m
    }()

    /// Ghost on / off. Re-applied when the clip model changed (each clip is its own model under `body`).
    func setGhost(_ on: Bool) {
        let parts = Self.modelCount(root)
        guard on != ghosted || (on && (rig.current != ghostedClip || parts != ghostedParts)) else { return }
        ghosted = on
        ghostedClip = rig.current
        ghostedParts = parts
        for c in root.children where c !== tag && c !== badge { apply(c, on) }
    }

    private func apply(_ e: Entity, _ on: Bool) {
        if var mc = e.components[ModelComponent.self] {
            let k = ObjectIdentifier(e)
            if on {
                if originals[k] == nil { originals[k] = mc.materials }
                mc.materials = Array(repeating: Self.ghostMaterial, count: max(1, mc.materials.count))
                e.components.set(mc)
            } else if let m = originals.removeValue(forKey: k) {
                mc.materials = m
                e.components.set(mc)
            }
        }
        for c in e.children { apply(c, on) }
    }

    private static func modelCount(_ e: Entity) -> Int {
        (e.components[ModelComponent.self] != nil ? 1 : 0) + e.children.reduce(0) { $0 + modelCount($1) }
    }

    /// The badge ("4.5 m", "↑ L2 · 6 m"); nil removes it. `make` builds a label entity (MapARLayer.makeLabel).
    func setBadge(_ text: String?, make: (String) -> Entity) {
        guard text != badgeText else { return }
        badgeText = text
        badge?.removeFromParent()
        badge = nil
        guard let text else { return }
        let b = make(text)
        Self.drawOnTop(b)
        b.position = SIMD3<Float>(0, 0, Float(height) + 0.3)
        root.addChild(b)
        badge = b
    }

    /// Every unlit material under `e` ignores depth (a label readable through walls).
    static func drawOnTop(_ e: Entity) {
        if var mc = e.components[ModelComponent.self] {
            mc.materials = mc.materials.map { (m: any Material) -> any Material in
                guard var u = m as? UnlitMaterial else { return m }
                u.readsDepth = false
                u.writesDepth = false
                return u
            }
            e.components.set(mc)
        }
        for c in e.children { drawOnTop(c) }
    }

    /// Place + animate at local time `now` (server time `serverNow`): the server's clip, at the server's phase.
    /// 12.7 `turret`: the interpolated head (body-relative yaw / pitch, rad) of a turreted body (RobosnailBob).
    func render(pose p: SimPose, snap s: SimEntitySnap, serverNow: Double?, now: Double,
                turret: (yaw: Double, pitch: Double)? = nil) {
        root.position = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        root.orientation = simd_quatf(angle: Float(p.theta), axis: SIMD3<Float>(0, 0, 1))
        if let r = robot, let t = turret { r.setTurret(yaw: t.yaw, pitch: t.pitch) }
        if let c = s.serverClip, !SimContent.locomotion.contains(c), !rig.available.contains(c) { rig.ensure(clip: c) }
        guard !rig.isEmpty, let key = SimSharedClip.key(s.serverClip, available: rig.available) else { return }
        rig.show(key, transition: 0.2)
        rig.lockPhase(clipT0: s.clipT0, rate: s.clipRate, serverNow: serverNow, now: now)
    }

    /// Which clip shows (nil = no model yet): for the log / tests.
    var shownClip: String? { rig.current }

    func remove() {
        rig.stop()
        root.removeFromParent()
    }

    /// The drawing for kinds the app has no model for (drone, unknown kinds): boxes in the map frame. 12.9: the drone's
    /// parts come from the map server (agents.drone, map frame) when it serves them.
    static func boxes(_ s: SimEntitySnap) -> [ModelEntity] {
        if s.isDrone, let served = SimContentStore.shared.droneParts { return served.compactMap(servedPart) }
        let parts: [(SIMD3<Float>, SIMD3<Float>, UIColor)]
        if s.isDrone {
            let c = UIColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)
            parts = [(SIMD3(0.18, 0.18, 0.06), SIMD3(0, 0, 0), c),
                     (SIMD3(0.5, 0.03, 0.02), SIMD3(0, 0, 0.02), c),
                     (SIMD3(0.03, 0.5, 0.02), SIMD3(0, 0, 0.02), c),
                     (SIMD3(0.06, 0.04, 0.03), SIMD3(0.1, 0, 0), UIColor.systemRed)]
        } else if let d = s.dims, d.count == 3 {
            let size = SIMD3<Float>(Float(max(d[0], 0.05)), Float(max(d[1], 0.05)), Float(max(d[2], 0.05)))
            parts = [(size, SIMD3<Float>(0, 0, size.z / 2), UIColor(red: 0.75, green: 0.7, blue: 0.6, alpha: 1))]
        } else {
            parts = [(SIMD3(0.3, 0.3, 0.3), SIMD3(0, 0, 0.15), UIColor(red: 0.75, green: 0.7, blue: 0.6, alpha: 1))]
        }
        return parts.map { size, off, colour in
            let m = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(size.x, size.y, size.z) * 0.2),
                                materials: [SimpleMaterial(color: colour, roughness: 0.6, isMetallic: false)])
            m.position = off
            return m
        }
    }

    /// One served part (map frame: x forward, y left, z up).
    private static func servedPart(_ p: SimPartSpec) -> ModelEntity? {
        guard p.center.count == 3, p.size.count == 3 else { return nil }
        let size = SIMD3<Float>(Float(p.size[0]), Float(p.size[1]), Float(p.size[2]))
        let colour: UIColor
        if let c = p.rgb { colour = UIColor(red: c.x, green: c.y, blue: c.z, alpha: 1) }
        else {
            switch p.material {
            case "dark": colour = UIColor(white: 0.12, alpha: 1)
            case "light": colour = UIColor(red: 0.88, green: 0.86, blue: 0.80, alpha: 1)
            case "grey": colour = UIColor(white: 0.55, alpha: 1)
            default: colour = UIColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)
            }
        }
        let mat = SimpleMaterial(color: colour, roughness: 0.6, isMetallic: false)
        let m: ModelEntity
        switch p.shape {
        case "cylinderZ":
            m = ModelEntity(mesh: .generateCylinder(height: size.z, radius: size.x / 2), materials: [mat])
            m.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        case "cylinderY":
            m = ModelEntity(mesh: .generateCylinder(height: size.y, radius: size.x / 2), materials: [mat])
        default:
            m = ModelEntity(mesh: .generateBox(size: size, cornerRadius: Float(p.corner ?? min(size.x, size.y, size.z) * 0.2)),
                            materials: [mat])
        }
        m.position = SIMD3<Float>(Float(p.center[0]), Float(p.center[1]), Float(p.center[2]))
        return m
    }
}
