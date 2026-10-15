import Foundation
import simd

// 9.6 Scans viewer maths (pure, tested on the CI host): frames, orbit / walk cameras, walk points, picking rays,
// triangle ray casts for Measure, dollhouse fitting. Viewer frame = Y-up metres, the same as the server's
// `mesh.glb` / `mesh.usdz` (map (x, y, z) → (x, z, −y), docs/SNAILSIGHT-API.md §8).

public enum ScanFrames {
    /// Map frame (Z-up) point → viewer frame (Y-up).
    public static func mapToYUp(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, p.z, -p.y) }
    public static func yUpToMap(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, -p.z, p.y) }

    /// The same as a matrix (a rotation of −90° about X): applied to the splat, which arrives in the map frame.
    public static let mapToYUpMatrix = simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 0, -1, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 0, 1)))
}

public enum CameraMath {
    /// Right-handed view matrix (camera looks down −Z), as RealityKit / MetalSplatter expect.
    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_float4x4 {
        var f = target - eye
        if simd_length(f) < 1e-6 { f = SIMD3(0, 0, -1) }
        f = simd_normalize(f)
        var s = simd_cross(f, up)
        if simd_length(s) < 1e-6 { s = simd_cross(f, SIMD3(0, 0, 1)) }
        s = simd_normalize(s)
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// Right-handed perspective, Metal clip space (z 0…1) — Apple's sample-code form (MetalSplatter's sample app).
    public static func perspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)))
    }

    /// World ray through a screen point (points, origin top-left) for a camera at `eye` looking along `forward`
    /// with vertical field of view `fovy` (radians), up = world Y.
    public static func ray(screen p: SIMD2<Float>, size: SIMD2<Float>, eye: SIMD3<Float>, forward: SIMD3<Float>,
                           fovy: Float) -> (origin: SIMD3<Float>, dir: SIMD3<Float>) {
        let f = simd_normalize(forward)
        var r = simd_cross(f, SIMD3(0, 1, 0))
        if simd_length(r) < 1e-6 { r = SIMD3(1, 0, 0) }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        let ndcX = (p.x / max(size.x, 1)) * 2 - 1
        let ndcY = 1 - (p.y / max(size.y, 1)) * 2
        let th = tanf(fovy / 2), aspect = size.x / max(size.y, 1)
        let d = simd_normalize(f + r * (ndcX * th * aspect) + u * (ndcY * th))
        return (eye, d)
    }
}

/// Orbit / pan / zoom around a target (the default view of a scan).
public struct OrbitCamera: Equatable {
    public var target: SIMD3<Float>
    public var yaw: Float            // radians, 0 = looking along −Z
    public var pitch: Float          // radians, positive = looking down
    public var distance: Float
    public static let minPitch: Float = -0.2, maxPitch: Float = 1.45
    public static let minDistance: Float = 0.15, maxDistance: Float = 300

    public init(target: SIMD3<Float> = .zero, yaw: Float = 0.6, pitch: Float = 0.6, distance: Float = 5) {
        self.target = target; self.yaw = yaw; self.pitch = pitch; self.distance = distance
    }

    /// Unit vector from the target towards the eye.
    public var back: SIMD3<Float> {
        SIMD3(sinf(yaw) * cosf(pitch), sinf(pitch), cosf(yaw) * cosf(pitch))
    }
    public var eye: SIMD3<Float> { target + back * distance }
    public var forward: SIMD3<Float> { -back }
    public var viewMatrix: simd_float4x4 { CameraMath.lookAt(eye: eye, target: target) }

    public mutating func rotate(dx: Float, dy: Float) {
        yaw -= dx
        pitch = min(Self.maxPitch, max(Self.minPitch, pitch + dy))
    }

    /// Pan in the screen plane; `dx`,`dy` are fractions of the view height (so the scene follows the finger).
    public mutating func pan(dx: Float, dy: Float) {
        let f = forward
        var r = simd_cross(f, SIMD3(0, 1, 0))
        if simd_length(r) < 1e-6 { r = SIMD3(1, 0, 0) }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        target += (-r * dx + u * dy) * distance
    }

    public mutating func zoom(_ factor: Float) {
        guard factor > 0, factor.isFinite else { return }
        distance = min(Self.maxDistance, max(Self.minDistance, distance / factor))
    }

    /// Frame a bounding box: look at its centre from far enough that its bounding sphere fits the vertical FOV.
    public mutating func frame(min lo: SIMD3<Float>, max hi: SIMD3<Float>, fovy: Float) {
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 0.05)
        distance = min(Self.maxDistance, max(Self.minDistance, radius / sinf(fovy / 2) * 1.05))
    }
}

/// First-person "walk" camera: eye at walk height, yaw/pitch look, moves on the horizontal plane.
public struct WalkCamera: Equatable {
    public var eye: SIMD3<Float>
    public var yaw: Float            // radians, 0 = looking along −Z
    public var pitch: Float          // radians, positive = looking up
    public init(eye: SIMD3<Float>, yaw: Float = 0, pitch: Float = 0) { self.eye = eye; self.yaw = yaw; self.pitch = pitch }

    public var forward: SIMD3<Float> {
        SIMD3(-sinf(yaw) * cosf(pitch), sinf(pitch), -cosf(yaw) * cosf(pitch))
    }
    public var viewMatrix: simd_float4x4 { CameraMath.lookAt(eye: eye, target: eye + forward) }

    public mutating func look(dx: Float, dy: Float) {
        yaw -= dx
        pitch = min(1.2, max(-1.2, pitch + dy))
    }

    /// Move `forwardM` along the horizontal heading and `rightM` sideways (metres).
    public mutating func move(forwardM: Float, rightM: Float) {
        let h = SIMD3<Float>(-sinf(yaw), 0, -cosf(yaw))
        let r = SIMD3<Float>(cosf(yaw), 0, -sinf(yaw))
        eye += h * forwardM + r * rightM
    }

    /// Yaw of a horizontal direction (inverse of `forward` at pitch 0).
    public static func yaw(of dir: SIMD3<Float>) -> Float { atan2f(-dir.x, -dir.z) }
}

/// "Walk points" (as the web viewer, §8.7): the splat's training cameras, else poses every 0.75 m along the walk.
public struct WalkPoint: Equatable {
    public var eye: SIMD3<Float>     // viewer frame (Y-up)
    public var yaw: Float
    public var pitch: Float
    public init(eye: SIMD3<Float>, yaw: Float, pitch: Float = 0) { self.eye = eye; self.yaw = yaw; self.pitch = pitch }
}

public enum WalkPoints {
    /// views.json `{"frame": "...Z-up, OpenGL camera (x right, y up, -z forward)", "views":[{"c2w": 4×4 rows}]}` or
    /// paths.json `{"paths":[{"points":[[x,y,z]..]}]}` (map frame). Pitch is kept within ±25°, roll dropped (upright).
    public static func parse(_ data: Data, spacing: Float = 0.75, maxCount: Int = 2000) -> [WalkPoint] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var out: [WalkPoint] = []
        if let views = o["views"] as? [[String: Any]] {
            for v in views {
                guard let rows = v["c2w"] as? [[Double]], rows.count >= 3, rows.allSatisfy({ $0.count >= 4 }) else { continue }
                let pos = SIMD3<Float>(Float(rows[0][3]), Float(rows[1][3]), Float(rows[2][3]))
                let fwdMap = -SIMD3<Float>(Float(rows[0][2]), Float(rows[1][2]), Float(rows[2][2]))
                let f = ScanFrames.mapToYUp(fwdMap)
                guard simd_length(f) > 1e-6 else { continue }
                let fn = simd_normalize(f)
                let pitch = max(-0.44, min(0.44, asinf(max(-1, min(1, fn.y)))))
                out.append(WalkPoint(eye: ScanFrames.mapToYUp(pos), yaw: WalkCamera.yaw(of: SIMD3(fn.x, 0, fn.z)), pitch: pitch))
                if out.count >= maxCount { break }
            }
            return out
        }
        if let paths = o["paths"] as? [[String: Any]] {
            for p in paths {
                guard let pts = p["points"] as? [[Double]] else { continue }
                let ys = pts.compactMap { $0.count >= 3 ? ScanFrames.mapToYUp(SIMD3(Float($0[0]), Float($0[1]), Float($0[2]))) : nil }
                guard ys.count >= 2 else { continue }
                var last: SIMD3<Float>? = nil
                for i in 0..<ys.count {
                    if let l = last, simd_distance(l, ys[i]) < spacing { continue }
                    let j = min(i + 1, ys.count - 1), k = j == i ? max(i - 1, 0) : i
                    var d = ys[j] - ys[k]
                    d.y = 0
                    let yaw = simd_length(d) > 1e-4 ? WalkCamera.yaw(of: d) : (out.last?.yaw ?? 0)
                    out.append(WalkPoint(eye: ys[i], yaw: yaw))
                    last = ys[i]
                    if out.count >= maxCount { return out }
                }
            }
        }
        return out
    }

    public static func nearest(_ pts: [WalkPoint], to p: SIMD3<Float>) -> Int? {
        guard !pts.isEmpty else { return nil }
        var best = 0, bd = Float.infinity
        for (i, w) in pts.enumerated() {
            let d = simd_distance_squared(w.eye, p)
            if d < bd { bd = d; best = i }
        }
        return best
    }
}

/// Triangle soup + uniform grid for ray casts (Measure, tap-to-walk). Positions in the viewer frame.
public struct TriangleIndex: Sendable {
    public let positions: [SIMD3<Float>]
    public let indices: [UInt32]
    public let lo: SIMD3<Float>
    public let cell: Float
    public let dims: SIMD3<Int32>
    let cellStart: [Int32]              // CSR: triangles of cell c = tris[cellStart[c]..<cellStart[c+1]]
    let cellTris: [Int32]

    public var triangleCount: Int { indices.count / 3 }

    /// `cell` = grid size in metres (auto: ~bounds / 64 per axis, ≥ 5 cm); triangles go into every cell their box touches.
    public init(positions: [SIMD3<Float>], indices: [UInt32], cell: Float? = nil) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if positions.isEmpty { lo = .zero; hi = .zero }
        let ext = hi - lo
        let c = cell ?? max(0.05, max(ext.x, max(ext.y, ext.z)) / 64)
        let lo0 = lo - SIMD3<Float>(repeating: c * 0.01)
        let d = SIMD3<Int32>(Int32(ext.x / c) + 1, Int32(ext.y / c) + 1, Int32(ext.z / c) + 1)
        let dmax = d &- 1
        let ncell = Int(d.x) * Int(d.y) * Int(d.z)
        let ntri = indices.count / 3
        func cellRange(_ t: Int) -> (SIMD3<Int32>, SIMD3<Int32>) {
            let a = positions[Int(indices[t * 3])], b = positions[Int(indices[t * 3 + 1])], e = positions[Int(indices[t * 3 + 2])]
            let mn = simd_min(a, simd_min(b, e)), mx = simd_max(a, simd_max(b, e))
            let i0 = SIMD3<Int32>(Int32((mn.x - lo0.x) / c), Int32((mn.y - lo0.y) / c), Int32((mn.z - lo0.z) / c))
            let i1 = SIMD3<Int32>(Int32((mx.x - lo0.x) / c), Int32((mx.y - lo0.y) / c), Int32((mx.z - lo0.z) / c))
            return (i0.clamped(lowerBound: .zero, upperBound: dmax), i1.clamped(lowerBound: .zero, upperBound: dmax))
        }
        var counts = [Int32](repeating: 0, count: ncell + 1)
        for t in 0..<ntri {
            let (i0, i1) = cellRange(t)
            for z in i0.z...i1.z { for y in i0.y...i1.y { for x in i0.x...i1.x {
                counts[Int((z * d.y + y) * d.x + x) + 1] += 1
            } } }
        }
        for i in 0..<ncell { counts[i + 1] += counts[i] }
        var fill = counts
        var tris = [Int32](repeating: 0, count: Int(counts[ncell]))
        for t in 0..<ntri {
            let (i0, i1) = cellRange(t)
            for z in i0.z...i1.z { for y in i0.y...i1.y { for x in i0.x...i1.x {
                let ci = Int((z * d.y + y) * d.x + x)
                tris[Int(fill[ci])] = Int32(t)
                fill[ci] += 1
            } } }
        }
        self.positions = positions
        self.indices = indices
        self.lo = lo0
        self.cell = c
        self.dims = d
        self.cellStart = counts
        self.cellTris = tris
    }

    public struct Hit: Equatable {
        public var t: Float
        public var point: SIMD3<Float>
        public var normal: SIMD3<Float>
        public var triangle: Int
    }

    /// Möller–Trumbore, both faces.
    public static func intersect(origin o: SIMD3<Float>, dir d: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                 _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        if abs(det) < 1e-12 { return nil }
        let inv = 1 / det
        let s = o - a
        let u = simd_dot(s, p) * inv
        if u < 0 || u > 1 { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(d, q) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 1e-5 ? t : nil
    }

    /// Nearest hit along the ray (3D DDA through the grid), nil when nothing is hit within `maxT`.
    public func raycast(origin: SIMD3<Float>, dir: SIMD3<Float>, maxT: Float = 1000) -> Hit? {
        guard triangleCount > 0, simd_length(dir) > 0 else { return nil }
        let d = simd_normalize(dir)
        let hi = lo + SIMD3<Float>(Float(dims.x), Float(dims.y), Float(dims.z)) * cell
        // clip the ray to the grid box
        var t0: Float = 0, t1 = maxT
        for k in 0..<3 {
            if abs(d[k]) < 1e-12 {
                if origin[k] < lo[k] || origin[k] > hi[k] { return nil }
            } else {
                var ta = (lo[k] - origin[k]) / d[k], tb = (hi[k] - origin[k]) / d[k]
                if ta > tb { swap(&ta, &tb) }
                t0 = max(t0, ta); t1 = min(t1, tb)
                if t0 > t1 { return nil }
            }
        }
        let start = origin + d * (t0 + 1e-6)
        var idx = SIMD3<Int32>(Int32((start.x - lo.x) / cell), Int32((start.y - lo.y) / cell), Int32((start.z - lo.z) / cell))
        idx = idx.clamped(lowerBound: .zero, upperBound: dims &- 1)
        var step = SIMD3<Int32>(0, 0, 0), tMax = SIMD3<Float>(repeating: .infinity), tDelta = SIMD3<Float>(repeating: .infinity)
        for k in 0..<3 {
            if d[k] > 0 {
                step[k] = 1
                tMax[k] = (lo[k] + Float(idx[k] + 1) * cell - origin[k]) / d[k]
                tDelta[k] = cell / d[k]
            } else if d[k] < 0 {
                step[k] = -1
                tMax[k] = (lo[k] + Float(idx[k]) * cell - origin[k]) / d[k]
                tDelta[k] = -cell / d[k]
            }
        }
        var best: Hit? = nil
        var visited = Set<Int32>()
        while true {
            let ci = Int((idx.z * dims.y + idx.y) * dims.x + idx.x)
            for j in Int(cellStart[ci])..<Int(cellStart[ci + 1]) {
                let tri = cellTris[j]
                if visited.contains(tri) { continue }
                visited.insert(tri)
                let t = Int(tri)
                let a = positions[Int(indices[t * 3])], b = positions[Int(indices[t * 3 + 1])], c = positions[Int(indices[t * 3 + 2])]
                if let th = Self.intersect(origin: origin, dir: d, a, b, c), th <= maxT, th < (best?.t ?? .infinity) {
                    var n = simd_cross(b - a, c - a)
                    n = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
                    if simd_dot(n, d) > 0 { n = -n }
                    best = Hit(t: th, point: origin + d * th, normal: n, triangle: t)
                }
            }
            // the nearest hit is final once the ray has left the cell it lies in
            let tNext = min(tMax.x, min(tMax.y, tMax.z))
            if let b = best, b.t <= tNext { return b }
            if tNext > t1 { return best }
            let k = tMax.x <= tMax.y && tMax.x <= tMax.z ? 0 : (tMax.y <= tMax.z ? 1 : 2)
            idx[k] += step[k]
            if idx[k] < 0 || idx[k] >= dims[k] { return best }
            tMax[k] += tDelta[k]
        }
    }
}

/// AR dollhouse: a whole house becomes a table-top miniature; a small object stays 1:1.
public enum Dollhouse {
    /// Scale so the larger horizontal extent (x/z, Y-up) is `targetM` (default 0.6 m); things already smaller than
    /// `targetM` keep their real size (1.0).
    public static func fitScale(min lo: SIMD3<Float>, max hi: SIMD3<Float>, targetM: Float = 0.6) -> Float {
        let e = hi - lo
        let span = max(e.x, e.z)
        guard span > 1e-4 else { return 1 }
        return span <= targetM ? 1 : targetM / span
    }

    /// Offset that puts the model's footprint centre at the origin and its floor (min y, or `floorY`) on y = 0.
    public static func baseOffset(min lo: SIMD3<Float>, max hi: SIMD3<Float>, floorY: Float? = nil) -> SIMD3<Float> {
        SIMD3(-(lo.x + hi.x) / 2, -(floorY ?? lo.y), -(lo.z + hi.z) / 2)
    }

    /// "1 : 40" label for the dollhouse scale.
    public static func scaleLabel(_ s: Float) -> String {
        guard s > 0 else { return "" }
        if s >= 0.999 { return "1 : 1" }
        return "1 : \(Int((1 / s).rounded()))"
    }
}
