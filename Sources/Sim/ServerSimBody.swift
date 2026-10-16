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
    private var clips: [String: Entity] = [:]
    private var durations: [String: Double] = [:]
    private var current: String?
    private var playback: AnimationPlaybackController?
    private var lastSync = 0.0
    private var robot: SimRobot?

    /// `label`: the tag drawn above it (shown while selected). `height`: its drawn height (m) for the tag.
    init(id: String, visual: SimServerVisual, snap s: SimEntitySnap, library: SimModelLibrary, catalog: SimCatalog,
         label: Entity) {
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
                for (clip, file) in item.files ?? [:] {
                    library.request(file) { [weak self] t in self?.attach(clip: clip, template: t) }
                }
            }
        case .object(let key, let scale):
            body.scale = SIMD3(repeating: Float(scale))
            if let item = catalog.item(key) {
                height = item.size.y * scale
                if let f = item.file(clip: "static") ?? item.files?.values.sorted().first {
                    library.request(f) { [weak self] t in self?.attach(clip: "static", template: t) }
                }
            }
        case .robot(let scale):
            let r = SimRobot(pose: DrivePose(x: 0, y: 0, theta: 0), floorY: 0, scale: scale)      // the real model
            robot = r
            upright.addChild(r.entity)
            height = r.size.y
        case .drone, .box:
            for m in Self.boxes(s) { root.addChild(m) }
            height = s.dims.flatMap { $0.count == 3 ? $0[2] : nil } ?? (s.isDrone ? 0.1 : 0.5)
        }
        tag.position = SIMD3<Float>(0, 0, Float(height) + 0.12)
        tag.isEnabled = false
        root.addChild(tag)
    }

    private func attach(clip: String, template: Entity) {
        guard clips[clip] == nil else { return }
        let c = template.clone(recursive: true)
        c.isEnabled = false
        body.addChild(c)
        clips[clip] = c
        current = nil                                  // show / re-pick at once (even before the next frame)
    }

    /// Place + animate at local time `now` (server time `serverNow`): the server's clip, at the server's phase.
    func render(pose p: SimPose, snap s: SimEntitySnap, serverNow: Double?, now: Double) {
        root.position = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        root.orientation = simd_quatf(angle: Float(p.theta), axis: SIMD3<Float>(0, 0, 1))
        guard !clips.isEmpty, let key = SimSharedClip.key(s.serverClip, available: Set(clips.keys)) else { return }
        if key != current {
            for (k, e) in clips { e.isEnabled = (k == key) }
            current = key
            playback?.stop()
            playback = nil
            if let e = clips[key], let a = e.availableAnimations.first {
                durations[key] = a.definition.duration
                playback = e.playAnimation(a.repeat(), transitionDuration: 0.2, startsPaused: false)
            }
            lastSync = 0
        }
        // keep the phase locked to the server's (cheap: at most once a second, only when off by > 80 ms)
        guard let c = playback, let d = durations[key], d > 0.05, now - lastSync >= 1.0 else { return }
        lastSync = now
        let want = SimSharedClip.time(clipT0: s.clipT0, rate: s.clipRate, serverNow: serverNow, duration: d)
        guard s.clipT0 != nil, serverNow != nil else { return }
        let cur = c.time.truncatingRemainder(dividingBy: d)
        let err = abs(want - cur)
        if min(err, d - err) > 0.08 { c.time = want }
    }

    func remove() {
        playback?.stop()
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
