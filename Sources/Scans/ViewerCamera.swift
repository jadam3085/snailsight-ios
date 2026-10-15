// 9.6 Scans viewer: one camera shared by the mesh (RealityKit) and splat (Metal) views, so switching Mesh ↔ Splat
// keeps the viewpoint. Orbit (default) or Walk (first person at eye height, walk points as in the web viewer §8.7).
// Maths in SnailSightCore (OrbitCamera / WalkCamera / CameraMath), tested on CI.
import UIKit
import simd
import SnailSightCore

final class ViewerCamera: NSObject, UIGestureRecognizerDelegate {
    enum Mode: String { case orbit, walk }
    var mode: Mode = .orbit { didSet { changed() } }
    var orbit = OrbitCamera()
    var walk = WalkCamera(eye: SIMD3(0, 1.5, 0))
    let fovy: Float = 60 * .pi / 180
    /// Called on every camera change (main thread). Several views may listen.
    private var listeners: [UUID: () -> Void] = [:]
    /// Taps in view coordinates (single / double) for Measure and walk-to.
    var onTap: ((CGPoint, CGSize) -> Void)?
    var onDoubleTap: ((CGPoint, CGSize) -> Void)?
    /// 9.9 Fly: two-finger / pinch moves of the first-person eye go through this (walls, unless Ghost); nil = free.
    var walkCollider: ((SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>)?

    var eye: SIMD3<Float> { mode == .orbit ? orbit.eye : walk.eye }
    var forward: SIMD3<Float> { mode == .orbit ? orbit.forward : walk.forward }
    var target: SIMD3<Float> { mode == .orbit ? orbit.target : walk.eye + walk.forward }
    var viewMatrix: simd_float4x4 { mode == .orbit ? orbit.viewMatrix : walk.viewMatrix }

    @discardableResult
    func listen(_ f: @escaping () -> Void) -> UUID {
        let id = UUID()
        listeners[id] = f
        return id
    }

    func unlisten(_ id: UUID) { listeners[id] = nil }

    func changed() { for f in listeners.values { f() } }

    /// Frame a scan's bounds (viewer frame, Y-up) from a three-quarter view.
    func frame(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        orbit.yaw = 0.6
        orbit.pitch = 0.75
        orbit.frame(min: lo, max: hi, fovy: fovy)
        changed()
    }

    func jump(to w: WalkPoint) {
        walk = WalkCamera(eye: w.eye, yaw: w.yaw, pitch: w.pitch)
        if mode != .walk { mode = .walk } else { changed() }
    }

    // MARK: gestures

    func attach(to v: UIView) {
        let one = UIPanGestureRecognizer(target: self, action: #selector(pan1(_:)))
        one.maximumNumberOfTouches = 1
        let two = UIPanGestureRecognizer(target: self, action: #selector(pan2(_:)))
        two.minimumNumberOfTouches = 2
        two.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        tap.require(toFail: dbl)
        for g in [one, two, pinch, dbl, tap] as [UIGestureRecognizer] {
            g.delegate = self
            v.addGestureRecognizer(g)
        }
        v.isMultipleTouchEnabled = true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && o is UIPanGestureRecognizer) || (o is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
    }

    @objc private func pan1(_ g: UIPanGestureRecognizer) {
        guard let v = g.view else { return }
        let t = g.translation(in: v)
        g.setTranslation(.zero, in: v)
        let w = Float(max(v.bounds.width, 1)), h = Float(max(v.bounds.height, 1))
        switch mode {
        case .orbit: orbit.rotate(dx: Float(t.x) / w * .pi, dy: Float(t.y) / h * .pi / 2)
        case .walk: walk.look(dx: -Float(t.x) / w * 1.6, dy: Float(t.y) / h * 1.2)
        }
        changed()
    }

    @objc private func pan2(_ g: UIPanGestureRecognizer) {
        guard let v = g.view else { return }
        let t = g.translation(in: v)
        g.setTranslation(.zero, in: v)
        let h = Float(max(v.bounds.height, 1))
        switch mode {
        case .orbit: orbit.pan(dx: Float(t.x) / h, dy: Float(t.y) / h)
        case .walk: moveWalk(forwardM: Float(t.y) / h * 4, rightM: -Float(t.x) / h * 4)
        }
        changed()
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        let s = Float(g.scale)
        g.scale = 1
        switch mode {
        case .orbit: orbit.zoom(s)
        case .walk: moveWalk(forwardM: (s - 1) * 3, rightM: 0)
        }
        changed()
    }

    private func moveWalk(forwardM: Float, rightM: Float) {
        let from = walk.eye
        walk.move(forwardM: forwardM, rightM: rightM)
        if let c = walkCollider { walk.eye = c(from, walk.eye) }
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        guard let v = g.view else { return }
        onTap?(g.location(in: v), v.bounds.size)
    }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        guard let v = g.view else { return }
        onDoubleTap?(g.location(in: v), v.bounds.size)
    }

    /// World ray through a view point.
    func ray(_ p: CGPoint, _ size: CGSize) -> (origin: SIMD3<Float>, dir: SIMD3<Float>) {
        CameraMath.ray(screen: SIMD2(Float(p.x), Float(p.y)), size: SIMD2(Float(size.width), Float(size.height)),
                       eye: eye, forward: forward, fovy: fovy)
    }
}
