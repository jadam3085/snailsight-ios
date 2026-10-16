import Foundation

// SnailSight 10.1 AR 1:1 mode (plan §7 P2 "apply-correction-to-anchor with smoothing (AC10)", §8.4 corrections).
// Everything drawn in the map frame (master mesh, rooms, labels, objects, terrain, other agents, server sim) hangs
// under ONE RealityKit entity whose transform is T_arkit_map. A new localizer answer / live correction never moves
// that entity at once: AlignBlender walks the SHOWN alignment toward the target, pivoting about the camera (so what
// you look at slides by at most a few cm per frame) and rate-limited (≤ 0.5 m/s, ≤ 20°/s). A relock to a different
// place (> 2 m or > 30°) snaps instead and says so (the app fades the content), because a 3 m slide looks worse.
// Pure maths (no simd), Linux-tested (ARMapTests).

/// map ← ARKit as 4 DoF (gravity is known on both sides): T_map_arkit = [Rz(yaw) | t] · Rx(+90°).
public struct Align4: Equatable, Codable {
    public var x: Double, y: Double, z: Double, yaw: Double

    public init(x: Double, y: Double, z: Double, yaw: Double) { self.x = x; self.y = y; self.z = z; self.yaw = yaw }

    /// Projects a (near-)gravity-aligned T_map_arkit onto 4 DoF.
    public init(_ T: Mat4) {
        x = T[0, 3]; y = T[1, 3]; z = T[2, 3]
        yaw = atan2(T[1, 0], T[0, 0])
    }

    /// T_map_arkit (row-major). Columns: ARKit +x → (c, s, 0), ARKit +y (up) → map +z, ARKit +z → (s, −c, 0).
    public var matrix: Mat4 {
        let c = cos(yaw), s = sin(yaw)
        return Mat4([c, 0, s, x,
                     s, 0, -c, y,
                     0, 1, 0, z,
                     0, 0, 0, 1])
    }

    /// T_arkit_map: the transform of the map-frame root entity in the ARKit world.
    public var inverseMatrix: Mat4 { matrix.inverse }

    /// An ARKit world point → map.
    public func toMap(_ p: [Double]) -> [Double] {
        let c = cos(yaw), s = sin(yaw)
        return [c * p[0] + s * p[2] + x, s * p[0] - c * p[2] + y, p[1] + z]
    }

    /// A map point → ARKit world.
    public func toArkit(_ q: [Double]) -> [Double] {
        let c = cos(yaw), s = sin(yaw)
        let dx = q[0] - x, dy = q[1] - y
        return [c * dx + s * dy, q[2] - z, s * dx - c * dy]
    }

    /// The alignment that puts ARKit point `pivot` at map point `m` with heading `yaw`.
    public static func pivoted(yaw: Double, pivot p: [Double], at m: [Double]) -> Align4 {
        let c = cos(yaw), s = sin(yaw)
        return Align4(x: m[0] - (c * p[0] + s * p[2]), y: m[1] - (s * p[0] - c * p[2]), z: m[2] - p[1], yaw: yaw)
    }

    public static func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }
}

/// Smoothly walks the shown alignment to the target (see the file header).
public struct AlignBlender: Equatable {
    public private(set) var shown: Align4?
    public private(set) var target: Align4?
    /// The last `step` snapped (first lock, or a jump above the snap limits): fade content in, don't slide.
    public private(set) var snapped = false
    public var tau = 0.5                      // s, exponential approach
    public var maxSpeed = 0.5                 // m/s at the pivot
    public var maxYawRate = 20 * Double.pi / 180
    public var snapMetres = 2.0
    public var snapRadians = 30 * Double.pi / 180
    static let doneMetres = 0.002
    static let doneRadians = 0.05 * Double.pi / 180

    public init() {}

    public mutating func setTarget(_ a: Align4?) { target = a; if a == nil { shown = nil } }
    public mutating func reset() { shown = nil; target = nil; snapped = false }

    /// How far the shown alignment is from the target at `pivot` (ARKit point): cm and degrees.
    public func remaining(pivot p: [Double]) -> (cm: Double, deg: Double) {
        guard let s = shown, let t = target else { return (0, 0) }
        let a = s.toMap(p), b = t.toMap(p)
        let d = ((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2])).squareRoot()
        return (d * 100, abs(Align4.wrap(t.yaw - s.yaw)) * 180 / .pi)
    }

    public var settled: Bool { shown == target }

    /// Advance by dt seconds with the camera (ARKit position) as the pivot. Returns true when `shown` changed.
    @discardableResult
    public mutating func step(dt: Double, pivot p: [Double]) -> Bool {
        snapped = false
        guard let t = target else { return false }
        guard let s = shown else { shown = t; snapped = true; return true }
        if s == t { return false }
        let ms = s.toMap(p), mt = t.toMap(p)
        var e = [mt[0] - ms[0], mt[1] - ms[1], mt[2] - ms[2]]
        var ey = Align4.wrap(t.yaw - s.yaw)
        let dist = (e[0] * e[0] + e[1] * e[1] + e[2] * e[2]).squareRoot()
        if dist > snapMetres || abs(ey) > snapRadians {
            shown = t; snapped = true
            return true
        }
        if dist <= Self.doneMetres && abs(ey) <= Self.doneRadians { shown = t; return true }
        let a = 1 - exp(-max(0, dt) / max(tau, 1e-3))
        e = e.map { $0 * a }
        ey *= a
        let stepLen = (e[0] * e[0] + e[1] * e[1] + e[2] * e[2]).squareRoot()
        let cap = maxSpeed * max(dt, 0)
        if stepLen > cap, stepLen > 0 { e = e.map { $0 * cap / stepLen } }
        let ycap = maxYawRate * max(dt, 0)
        ey = max(-ycap, min(ycap, ey))
        shown = Align4.pivoted(yaw: Align4.wrap(s.yaw + ey), pivot: p, at: [ms[0] + e[0], ms[1] + e[1], ms[2] + e[2]])
        return true
    }
}

/// What the AR 1:1 status line says and how strongly the map content is drawn.
public struct ARMapStatus: Equatable {
    public enum Tone: String, Equatable { case neutral, working, good, warn }
    public var tone: Tone
    public var title: String
    public var detail: String
    /// 0 = hidden (never draw the house at a guessed place), 1 = full.
    public var opacity: Double

    public init(tone: Tone, title: String, detail: String, opacity: Double) {
        self.tone = tone; self.title = title; self.detail = detail; self.opacity = opacity
    }

    public enum Lock: Equatable { case none, cached, server(method: String?) }

    /// - online: the map server reachable; lock: current map lock; tracking: ARKit "normal" | "relocalizing" | other
    ///   limited reason; remainingCm: correction still being blended in; ageS: seconds since the lock was last confirmed.
    public static func make(online: Bool, lock: Lock, version: Int?, tracking: String, remainingCm: Double,
                            searchingS: Double = 0, matches: Int = 0, ageS: Double = 0) -> ARMapStatus {
        let v = version.map { " v\($0)" } ?? ""
        switch lock {
        case .none:
            if !online {
                return ARMapStatus(tone: .warn, title: "HOUSE OVERLAY OFFLINE",
                                   detail: "Needs the map server to localize (home Wi-Fi or Tailscale)", opacity: 0)
            }
            var d = String(format: "Finding you in the house map · %.0f s", searchingS)
            d += matches > 0 ? " · \(matches) match\(matches == 1 ? "" : "es")" : " · look at walls and furniture"
            return ARMapStatus(tone: .working, title: "FINDING YOU", detail: d, opacity: 0)
        case .cached, .server:
            let cached = lock == .cached
            if tracking == "relocalizing" {
                return ARMapStatus(tone: .working, title: "RELOCALIZING",
                                   detail: "ARKit lost its place: overlay hidden until it is back", opacity: 0)
            }
            if tracking != "normal" {
                return ARMapStatus(tone: .warn, title: "TRACKING LIMITED",
                                   detail: "Overlay dimmed: it may drift until tracking recovers", opacity: 0.3)
            }
            if remainingCm >= 3 {
                return ARMapStatus(tone: .working, title: String(format: "CORRECTING %.0f cm", remainingCm),
                                   detail: "Easing onto the new house-map fix", opacity: cached ? 0.6 : 1)
            }
            if cached {
                return ARMapStatus(tone: .working, title: "1:1 · saved place\(v)",
                                   detail: "From the saved place; confirming with the map server", opacity: 0.6)
            }
            var method: String?
            if case .server(let m) = lock { method = m }
            let mesh = LocMethod.usesGeometry(method)
            var d = mesh ? "Aligned to the house mesh" : "Aligned to the house map"
            if ageS > 120 { d += String(format: " · last fix %.0f min ago", ageS / 60) }
            return ARMapStatus(tone: .good, title: "1:1\(mesh ? " · " + LocMethod.label(method) : "") · whole house\(v)",
                               detail: d, opacity: 1)
        }
    }
}
