import Foundation

// SnailSight 10.8: server sim paths, storeys and X-ray (API §5.9.11, server 0.4.7). Pure, Linux-tested (SimXRayTests).
// - SimNav: the server planner's status per body (`nav`: a string in snapshots, an object in entity docs).
// - SimXRay: which bodies show as a see-through ghost (behind walls / on another storey) and the badge they carry.
// - SimPathPreview: the selected body's planned route, trimmed to what is still ahead, as a flat ribbon mesh.

/// The server planner's status of one body: walking | climbing | with_you | arrived | waiting | lost | no_path | stuck.
public struct SimNav: Equatable {
    public var status: String
    public var reason: String?
    public var targetLevel: Int?
    public var pathM: Double?
    public init(status: String, reason: String? = nil, targetLevel: Int? = nil, pathM: Double? = nil) {
        self.status = status; self.reason = reason; self.targetLevel = targetLevel; self.pathM = pathM
    }

    /// A snapshot carries only the status string; the entity doc the reason / target. The snapshot's status wins, the
    /// doc's details are kept only while they describe that same status.
    public static func merged(snapshot s: SimNav?, doc d: SimNav?) -> SimNav? {
        guard let s else { return d }
        guard let d, d.status == s.status else { return s }
        return SimNav(status: s.status, reason: s.reason ?? d.reason, targetLevel: s.targetLevel ?? d.targetLevel,
                      pathM: s.pathM ?? d.pathM)
    }

    /// Words for the selection line ("climbing the stairs", "no path: the stairs to level 2 have …").
    public var text: String {
        switch status {
        case "walking": return targetLevel.map { "walking to level \($0)" } ?? "walking"
        case "climbing": return "climbing the stairs"
        case "with_you": return "with you"
        case "arrived": return "arrived"
        case "waiting": return reason ?? "waiting for your position"
        case "lost": return reason ?? "lost your position"
        case "no_path", "stuck": return reason ?? status.replacingOccurrences(of: "_", with: " ")
        default: return reason ?? status
        }
    }

    /// A status the owner should read now (flash it once when it appears).
    public var isProblem: Bool { ["no_path", "stuck", "lost"].contains(status) }
}

extension SimNav: Decodable {
    enum K: String, CodingKey { case status, reason, targetLevel = "target_level", pathM = "path_m" }
    public init(from d: Decoder) throws {
        if let c = try? d.singleValueContainer(), let s = try? c.decode(String.self) {
            status = s; reason = nil; targetLevel = nil; pathM = nil
            return
        }
        let c = try d.container(keyedBy: K.self)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        targetLevel = try? c.decodeIfPresent(Int.self, forKey: .targetLevel)
        pathM = try? c.decodeIfPresent(Double.self, forKey: .pathM)
    }
}

public enum SimXRay {
    public static let defaultsKey = "sim.xray"
    /// A phone's map pose is its camera: the floor it stands on is about this far below.
    public static let eyeHeight = 1.35
    /// A body this far above / below the floor under the phone is on another storey.
    public static let storeyDz = 1.2

    /// Height of a body relative to the floor under the phone (m; + = above).
    public static func dz(bodyZ: Double, cameraZ: Double) -> Double { bodyZ - (cameraZ - eyeHeight) }

    public static func otherStorey(bodyZ: Double, cameraZ: Double) -> Bool {
        abs(dz(bodyZ: bodyZ, cameraZ: cameraZ)) > storeyDz
    }

    /// Ghost or not: X-ray on and the body hidden (a wall in between, or another storey).
    public static func ghost(enabled: Bool, occluded: Bool, bodyZ: Double, cameraZ: Double) -> Bool {
        enabled && (occluded || otherStorey(bodyZ: bodyZ, cameraZ: cameraZ))
    }

    /// The badge under a ghost: "4.5 m" behind a wall, "↑ L2 · 6.5 m" / "↓ L0 · 3 m" on another storey (distance
    /// rounded to 0.5 m: the text mesh is rebuilt only when it changes). nil = no badge.
    public static func badge(enabled: Bool, occluded: Bool, bodyZ: Double, bodyLevel: Int?, cameraZ: Double,
                             distance: Double) -> String? {
        guard enabled else { return nil }
        let other = otherStorey(bodyZ: bodyZ, cameraZ: cameraZ)
        guard other || occluded else { return nil }
        let r = (distance * 2).rounded() / 2
        let d = r < 10 ? String(format: r == r.rounded() ? "%.0f m" : "%.1f m", r) : String(format: "%.0f m", r)
        guard other else { return d }
        let up = dz(bodyZ: bodyZ, cameraZ: cameraZ) > 0
        let lv = bodyLevel.map { "L\($0)" } ?? (up ? "upstairs" : "downstairs")
        return "\(up ? "↑" : "↓") \(lv) · \(d)"
    }
}

public enum SimPathPreview {
    /// What is still ahead of a body on its path: its current position, then every later point. `path` points are
    /// [x, y, z(, level)]; nil when nothing (useful) is left.
    public static func remaining(_ path: [[Double]]?, from p: [Double]) -> [[Double]]? {
        guard let P = path?.filter({ $0.count >= 3 }), P.count >= 2, p.count >= 3 else { return nil }
        var best = 0, bd = Double.infinity, bt = 0.0
        for i in 0..<(P.count - 1) {
            let a = P[i], b = P[i + 1]
            let ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2]
            let l2 = ux * ux + uy * uy + uz * uz
            var t = l2 > 1e-12 ? ((p[0] - a[0]) * ux + (p[1] - a[1]) * uy + (p[2] - a[2]) * uz) / l2 : 0
            t = min(1, max(0, t))
            let qx = a[0] + ux * t - p[0], qy = a[1] + uy * t - p[1], qz = a[2] + uz * t - p[2]
            let d = qx * qx + qy * qy + qz * qz
            if d < bd { bd = d; best = i; bt = t }
        }
        if best == P.count - 2 && bt >= 0.999 { return nil }
        var out: [[Double]] = [[p[0], p[1], p[2]]]
        for i in (best + 1)..<P.count { out.append(Array(P[i].prefix(3))) }
        let total = zip(out.dropLast(), out.dropFirst()).reduce(0.0) { acc, ab in
            acc + hypot(ab.1[0] - ab.0[0], ab.1[1] - ab.0[1])
        }
        return total < 0.05 ? nil : out
    }

    /// Path length (m, 3D).
    public static func length(_ pts: [[Double]]) -> Double {
        zip(pts.dropLast(), pts.dropFirst()).reduce(0.0) { acc, ab in
            let dx = ab.1[0] - ab.0[0], dy = ab.1[1] - ab.0[1], dz = ab.1[2] - ab.0[2]
            return acc + (dx * dx + dy * dy + dz * dz).squareRoot()
        }
    }

    /// A flat ribbon along the points (map frame, z up), `width` wide, `lift` above them: one quad per segment
    /// (+ a square joint at each inner point). positions = xyz floats, indices = triangles (both faces drawn by the
    /// caller's material, the ribbon is seen from above and below on stairs).
    public static func ribbon(_ pts: [[Double]], width: Double = 0.04, lift: Double = 0.03) -> (positions: [Float], indices: [UInt32]) {
        var pos: [Float] = []
        var idx: [UInt32] = []
        let h = width / 2
        func quad(_ c: [(Double, Double, Double)]) {
            let base = UInt32(pos.count / 3)
            for v in c { pos += [Float(v.0), Float(v.1), Float(v.2 + lift)] }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3, base, base + 2, base + 1, base, base + 3, base + 2]
        }
        for (a, b) in zip(pts.dropLast(), pts.dropFirst()) where a.count >= 3 && b.count >= 3 {
            let dx = b[0] - a[0], dy = b[1] - a[1]
            let l = (dx * dx + dy * dy).squareRoot()
            guard l > 1e-6 else { continue }
            let nx = -dy / l * h, ny = dx / l * h
            quad([(a[0] + nx, a[1] + ny, a[2]), (b[0] + nx, b[1] + ny, b[2]), (b[0] - nx, b[1] - ny, b[2]),
                  (a[0] - nx, a[1] - ny, a[2])])
        }
        for p in pts.dropFirst().dropLast() where p.count >= 3 {
            quad([(p[0] - h, p[1] - h, p[2]), (p[0] + h, p[1] - h, p[2]), (p[0] + h, p[1] + h, p[2]), (p[0] - h, p[1] + h, p[2])])
        }
        return (pos, idx)
    }
}
