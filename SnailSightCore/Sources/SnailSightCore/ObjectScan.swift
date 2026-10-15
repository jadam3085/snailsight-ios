import Foundation
import simd

// 9.3 object scan (docs/SNAILSIGHT-API.md §9; owner 2026-10-12: "a high resolution option for 3D scanning of a part
// like this", the robot base, without feeding the house floor-plan workflow). Pure parts: capture naming, the AR box
// (placement heuristic, edges, JSON), upload routing to /v1/objects, and the result line. The app uses them from
// Sources/ObjectScan/.


/// The AR bounding box for a LiDAR object scan, in ARKit world (gravity-aligned, Y up, metres). Its bottom sits on the
/// floor; X = width axis, Z = depth axis after `yawDeg` about +Y (right-handed, same as the server's `rot_y`).
public struct ObjectBox: Equatable, Codable {
    public var center: SIMD3<Float>            // box centre (y = floorY + height / 2)
    public var size: SIMD3<Float>              // (width, height, depth)
    public var yawDeg: Float
    public var floorY: Float

    public static let defaultSize = SIMD3<Float>(1.0, 0.8, 0.8)     // RoboSnailBob 0.84 × 0.61 × 0.62 + margin
    public static let minSide: Float = 0.1
    public static let maxSide: Float = 2.5

    public init(center: SIMD3<Float>, size: SIMD3<Float>, yawDeg: Float, floorY: Float) {
        self.center = center; self.size = size; self.yawDeg = yawDeg; self.floorY = floorY
    }

    /// Box from a raycast hit on the object. The box faces the camera (+Z toward it). A hit on a vertical face (the
    /// object's front) is pushed in by half the depth so the box surrounds the object, not just its front; a hit on a
    /// top surface is used as the centre.
    public static func place(hit: SIMD3<Float>, normal: SIMD3<Float>, camera: SIMD3<Float>, floorY: Float,
                             size: SIMD3<Float> = defaultSize) -> ObjectBox {
        var toCam = SIMD3<Float>(camera.x - hit.x, 0, camera.z - hit.z)
        let len = simd_length(toCam)
        toCam = len > 1e-4 ? toCam / len : SIMD3(0, 0, 1)
        let yaw = atan2(toCam.x, toCam.z) * 180 / .pi          // +Z of the box points at the camera
        var c = SIMD3<Float>(hit.x, floorY + size.y / 2, hit.z)
        let n = simd_length(normal) > 1e-4 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
        if abs(n.y) < 0.5 { c -= toCam * (size.z / 2) }
        return ObjectBox(center: c, size: size, yawDeg: yaw, floorY: floorY)
    }

    public func clamped() -> ObjectBox {
        var b = self
        b.size = size.clamped(lowerBound: SIMD3(repeating: Self.minSide), upperBound: SIMD3(repeating: Self.maxSide))
        b.center.y = floorY + b.size.y / 2
        return b
    }

    public var yawRad: Float { yawDeg * .pi / 180 }
    public var xAxis: SIMD3<Float> { SIMD3(cos(yawRad), 0, -sin(yawRad)) }
    public var zAxis: SIMD3<Float> { SIMD3(sin(yawRad), 0, cos(yawRad)) }

    /// Move the box in its own frame (dx along width, dz along depth), e.g. the nudge buttons.
    public func nudged(dx: Float, dz: Float) -> ObjectBox {
        var b = self
        b.center += xAxis * dx + zAxis * dz
        return b
    }

    /// 8 world corners, bottom ring first (−x−z, +x−z, +x+z, −x+z), then the top ring.
    public var corners: [SIMD3<Float>] {
        let hx = size.x / 2, hz = size.z / 2
        var out: [SIMD3<Float>] = []
        for y in [floorY, floorY + size.y] {
            for (sx, sz) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                out.append(SIMD3(center.x, y, center.z) + xAxis * (sx * hx) + zAxis * (sz * hz))
            }
        }
        return out
    }

    /// The 12 edges as corner-index pairs.
    public static let edges: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4),
                                             (0, 4), (1, 5), (2, 6), (3, 7)]

    /// World point inside the box (floor up to the top).
    public func contains(_ p: SIMD3<Float>) -> Bool {
        let d = p - SIMD3(center.x, floorY, center.z)
        let x = simd_dot(d, xAxis), z = simd_dot(d, zAxis)
        return abs(x) <= size.x / 2 && abs(z) <= size.z / 2 && d.y >= 0 && d.y <= size.y
    }

    /// capture.json `object_box` (what services/snailsight/object_build.py reads): size = [w, h, d].
    public var json: [String: Any] {
        ["center": [Double(center.x), Double(center.y), Double(center.z)],
         "size": [Double(size.x), Double(size.y), Double(size.z)],
         "yaw_deg": Double(yawDeg), "floor_y": Double(floorY), "frame": "arkit_world_gravity"]
    }

    /// "1.00 × 0.80 × 0.80 m" (w × d × h) for the HUD.
    public var label: String { String(format: "%.2f × %.2f × %.2f m", size.x, size.z, size.y) }
}

/// Object-profile keyframe spacing for the LiDAR mode: ×0.3 of the room rule (0.4 m / 15° / 1.5 s) = every 12 cm or
/// 4.5°, ≥ 0.45 s apart, i.e. ~60–100 full-res keyframes per orbit around a 1 m object (≈ +30 MB/min at q0.75).
public enum ObjectProfile {
    public static let keyframeScale = 0.3
}

/// 9.4 auto-fit (owner's first real scan, 2026-10-13: a mini PC on a table got the default 1.0 × 0.8 × 0.8 m box on the
/// FLOOR plane, so the table top and a cup were in it). From the LiDAR scene-mesh vertices around the crosshair hit:
///  1. support surface = the highest horizontal level BELOW the hit that surrounds the object (table / shelf / floor):
///     for each candidate level (1 cm bins with many 3 cm cells), the object blob = 3 cm cells holding points above
///     that level, flood-filled from the hit's cell; the level must show up around the blob on >= 4 of 8 sides;
///  2. box = the blob's minimum-area rectangle over yaw (3° steps), + 3 cm per side, height = top - level + 3 cm, its
///     bottom ON the support level (floorY).
/// nil when the mesh around the hit is too thin (the app then falls back to "Set surface" + the old placement).
public enum ObjectAutoFit {
    public static let cell: Float = 0.03
    public static let margin: Float = 0.03
    public static let searchRadius: Float = 0.9

    public struct Fit: Equatable {
        public var box: ObjectBox
        public var supportY: Float
        public var sides: Int            // of 8 around the blob where the support level was seen
        public var blobCells: Int
    }

    private struct Cell: Hashable { var x: Int; var z: Int }

    public static func fit(points: [SIMD3<Float>], hit: SIMD3<Float>, camera: SIMD3<Float>) -> Fit? {
        let near = points.filter { p in
            let dx = p.x - hit.x, dz = p.z - hit.z
            return dx * dx + dz * dz <= searchRadius * searchRadius && p.y <= hit.y + 1.0 && p.y >= hit.y - 1.6
        }
        guard near.count >= 50 else { return nil }
        func key(_ p: SIMD3<Float>) -> Cell { Cell(x: Int(floor((p.x - hit.x) / cell)), z: Int(floor((p.z - hit.z) / cell))) }
        // candidate levels: 1 cm bins below the hit with many distinct cells
        var bins: [Int: Set<Cell>] = [:]
        for p in near where p.y < hit.y - 0.015 {
            bins[Int(floor((p.y - hit.y) / 0.01)), default: []].insert(key(p))
        }
        let levels = bins.filter { $0.value.count >= 12 }.keys.sorted(by: >)        // highest first
        let hitCell = key(hit)
        for b in levels {
            let levelY = hit.y + (Float(b) + 0.5) * 0.01
            var support = Set<Cell>()
            var ys: [Float] = []
            var above = Set<Cell>()
            for p in near {
                let dy = p.y - levelY
                if abs(dy) <= 0.012 { support.insert(key(p)); ys.append(p.y) }
                else if dy > 0.015 && dy < 2.5 { above.insert(key(p)) }
            }
            // flood the object blob from the hit cell (8-connected, ≤ 1.2 m across)
            guard above.contains(hitCell) || above.contains(where: { abs($0.x - hitCell.x) <= 1 && abs($0.z - hitCell.z) <= 1 })
            else { continue }
            var start = hitCell
            if !above.contains(start), let n = above.first(where: { abs($0.x - hitCell.x) <= 1 && abs($0.z - hitCell.z) <= 1 }) { start = n }
            var blob: Set<Cell> = [start]
            var todo = [start]
            let maxR = Int(0.6 / cell)
            while let c = todo.popLast() {
                for dx in -1...1 { for dz in -1...1 where dx != 0 || dz != 0 {
                    let n = Cell(x: c.x + dx, z: c.z + dz)
                    if above.contains(n), !blob.contains(n), abs(n.x - start.x) <= maxR, abs(n.z - start.z) <= maxR {
                        blob.insert(n); todo.append(n)
                    }
                } }
            }
            // the support level AROUND the blob: the annulus 2–3 cells out (the first ring is skipped: the object's own
            // sides spill into it) must be mostly covered at this level, on >= 4 of 8 sides. A level cut through the
            // object's sides only touches the blob's edge, a table / floor fills the annulus.
            let cx = Float(blob.map(\.x).reduce(0, +)) / Float(blob.count)
            let cz = Float(blob.map(\.z).reduce(0, +)) / Float(blob.count)
            var ring1 = Set<Cell>(), ring3 = Set<Cell>()
            for c in blob { for dx in -3...3 { for dz in -3...3 {
                let n = Cell(x: c.x + dx, z: c.z + dz)
                if blob.contains(n) { continue }
                if abs(dx) <= 1 && abs(dz) <= 1 { ring1.insert(n) } else { ring3.insert(n) }
            } } }
            let annulus = ring3.subtracting(ring1)
            var sectors = Set<Int>()
            var covered = 0
            for s in annulus where support.contains(s) {
                covered += 1
                let a = atan2(Float(s.z) - cz, Float(s.x) - cx)
                sectors.insert(Int(floor((a + .pi) / (2 * .pi) * 8)) % 8)
            }
            guard !annulus.isEmpty, Float(covered) / Float(annulus.count) >= 0.35, sectors.count >= 4 else { continue }
            let supportY = ys.sorted()[ys.count / 2]
            // object points: in blob cells, above the level
            let obj = near.filter { blob.contains(key($0)) && $0.y > supportY + 0.015 && $0.y < supportY + 2.5 }
            guard obj.count >= 8, let top = obj.map(\.y).max() else { continue }
            // minimum-area rectangle over yaw
            var best: (area: Float, yaw: Float, c: SIMD2<Float>, s: SIMD2<Float>)?
            for step in 0..<30 {
                let yaw = Float(step) * 3 * .pi / 180
                let xa = SIMD2<Float>(cos(yaw), -sin(yaw)), za = SIMD2<Float>(sin(yaw), cos(yaw))
                var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
                for p in obj {
                    let q = SIMD2<Float>(p.x, p.z)
                    let u = SIMD2<Float>(simd_dot(q, xa), simd_dot(q, za))
                    lo = simd_min(lo, u); hi = simd_max(hi, u)
                }
                let s = hi - lo, area = s.x * s.y
                if best == nil || area < best!.area {
                    let m = (lo + hi) / 2
                    best = (area, yaw, xa * m.x + za * m.y, s)
                }
            }
            guard let r = best else { continue }
            // keep the yaw closest to facing the camera (the rectangle is symmetric every 90°)
            let toCam = SIMD2<Float>(camera.x - r.c.x, camera.z - r.c.y)
            let camYaw = atan2(toCam.x, toCam.y)
            var yaw = r.yaw, size = r.s
            for k in 1...3 {
                let y2 = r.yaw + Float(k) * .pi / 2
                let d2 = abs(remainder(y2 - camYaw, 2 * .pi)), d1 = abs(remainder(yaw - camYaw, 2 * .pi))
                if d2 < d1 { yaw = y2; size = k % 2 == 1 ? SIMD2(r.s.y, r.s.x) : r.s }
            }
            let h = top - supportY + margin
            let box = ObjectBox(center: SIMD3(r.c.x, supportY + h / 2, r.c.y),
                                size: SIMD3(size.x + 2 * margin, h, size.y + 2 * margin),
                                yawDeg: remainder(yaw * 180 / .pi, 360), floorY: supportY).clamped()
            return Fit(box: box, supportY: supportY, sides: sectors.count, blobCells: blob.count)
        }
        return nil
    }
}

/// Object scan name / robot tag defaults (owner 2026-10-13: the first scan defaulted to "RoboSnailBob" with the robot
/// tag on and was auto-sent to the robot page). The name starts empty and is required; the robot tag starts off.
public enum ObjectNameRule {
    public static let defaultName = ""
    public static let defaultRobotTag = false
    public static func clean(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
    public static func isValid(_ raw: String) -> Bool { !clean(raw).isEmpty }
}
