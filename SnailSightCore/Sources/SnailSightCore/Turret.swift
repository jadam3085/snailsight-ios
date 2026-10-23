import Foundation

// SnailSight 12.7 turret + first-person view (owner 2026-10-22: "I want the right thumbstick and I want that to control
// turret orientation" · "give first person view with 3d world"). Server contract: API §5.9.10 "Turret" (snailCOP
// services/snailsight/sim/vehicle.py turret_step / turret_camera).
// - Catalog item `robot` (and its entity docs) carry `turret.spec` {origin_m, camera_m, yaw_min/max (null = continuous),
//   pitch_min, pitch_max, yaw_rate_max, pitch_rate_max}; snapshots carry `turret {yaw, pitch}` (rad, body-relative).
// - Command `{turret: {yaw_rate, pitch_rate}}` (fractions -1…1 of the max rates; yaw + = counter-clockwise = left,
//   pitch + = up), `{turret: {yaw?, pitch?}}` absolute rad, `{turret: {centre: true}}`. TTL deadman = the turret HOLDS.
// - FPV camera (map frame, z up): pivot = pose + Rz(yaw)·origin·scale; camera = pivot + Rz(yaw + t.yaw)·(camera −
//   origin)·scale, z = pose.z + camera.z·scale; look yaw = pose.yaw + t.yaw, look pitch = t.pitch, roll 0.
// - Viewer frame (RealityKit, y up, the 12.3 Map 3D viewer): (x, y, z)_viewer = (x_map, z_map, −y_map), i.e. x = ARKit x,
//   y_map = −z_ark.
// Pure, Linux-tested (TurretTests).

/// The pan-tilt head (catalog / entity doc `turret.spec`).
public struct TurretSpec: Equatable {
    public var kind: String
    public var originM: [Double]                 // the yaw pivot on the body (x fwd, y left, z up), m at scale 1
    public var cameraM: [Double]                 // the head camera at turret yaw 0
    public var yawMin: Double?, yawMax: Double?  // nil = continuous (slip ring)
    public var pitchMin: Double, pitchMax: Double
    public var yawRateMax: Double, pitchRateMax: Double

    public init(kind: String = "pan_tilt", originM: [Double], cameraM: [Double], yawMin: Double? = nil, yawMax: Double? = nil,
                pitchMin: Double, pitchMax: Double, yawRateMax: Double, pitchRateMax: Double) {
        self.kind = kind; self.originM = originM; self.cameraM = cameraM; self.yawMin = yawMin; self.yawMax = yawMax
        self.pitchMin = pitchMin; self.pitchMax = pitchMax; self.yawRateMax = yawRateMax; self.pitchRateMax = pitchRateMax
    }

    /// RobosnailBob (server catalog `robot`, API §5.9.10) — used until the entity doc's spec arrives.
    public static let robosnailbob = TurretSpec(originM: [0.15, 0, 0.50], cameraM: [0.20, 0, 0.62], pitchMin: -0.349,
                                                pitchMax: 0.785, yawRateMax: 1.5, pitchRateMax: 1.0)

    /// App-only "virtual head" for bodies without a turret (rc_car): the right stick pans the app's OWN view in FPV /
    /// Chase (nothing is sent to the server). Hood camera at 1/10 car size.
    public static let rcCarView = TurretSpec(kind: "view", originM: [0.10, 0, 0.14], cameraM: [0.14, 0, 0.20],
                                             pitchMin: -0.5, pitchMax: 0.6, yawRateMax: 1.5, pitchRateMax: 1.0)

    public var continuousYaw: Bool { yawMin == nil || yawMax == nil }

    public func clampPitch(_ p: Double) -> Double { SimMath.clamp(p, pitchMin, pitchMax) }
    public func clampYaw(_ y: Double) -> Double {
        if let lo = yawMin, let hi = yawMax { return SimMath.clamp(y, lo, hi) }
        return SimMath.wrap(y)
    }
}

extension TurretSpec: Decodable {
    enum K: String, CodingKey {
        case kind, originM = "origin_m", cameraM = "camera_m", yawMin = "yaw_min", yawMax = "yaw_max"
        case pitchMin = "pitch_min", pitchMax = "pitch_max", yawRateMax = "yaw_rate_max", pitchRateMax = "pitch_rate_max"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let r = TurretSpec.robosnailbob
        func dbl(_ k: K) -> Double? { let x: Double? = try? c.decodeIfPresent(Double.self, forKey: k); return x }
        func arr(_ k: K) -> [Double]? {
            let x: [Double]? = try? c.decodeIfPresent([Double].self, forKey: k)
            return x?.count == 3 ? x : nil
        }
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? r.kind
        originM = arr(.originM) ?? r.originM
        cameraM = arr(.cameraM) ?? originM
        yawMin = dbl(.yawMin); yawMax = dbl(.yawMax)
        pitchMin = dbl(.pitchMin) ?? r.pitchMin; pitchMax = dbl(.pitchMax) ?? r.pitchMax
        yawRateMax = dbl(.yawRateMax) ?? r.yawRateMax; pitchRateMax = dbl(.pitchRateMax) ?? r.pitchRateMax
    }
}

/// A body's turret state: snapshot `turret {yaw, pitch}`, entity doc `turret {yaw, pitch, spec}`.
public struct SimTurret: Equatable {
    public var yaw: Double
    public var pitch: Double
    public var spec: TurretSpec?
    public init(yaw: Double = 0, pitch: Double = 0, spec: TurretSpec? = nil) { self.yaw = yaw; self.pitch = pitch; self.spec = spec }
}

extension SimTurret: Decodable {
    enum K: String, CodingKey { case yaw, pitch, spec }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        yaw = (try? c.decodeIfPresent(Double.self, forKey: .yaw)) ?? 0
        pitch = (try? c.decodeIfPresent(Double.self, forKey: .pitch)) ?? 0
        spec = try? c.decodeIfPresent(TurretSpec.self, forKey: .spec)
    }
}

/// A camera pose in the map frame (z up): position, look yaw (about +z, CCW from +x), look pitch (+ = up), roll 0.
public struct FPVPose: Equatable {
    public var x: Double, y: Double, z: Double
    public var yaw: Double, pitch: Double
    public init(x: Double, y: Double, z: Double, yaw: Double, pitch: Double) {
        self.x = x; self.y = y; self.z = z; self.yaw = yaw; self.pitch = pitch
    }

    /// Unit look direction in the map frame.
    public var forward: [Double] { [cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch)] }
    public var position: [Double] { [x, y, z] }

    /// The RealityKit viewer frame (y up): eye and look direction ((x, y, z)_viewer = (x, z, −y)_map).
    public var viewerEye: [Double] { MapViewerFrame.toViewer([x, y, z]) }
    public var viewerForward: [Double] { MapViewerFrame.toViewer(forward) }
}

/// Map frame (z up, the server's) ↔ the RealityKit viewer frame (y up) of Map 3D / FPV: x = ARKit x, y_map = −z_ark.
public enum MapViewerFrame {
    public static func toViewer(_ m: [Double]) -> [Double] { [m[0], m.count > 2 ? m[2] : 0, -(m.count > 1 ? m[1] : 0)] }
    public static func toMap(_ v: [Double]) -> [Double] { [v[0], -v[2], v[1]] }
}

public enum TurretCamera {
    /// The turret camera pose — exactly `sim/vehicle.py turret_camera` (API §5.9.10). `z` = the body's floor height
    /// (snapshot pose z); the returned yaw is wrapped to (−π, π].
    public static func pose(x: Double, y: Double, z: Double, bodyYaw: Double, scale: Double, spec: TurretSpec,
                            turretYaw: Double, turretPitch: Double) -> FPVPose {
        let o = spec.originM.map { $0 * scale }
        let cm = (spec.cameraM.count == 3 ? spec.cameraM : spec.originM).map { $0 * scale }
        let c = cos(bodyYaw), s = sin(bodyYaw)
        let px = x + c * o[0] - s * o[1], py = y + s * o[0] + c * o[1]
        let yw = bodyYaw + turretYaw
        let c2 = cos(yw), s2 = sin(yw)
        let dx = cm[0] - o[0], dy = cm[1] - o[1]
        return FPVPose(x: px + c2 * dx - s2 * dy, y: py + s2 * dx + c2 * dy, z: z + cm[2], yaw: atan2(sin(yw), cos(yw)),
                       pitch: turretPitch)
    }

    /// The turret pivot (yaw axis) in the map frame (for drawing the head and the AR aim line).
    public static func pivot(x: Double, y: Double, z: Double, bodyYaw: Double, scale: Double, spec: TurretSpec) -> [Double] {
        let o = spec.originM.map { $0 * scale }
        let c = cos(bodyYaw), s = sin(bodyYaw)
        return [x + c * o[0] - s * o[1], y + s * o[0] + c * o[1], z + o[2]]
    }

    /// Chase (third person): behind and above the turret camera along its look yaw, looking at a point ahead of it.
    /// back = 0.4 + 1.6·scale m, up = 0.2 + 0.6·scale m (1.2 m / 0.5 m at the default 50 % scale), target 2 m ahead
    /// of the camera along the full look direction (so the chase view tilts with the turret pitch).
    public static func chase(_ cam: FPVPose, scale: Double) -> (eye: [Double], target: [Double]) {
        let s = scale.isFinite && scale > 0 ? scale : 1
        let back = 0.4 + 1.6 * s, up = 0.2 + 0.6 * s, ahead = 2.0
        let f = cam.forward
        let eye = [cam.x - cos(cam.yaw) * back, cam.y - sin(cam.yaw) * back, cam.z + up]
        let target = [cam.x + f[0] * ahead, cam.y + f[1] * ahead, cam.z + f[2] * ahead]
        return (eye, target)
    }

    /// The world aim ray (AR crosshair / heading line): from the camera along the look direction.
    public static func aimPoint(_ cam: FPVPose, distance: Double) -> [Double] {
        let f = cam.forward
        return [cam.x + f[0] * distance, cam.y + f[1] * distance, cam.z + f[2] * distance]
    }
}

/// Client-side turret track (the body's RemoteTrack idea for the head): the drawn yaw / pitch extrapolates from the
/// last two snapshots at the measured rate (≤ `maxExtrapolate`, ≤ the spec's max rates) and eases out the
/// snapshot-to-snapshot error (τ 0.12 s), so the head turns smoothly at 30–60 fps from a 10 Hz stream.
public struct TurretTrack: Equatable {
    public private(set) var yaw: Double
    public private(set) var pitch: Double
    public private(set) var recvAt: Double
    private var yawRate = 0.0, pitchRate = 0.0
    private var errYaw = 0.0, errPitch = 0.0
    public static let maxExtrapolate = 0.15
    public static let tau = 0.12

    public init(yaw: Double, pitch: Double, now: Double) { self.yaw = yaw; self.pitch = pitch; recvAt = now }

    /// The pose to draw at local time `now`.
    public func value(now: Double, spec: TurretSpec = .robosnailbob) -> (yaw: Double, pitch: Double) {
        let dt = max(0, min(now - recvAt, Self.maxExtrapolate))
        let k = exp(-max(0, now - recvAt) / Self.tau)
        let y = spec.clampYaw(yaw + yawRate * dt + errYaw * k)
        let p = spec.clampPitch(pitch + pitchRate * dt + errPitch * k)
        return (y, p)
    }

    public mutating func update(yaw ny: Double, pitch np: Double, now: Double, spec: TurretSpec = .robosnailbob) {
        let drawn = value(now: now, spec: spec)
        let dt = now - recvAt
        if dt > 0.03 && dt < 0.6 {
            yawRate = SimMath.clamp(SimMath.wrap(ny - yaw) / dt, -spec.yawRateMax, spec.yawRateMax)
            pitchRate = SimMath.clamp((np - pitch) / dt, -spec.pitchRateMax, spec.pitchRateMax)
        } else if dt >= 0.6 {
            yawRate = 0; pitchRate = 0
        }
        errYaw = SimMath.wrap(drawn.yaw - ny)
        errPitch = drawn.pitch - np
        if abs(errYaw) > 0.8 { errYaw = 0 }                    // a jump (recentre on a reconnect): no easing
        yaw = ny; pitch = np; recvAt = now
    }
}

/// App-side head for bodies without a server turret (rc_car FPV / Chase): the right stick pans this view (rate ×
/// the spec's max rates), double-tap recentres; it never goes to the server.
public struct ViewPan: Equatable {
    public private(set) var yaw = 0.0
    public private(set) var pitch = 0.0
    public init() {}
    public mutating func step(yawRate: Double, pitchRate: Double, dt: Double, spec: TurretSpec = .rcCarView) {
        let d = max(0, min(dt, 0.1))
        yaw = spec.clampYaw(yaw + SimMath.clamp(yawRate, -1, 1) * spec.yawRateMax * d)
        pitch = spec.clampPitch(pitch + SimMath.clamp(pitchRate, -1, 1) * spec.pitchRateMax * d)
    }
    public mutating func centre() { yaw = 0; pitch = 0 }
}

/// What a turret command says (the `turret` field of a WS / REST cmd).
public enum TurretCommand: Equatable {
    case rate(yaw: Double, pitch: Double)        // fractions −1…1 of the max rates (yaw + = left, pitch + = up)
    case aim(yaw: Double?, pitch: Double?)       // absolute body-relative rad
    case centre

    public var fields: [String: Any] {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        switch self {
        case .rate(let y, let p): return ["yaw_rate": r(SimMath.clamp(y, -1, 1)), "pitch_rate": r(SimMath.clamp(p, -1, 1))]
        case .aim(let y, let p):
            var o: [String: Any] = [:]
            if let y { o["yaw"] = r(y) }
            if let p { o["pitch"] = r(p) }
            return o
        case .centre: return ["centre": true]
        }
    }

    public var isZeroRate: Bool {
        if case .rate(let y, let p) = self { return abs(y) < TeleopFrameSender.deadband && abs(p) < TeleopFrameSender.deadband }
        return false
    }
}
