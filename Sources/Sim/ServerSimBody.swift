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
                rig.load(item, library: library, log: log)
            } else {
                log("sim_model_fallback", ["kind": .string(key), "why": .string("not in the bundled catalog")])
            }
        case .object(let key, let scale):
            body.scale = SIMD3(repeating: Float(scale))
            if let item = catalog.item(key) {
                height = item.size.y * scale
                if let f = item.file(clip: "static") ?? item.files?.values.sorted().first {
                    library.request(f) { [weak self] t in self?.rig.attach(clip: "static", template: t) }
                } else {
                    log("sim_model_fallback", ["kind": .string(key), "why": .string("no model files in the catalog")])
                }
            }
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
    }

    /// Place + animate at local time `now` (server time `serverNow`): the server's clip, at the server's phase.
    func render(pose p: SimPose, snap s: SimEntitySnap, serverNow: Double?, now: Double) {
        root.position = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        root.orientation = simd_quatf(angle: Float(p.theta), axis: SIMD3<Float>(0, 0, 1))
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

    /// The drawing for kinds the app has no model for (drone, unknown kinds): boxes in the map frame.
    static func boxes(_ s: SimEntitySnap) -> [ModelEntity] {
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
}
