// SnailSight 12.2 "Mark camera": confirm where a camera / sensor really is, including ones on the roofline beyond the
// iPhone LiDAR range, by aiming the crosshair at it from two or more spots (rays in the MAP frame, triangulated by the
// server, API §5.7b), and "Camera check" while walking (which cameras see me, the walk-calibration window).
// Pure maths + wire parsing only (no simd / ARKit), so it is tested on Linux.
import Foundation

// MARK: lock quality of a mark

/// How much a mark's map-frame ray can be trusted (the server's default sigmas: strong 0.5° / 3 cm, good 1° / 8 cm,
/// weak 2.5° / 25 cm; `none` rays are rejected by the server and never sent).
public enum MarkLock: String, Codable, Equatable, CaseIterable {
    case strong, good, weak, none

    /// From the localizer's state: lock source ("server" | "place_cache" | "carried" | ""), method and its ± cm.
    public static func from(source: String, method: String?, errCm: Double?) -> MarkLock {
        guard let e = errCm, source != "" else { return .none }
        if source == "server" && LocMethod.usesGeometry(method) && e <= 3 { return .strong }
        if e <= 8 { return .good }
        if e <= 25 { return .weak }
        return .none
    }

    public var title: String {
        switch self {
        case .strong: return "strong lock"
        case .good: return "good lock"
        case .weak: return "weak lock"
        case .none: return "no lock"
        }
    }
}

// MARK: one mark

/// One "Mark": the phone camera centre and the crosshair direction, both in the MAP frame (Z-up metres).
public struct MarkRay: Equatable, Codable {
    public var origin: [Double]
    public var dir: [Double]                 // unit
    public var t: Double                     // unix s
    public var lock: MarkLock
    public var hit: [Double]?                // LiDAR raycast hit along the ray (map frame), if any within range

    public init(origin: [Double], dir: [Double], t: Double, lock: MarkLock, hit: [Double]? = nil) {
        self.origin = origin; self.dir = MarkMath.unit(dir); self.t = t; self.lock = lock; self.hit = hit
    }

    /// The triangulate request item (API §5.7b).
    public var wire: [String: Any] {
        var o: [String: Any] = ["origin": origin, "dir": dir, "t": t, "lock_quality": lock.rawValue]
        o["raycast_hit"] = hit.map { $0 as Any } ?? NSNull()
        return o
    }
}

public enum MarkMath {
    /// LiDAR depth is usable to ~5 m; a raycast hit closer than this is taken as the point itself (single tap).
    public static let lidarRangeM = 5.0
    public static let minSpreadDeg = 10.0

    public static func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
    public static func sub(_ a: [Double], _ b: [Double]) -> [Double] { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
    public static func add(_ a: [Double], _ b: [Double]) -> [Double] { [a[0] + b[0], a[1] + b[1], a[2] + b[2]] }
    public static func scale(_ a: [Double], _ s: Double) -> [Double] { [a[0] * s, a[1] * s, a[2] * s] }
    public static func norm(_ a: [Double]) -> Double { sqrt(dot(a, a)) }
    public static func unit(_ a: [Double]) -> [Double] {
        let n = norm(a)
        return n > 1e-12 ? scale(a, 1 / n) : [0, 0, 0]
    }

    /// Rotates a direction by T (no translation).
    public static func rotate(_ T: Mat4, _ v: [Double]) -> [Double] {
        (0..<3).map { r in T[r, 0] * v[0] + T[r, 1] * v[1] + T[r, 2] * v[2] }
    }

    /// A ray in the ARKit world (origin, direction) → the map frame with T_map_arkit.
    public static func mapRay(T_map_arkit T: Mat4, originArkit o: [Double], dirArkit d: [Double]) -> (origin: [Double], dir: [Double]) {
        (T.apply(o), unit(rotate(T, d)))
    }

    /// The crosshair ray from the ARKit camera pose: `camera` = ARFrame.camera.transform (camera → ARKit world,
    /// row-major Mat4), `dirCamera` = the crosshair direction in the camera frame (x right, y up, looks along −z;
    /// the screen centre ≈ (0, 0, −1)).
    public static func crosshairRay(T_map_arkit T: Mat4, camera C: Mat4, dirCamera: [Double] = [0, 0, -1])
        -> (origin: [Double], dir: [Double]) {
        mapRay(T_map_arkit: T, originArkit: C.translation, dirArkit: rotate(C, dirCamera))
    }

    /// The crosshair direction in the camera frame for a pixel of the captured image (intrinsics fx, fy, cx, cy;
    /// image y grows down): ((u − cx)/fx, −(v − cy)/fy, −1), unit.
    public static func pixelDirection(u: Double, v: Double, fx: Double, fy: Double, cx: Double, cy: Double) -> [Double] {
        unit([(u - cx) / fx, -(v - cy) / fy, -1])
    }

    /// Angle between two directions (deg).
    public static func angleDeg(_ a: [Double], _ b: [Double]) -> Double {
        let c = max(-1, min(1, dot(unit(a), unit(b))))
        return acos(c) * 180 / .pi
    }

    /// The widest pair of rays (deg) — what the triangulation's depth precision depends on.
    public static func maxSpreadDeg(_ rays: [MarkRay]) -> Double {
        var best = 0.0
        for i in rays.indices { for j in rays.indices where j > i { best = max(best, angleDeg(rays[i].dir, rays[j].dir)) } }
        return best
    }

    /// Least-squares point closest to all rays: Σ(I − d dᵀ) p = Σ(I − d dᵀ) o. nil when the rays are (near) parallel
    /// or the point is behind a ray. The local fallback when the server cannot triangulate.
    public static func closestPoint(_ rays: [MarkRay]) -> [Double]? {
        guard rays.count >= 2 else { return nil }
        var A = [[Double]](repeating: [0, 0, 0], count: 3), b = [0.0, 0, 0]
        for r in rays {
            let d = r.dir
            for i in 0..<3 {
                for j in 0..<3 {
                    let m = (i == j ? 1 : 0) - d[i] * d[j]
                    A[i][j] += m
                    b[i] += m * r.origin[j]
                }
            }
        }
        guard let p = solve3(A, b) else { return nil }
        for r in rays where dot(sub(p, r.origin), r.dir) <= 0 { return nil }
        return p
    }

    /// Distance from p to the ray's line.
    public static func lineDistance(_ p: [Double], _ r: MarkRay) -> Double {
        let v = sub(p, r.origin)
        return norm(sub(v, scale(r.dir, dot(v, r.dir))))
    }

    /// Cramer's rule for 3×3 (nil when singular).
    public static func solve3(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let D = det(A)
        let scaleA = A.flatMap { $0 }.map(abs).max() ?? 0
        guard scaleA > 0, abs(D) > 1e-9 * scaleA * scaleA * scaleA else { return nil }
        return (0..<3).map { k in
            var M = A
            for i in 0..<3 { M[i][k] = b[i] }
            return det(M) / D
        }
    }

    /// Default angular sigma of a mark (deg) per lock quality (same as the server).
    public static func sigmaDeg(_ l: MarkLock) -> Double {
        switch l { case .strong: return 0.5; case .good: return 1.0; case .weak: return 2.5; case .none: return 10 }
    }

    /// Local estimate: the point + a 1σ radius ≈ range · σ / sin(spread) (depth) combined with the line residuals.
    public static func localTriangulate(_ rays: [MarkRay]) -> TriangulateResult? {
        let used = rays.filter { $0.lock != .none }
        guard used.count >= 2, maxSpreadDeg(used) >= minSpreadDeg, let p = closestPoint(used) else { return nil }
        let range = used.map { norm(sub(p, $0.origin)) }.reduce(0, +) / Double(used.count)
        let sig = (used.map { sigmaDeg($0.lock) }.reduce(0, +) / Double(used.count)) * .pi / 180
        let spread = maxSpreadDeg(used) * .pi / 180
        let depth = range * sig / max(0.05, sin(spread)) / sqrt(Double(used.count - 1))
        let resid = sqrt(used.map { pow(lineDistance(p, $0), 2) }.reduce(0, +) / Double(used.count))
        let resDeg = used.map { atan2(lineDistance(p, $0), max(0.01, norm(sub(p, $0.origin)))) * 180 / .pi }.sorted()
        return TriangulateResult(ok: true, point: p, sigmaM: max(depth, resid), axes: nil,
                                 residualDegP50: resDeg[resDeg.count / 2], maxAngleDeg: maxSpreadDeg(used),
                                 used: used.count, why: nil, deltaM: nil, local: true)
    }
}

// MARK: guidance

/// What the user should do next while marking.
public struct MarkGuide: Equatable {
    public enum Phase: String, Equatable { case aim, moveSideways, ready }
    public var phase: Phase
    public var text: String
    public var spreadDeg: Double
    /// How far to step sideways (m) for 10° (rounded to 0.5 m, ≥ 1 m); nil when ready.
    public var stepM: Double?

    /// `me` = the phone now (map frame), to say how far to move from the last mark.
    public static func evaluate(_ rays: [MarkRay], me: [Double]? = nil, minDeg: Double = MarkMath.minSpreadDeg) -> MarkGuide {
        let used = rays.filter { $0.lock != .none }
        if used.isEmpty {
            return MarkGuide(phase: .aim, text: "Aim the crosshair at the camera and tap Mark", spreadDeg: 0, stepM: nil)
        }
        let spread = MarkMath.maxSpreadDeg(used)
        if used.count >= 2 && spread >= minDeg {
            return MarkGuide(phase: .ready, text: String(format: "Ready: %d marks, %.0f° apart. Tap Locate", used.count, spread),
                             spreadDeg: spread, stepM: nil)
        }
        // range to the target: the rays' closest point when they are not parallel, else a 6 m guess (roofline)
        var range = 6.0
        if used.count >= 2, let p = MarkMath.closestPoint(used) {
            range = min(40, max(1, MarkMath.norm(MarkMath.sub(p, used.last!.origin))))
        }
        let needed = range * tan(minDeg * .pi / 180)
        var moved = 0.0
        if let me, let last = used.last {
            let d = MarkMath.sub(me, last.origin)
            let along = MarkMath.dot(d, last.dir)
            moved = MarkMath.norm(MarkMath.sub(d, MarkMath.scale(last.dir, along)))     // sideways, across the ray
        }
        let step = max(1, (max(needed, 2) * 2).rounded(.up) / 2)
        let left = max(0, step - moved)
        let text: String
        if used.count == 1 {
            text = left > 0.25 ? String(format: "Step %.1f m sideways and mark again", left)
                               : "Good spot: aim at the camera and mark again"
        } else {
            text = String(format: "Only %.0f° apart: step %.1f m further sideways and mark again", spread, max(0.5, left))
        }
        return MarkGuide(phase: .moveSideways, text: text, spreadDeg: spread, stepM: step)
    }
}

// MARK: server answers (API §5.7b)

public struct TriangulateResult: Equatable {
    public var ok: Bool
    public var point: [Double]?
    public var sigmaM: Double?
    /// 1σ ellipse axes (m, descending) — the ring shows the two largest.
    public var axes: [Double]?
    public var residualDegP50: Double?
    public var maxAngleDeg: Double?
    public var used: Int
    public var why: String?
    public var deltaM: Double?               // how far it moves the entity
    public var local: Bool                   // computed on the phone (server unavailable)

    public init(ok: Bool, point: [Double]?, sigmaM: Double?, axes: [Double]?, residualDegP50: Double?, maxAngleDeg: Double?,
                used: Int, why: String?, deltaM: Double?, local: Bool) {
        self.ok = ok; self.point = point; self.sigmaM = sigmaM; self.axes = axes; self.residualDegP50 = residualDegP50
        self.maxAngleDeg = maxAngleDeg; self.used = used; self.why = why; self.deltaM = deltaM; self.local = local
    }

    public static func parse(_ d: Data) -> TriangulateResult? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        let pt = (o["point"] as? [NSNumber])?.map(\.doubleValue)
        let ell = o["ellipse"] as? [String: Any]
        let used: Int = (o["used"] as? [Any])?.count ?? (o["used"] as? NSNumber)?.intValue ?? 0
        return TriangulateResult(ok: (o["ok"] as? Bool) ?? false, point: (pt?.count ?? 0) >= 3 ? pt : nil,
                                 sigmaM: num("sigma_m"), axes: (ell?["axes_m"] as? [NSNumber])?.map(\.doubleValue),
                                 residualDegP50: num("residual_deg_p50"), maxAngleDeg: num("max_angle_deg"), used: used,
                                 why: o["why"] as? String, deltaM: num("delta_m"), local: false)
    }

    /// "± 12 cm · 3 rays · 24° apart".
    public var summary: String {
        var parts: [String] = []
        if let s = sigmaM { parts.append(s < 1 ? String(format: "± %.0f cm", s * 100) : String(format: "± %.1f m", s)) }
        parts.append("\(used) rays")
        if let a = maxAngleDeg { parts.append(String(format: "%.0f° apart", a)) }
        if let d = deltaM { parts.append(d < 1 ? String(format: "moves %.0f cm", d * 100) : String(format: "moves %.1f m", d)) }
        if local { parts.append("phone estimate") }
        return parts.joined(separator: " · ")
    }

    /// Ring radii (m) shown in AR: the two largest 1σ axes, else σ for both. Never below 2 cm (visible).
    public var ringRadii: (Double, Double) {
        if let a = axes, a.count >= 2 { return (max(0.02, a[0]), max(0.02, a[1])) }
        let s = max(0.02, sigmaM ?? 0.1)
        return (s, s)
    }
}

/// The request bodies.
public enum MarkWire {
    public static func triangulate(rays: [MarkRay], agentID: String, mapVersion: Int?) -> [String: Any] {
        var o: [String: Any] = ["rays": rays.filter { $0.lock != .none }.map(\.wire), "agent_id": agentID]
        if let v = mapVersion { o["map_version"] = v }
        return o
    }

    public static func accept(_ r: TriangulateResult, rays: Int, agentID: String, mapVersion: Int?) -> [String: Any]? {
        guard let p = r.point, let s = r.sigmaM else { return nil }
        var o: [String: Any] = ["point": p, "sigma_m": s, "rays_n": rays, "agent_id": agentID]
        if let v = mapVersion { o["map_version"] = v }
        return o
    }

    /// A NEW placement (§5.7a `PUT …/entities/{id}`), placed at the accepted point. `source` must be
    /// `frigate:<cam>` | `ring:<cam>` | `ha:<entity_id>` | `kinect`.
    public static func newPlacement(kind: String, name: String, source: String, point: [Double], sigmaM: Double, rays: Int,
                                    agentID: String, mapVersion: Int?, level: Int?, t: Double) -> [String: Any] {
        var rec: [String: Any] = ["source": source, "estimated": false,
                                  "est_from": String(format: "triangulated (%d rays, σ %.2f m)", rays, sigmaM),
                                  "position": ["source": "triangulated", "sigma_m": sigmaM, "rays_n": rays, "t": t,
                                               "agent_id": agentID] as [String: Any]]
        if let level { rec["level"] = level }
        var o: [String: Any] = ["kind": kind, "name": name, "agent_id": agentID, "record": rec,
                                "pose": ["x": point[0], "y": point[1], "z": point[2], "yaw": 0.0]]
        if let v = mapVersion { o["map_version"] = v }
        return o
    }

    /// Valid §5.7a source string?
    public static func validSource(_ s: String) -> Bool {
        if s == "kinect" { return true }
        for p in ["frigate:", "ring:", "ha:"] where s.hasPrefix(p) && s.count > p.count { return true }
        return false
    }

    /// A new placement id: slug of the name + a short hex time (the portal's `<id>-<hex time>` style).
    public static func newID(name: String, t: Double) -> String {
        let slug = name.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "_" }
        let s = String(slug).split(separator: "_").joined(separator: "_")
        return "\(s.isEmpty ? "camera" : s)-\(String(Int(t), radix: 16))"
    }
}

// MARK: Camera check (walk FOV tracking)

/// GET …/cameras/coverage?x=&y=&z= → which cameras see this point.
public struct CoverageAnswer: Equatable {
    public struct Cam: Equatable, Identifiable {
        public var id: String
        public var name: String?
        public var sees: Bool
        public var score: Double?
        public var rangeM: Double?
        public var calibrated: Bool
        public var title: String { name ?? id }
    }
    public var cameras: [Cam]

    public static func parse(_ d: Data) -> CoverageAnswer? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let list = o["cameras"] as? [[String: Any]] else { return nil }
        return CoverageAnswer(cameras: list.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            return Cam(id: id, name: c["name"] as? String, sees: (c["sees"] as? Bool) ?? false,
                       score: (c["score"] as? NSNumber)?.doubleValue, rangeM: (c["range_m"] as? NSNumber)?.doubleValue,
                       calibrated: (c["calibrated"] as? Bool) ?? false)
        })
    }

    public var seeing: [Cam] { cameras.filter(\.sees).sorted { ($0.score ?? 0) > ($1.score ?? 0) } }
}

/// GET …/cameras/calibration/walk/{wid}: the live "camera saw you" feed.
public struct WalkStatus: Equatable {
    public struct Hit: Equatable { public var cameraID: String; public var t: Double; public var matched: Bool }
    public struct Cam: Equatable { public var id: String; public var detections: Int; public var matches: Int; public var lastMatchT: Double? }
    public var status: String
    public var endT: Double?
    public var poses: Int
    public var cameras: [Cam]
    public var recent: [Hit]

    public static func parse(_ d: Data) -> WalkStatus? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let cams = ((o["cameras"] as? [[String: Any]]) ?? []).compactMap { c -> Cam? in
            guard let id = c["id"] as? String else { return nil }
            return Cam(id: id, detections: (c["detections_n"] as? NSNumber)?.intValue ?? 0,
                       matches: (c["matches_n"] as? NSNumber)?.intValue ?? 0,
                       lastMatchT: (c["last_match_t"] as? NSNumber)?.doubleValue)
        }
        let rec = ((o["recent"] as? [[String: Any]]) ?? []).compactMap { r -> Hit? in
            guard let id = r["camera_id"] as? String, let t = (r["t"] as? NSNumber)?.doubleValue else { return nil }
            return Hit(cameraID: id, t: t, matched: (r["matched"] as? Bool) ?? false)
        }
        return WalkStatus(status: (o["status"] as? String) ?? "?", endT: (o["end_t"] as? NSNumber)?.doubleValue,
                          poses: (o["poses_n"] as? NSNumber)?.intValue ?? 0, cameras: cams, recent: rec)
    }

    /// Cameras whose detection matched me within the last `window` s.
    public func sawMe(now: Double, window: Double = 6) -> Set<String> {
        Set(recent.filter { $0.matched && now - $0.t <= window }.map(\.cameraID))
    }
}

/// Pose batches for the walk window: 2 Hz samples, flushed every 5 s (or at 30 poses).
public struct WalkPoseBuffer {
    public struct Pose: Equatable { public var t: Double; public var p: [Double]; public var yaw: Double; public var lock: MarkLock }
    public private(set) var pending: [Pose] = []
    private var lastSample = -Double.infinity
    private var lastFlush: Double?
    public let hz: Double
    public let flushEvery: Double

    public init(hz: Double = 2, flushEvery: Double = 5) { self.hz = hz; self.flushEvery = flushEvery }

    /// Offer a pose (every AR frame is fine); returns true when it was kept.
    @discardableResult
    public mutating func offer(t: Double, p: [Double], yaw: Double, lock: MarkLock) -> Bool {
        guard lock != .none, t - lastSample >= 1 / hz - 1e-6 else { return false }
        lastSample = t
        if lastFlush == nil { lastFlush = t }
        pending.append(Pose(t: t, p: p, yaw: yaw, lock: lock))
        return true
    }

    public func due(now: Double) -> Bool {
        guard !pending.isEmpty else { return false }
        return pending.count >= 30 || now - (lastFlush ?? now) >= flushEvery
    }

    /// Take the batch (body `poses` items) and reset the flush clock. Put it back with `restore` if the send fails.
    public mutating func take(now: Double) -> [[String: Any]] {
        let out = pending.map { ["t": $0.t, "p": $0.p, "yaw": $0.yaw, "lock_quality": $0.lock.rawValue] as [String: Any] }
        pending.removeAll()
        lastFlush = now
        return out
    }

    public mutating func restore(_ batch: [Pose]) { pending = Array((batch + pending).suffix(600)) }

    public var snapshot: [Pose] { pending }
}

/// The local fallback for "which cameras see me": a frustum test from the placement's pose / yaw / pitch / FOV / far.
public enum CameraFrustum {
    public static func sees(camera c: [Double], yaw: Double, pitchDeg: Double, hfovDeg: Double, vfovDeg: Double, far: Double,
                            point p: [Double]) -> Bool {
        let d = MarkMath.sub(p, c)
        let r = MarkMath.norm(d)
        guard r > 0.05, r <= far else { return false }
        // camera axes: forward from yaw (about +z) and pitch (negative = down)
        let pitch = pitchDeg * .pi / 180
        let f = [cos(yaw) * cos(pitch), sin(yaw) * cos(pitch), sin(pitch)]
        let right = [sin(yaw), -cos(yaw), 0.0]
        let up = [-cos(yaw) * sin(pitch), -sin(yaw) * sin(pitch), cos(pitch)]
        let z = MarkMath.dot(d, f)
        guard z > 0 else { return false }
        let h = atan2(abs(MarkMath.dot(d, right)), z) * 180 / .pi
        let v = atan2(abs(MarkMath.dot(d, up)), z) * 180 / .pi
        return h <= hfovDeg / 2 && v <= vfovDeg / 2
    }
}
