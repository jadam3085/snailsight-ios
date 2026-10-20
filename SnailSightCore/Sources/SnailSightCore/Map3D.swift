import Foundation

// SnailSight 12.3 Map ▸ 3D (owner 2026-10-20: "a button on map mode to be able to manipulate the map in 3d to see the
// entire 3d color map and float through it", fly mode like the PC portal). Pure maths, Linux-tested (Map3DTests):
//
//  - Map3DTiles: whole-site tile LOD for a free virtual camera. Unlike TileSelect (the AR near band, FAR_M = 25 m) the
//    whole site is always covered: the per-level roots are the floor of detail and nodes are refined greedily by
//    screen-space error (size / distance) while the refinement fits the memory budget (600 MB, the plan's Q7 total);
//    far tiles are evicted first when the loaded set is over budget. The level slicer hides storeys above the slice.
//  - Map3DFly: the Fly controller (stick → velocity in the camera frame, look clamp, ground clamp, walk / run / drone
//    presets, gyro look) in the viewer frame (Y up, metres; map (x, y, z) → (x, z, −y), yaw 0 = looking along −Z — the
//    same convention as the Scans viewer's WalkCamera / DroneMath, so the app drives the Scans Fly controller with it).
//  - Map3DGround: the floor under the camera (storey floors inside their plan bounds, else the estimated DEM).
//  - Map3DShapes: camera frustum corners, DEM terrain mesh. Map3DQuality: detail / budget adaptation from fps + memory.

/// A plain 3-vector (the package's simd files do not build on Linux CI).
public struct Map3DVec: Equatable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = Map3DVec(0, 0, 0)
    public static func + (a: Map3DVec, b: Map3DVec) -> Map3DVec { Map3DVec(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Map3DVec, b: Map3DVec) -> Map3DVec { Map3DVec(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Map3DVec, s: Double) -> Map3DVec { Map3DVec(a.x * s, a.y * s, a.z * s) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public func dot(_ b: Map3DVec) -> Double { x * b.x + y * b.y + z * b.z }

    /// Map frame (z up) → viewer frame (y up): (x, z, −y). The tiles' usdz are already in the viewer frame.
    public static func yUp(map p: [Double]) -> Map3DVec { Map3DVec(p[0], p.count > 2 ? p[2] : 0, -p[1]) }
    /// Viewer frame → map frame [x, y, z].
    public var map: [Double] { [x, -z, y] }
}

// MARK: - tiles

public enum Map3DTiles {
    /// Plan Q7: 600 MB of tiles on the phone.
    public static let BUDGET = 600 * (1 << 20)
    /// Refine a node while its distance is below size × k (k adapts to the frame rate, Map3DQuality).
    public static let REFINE_K = 1.5
    public static let MIN_DISTANCE = 0.5

    /// Camera → bounding box distance (plain 3D: in the free view a storey is not "in the way" as it is in AR).
    public static func distance(_ cam: [Double], _ n: TileNode) -> Double {
        var s = 0.0
        for (i, (c, h)) in [(n.box[0], n.box[3]), (n.box[1], n.box[7]), (n.box[2], n.box[11])].enumerated() {
            let d = max(0, abs(cam[i] - c) - h)
            s += d * d
        }
        return s.squareRoot()
    }

    /// Screen-space error proxy: bigger and nearer first.
    public static func priority(_ cam: [Double], _ n: TileNode) -> Double {
        Double(n.size) / max(distance(cam, n), MIN_DISTANCE)
    }

    /// Visible under the level slicer (nil = every storey; else storeys up to and including `maxLevel`).
    public static func visible(_ n: TileNode, maxLevel: Int?) -> Bool {
        guard let m = maxLevel else { return true }
        return n.level <= m
    }

    /// The tiles to draw for the whole site: a cover of every visible root (REPLACE: never an ancestor together with a
    /// descendant), refined near the camera while it fits `budget` (bytes, by the tiles' `mem` estimate).
    public static func select(_ roots: [TileNode], cam: [Double], budget: Int = BUDGET, k: Double = REFINE_K,
                              maxLevel: Int? = nil) -> [String: TileSelect.Want] {
        // the cover starts at the roots (a root without content opens at once: it is only a grouping node)
        var cover: [TileNode] = []
        func seed(_ n: TileNode) {
            guard visible(n, maxLevel: maxLevel) else { return }
            if n.uri != nil { cover.append(n) } else { n.children.forEach(seed) }
        }
        roots.forEach(seed)
        // the coarsest cover itself over budget: nearest roots first
        var used = 0
        var kept: [TileNode] = []
        for n in cover.sorted(by: { distance(cam, $0) != distance(cam, $1) ? distance(cam, $0) < distance(cam, $1) : $0.key < $1.key }) {
            if used + n.mem > budget { continue }
            used += n.mem
            kept.append(n)
        }
        var inCover = Set(kept.map(\.key))
        var nodes: [String: TileNode] = Dictionary(kept.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        // greedy refinement, highest screen-space error first
        func refinable(_ n: TileNode) -> Bool {
            !n.children.isEmpty && distance(cam, n) < Double(n.size) * k
        }
        var heap = kept.filter(refinable).map { (p: priority(cam, $0), n: $0) }
        while !heap.isEmpty {
            var bi = 0
            for i in 1..<heap.count where heap[i].p > heap[bi].p || (heap[i].p == heap[bi].p && heap[i].n.key < heap[bi].n.key) { bi = i }
            let n = heap.remove(at: bi).n
            guard inCover.contains(n.key) else { continue }
            var kids: [TileNode] = []
            func open(_ c: TileNode) {
                guard visible(c, maxLevel: maxLevel) else { return }
                if c.uri != nil { kids.append(c) } else { c.children.forEach(open) }
            }
            n.children.forEach(open)
            let delta = kids.reduce(0) { $0 + $1.mem } - n.mem
            guard used + delta <= budget else { continue }
            used += delta
            inCover.remove(n.key)
            nodes[n.key] = nil
            for c in kids {
                inCover.insert(c.key)
                nodes[c.key] = c
                if refinable(c) { heap.append((priority(cam, c), c)) }
            }
        }
        var out: [String: TileSelect.Want] = [:]
        for (k, n) in nodes {
            out[k] = TileSelect.Want(node: n, distance: distance(cam, n), band: n.size == TileSelect.LEAF_M ? .near : .mid)
        }
        return out
    }

    /// Download order: coarse-and-near first (distance / size), so the whole site appears at once and sharpens near you.
    public static func fetchOrder(_ want: [String: TileSelect.Want], loaded: Set<String>) -> [TileSelect.Want] {
        want.values.filter { !loaded.contains($0.node.key) }.sorted { a, b in
            let ka = max(a.distance, MIN_DISTANCE) / Double(max(a.node.size, 1))
            let kb = max(b.distance, MIN_DISTANCE) / Double(max(b.node.size, 1))
            return ka != kb ? ka < kb : a.node.key < b.node.key
        }
    }

    /// What to release: everything neither wanted nor drawn, then (while the loaded total is over `budget`) the
    /// farthest hole-fillers (drawn but not wanted), then the farthest wanted tiles.
    /// `loaded` = key → (mem bytes, distance to the camera).
    public static func evict(loaded: [String: (mem: Int, distance: Double)], want: [String: TileSelect.Want],
                             drawn: Set<String>, budget: Int = BUDGET) -> [String] {
        var out = TileSelect.evictable(loaded: Set(loaded.keys), want: want, drawn: drawn)
        let gone = Set(out)
        var total = loaded.filter { !gone.contains($0.key) }.reduce(0) { $0 + $1.value.mem }
        guard total > budget else { return out }
        let rest = loaded.filter { !gone.contains($0.key) }
        let fillers = rest.filter { want[$0.key] == nil }.sorted { $0.value.distance != $1.value.distance ? $0.value.distance > $1.value.distance : $0.key < $1.key }
        let wanted = rest.filter { want[$0.key] != nil }.sorted { $0.value.distance != $1.value.distance ? $0.value.distance > $1.value.distance : $0.key < $1.key }
        for (k, v) in fillers + wanted {
            if total <= budget { break }
            out.append(k)
            total -= v.mem
        }
        return out
    }

    /// The site's bounds (map frame [x0, y0, z0, x1, y1, z1]) from the roots' boxes.
    public static func bounds(_ roots: [TileNode]) -> [Double]? {
        guard !roots.isEmpty else { return nil }
        var lo = [Double.infinity, .infinity, .infinity], hi = [-Double.infinity, -.infinity, -.infinity]
        for n in roots {
            let c = [n.box[0], n.box[1], n.box[2]], h = [n.box[3], n.box[7], n.box[11]]
            for i in 0..<3 { lo[i] = min(lo[i], c[i] - h[i]); hi[i] = max(hi[i], c[i] + h[i]) }
        }
        return lo + hi
    }
}

// MARK: - level slicer

public enum Map3DSlice {
    /// The slice's tile level (nil = Yard / everything).
    public static func maxLevel(_ slice: PlanLevel?) -> Int? { slice?.level }

    /// Height (map z) above which overlays are hidden for a slice: just under the next storey's floor (nil = no cut).
    public static func cutZ(levels: [PlanLevel], slice: PlanLevel?) -> Double? {
        guard let s = slice, s.level != nil, let f = s.floorZ else { return nil }
        let above = levels.compactMap { l -> Double? in
            guard l.level != nil, let z = l.floorZ, z > f + 0.5 else { return nil }
            return z
        }.min()
        return above.map { $0 - 0.1 }
    }
}

// MARK: - fly controller

public enum Map3DSpeed: String, CaseIterable, Identifiable {
    case walk, run, drone
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// m/s on the stick's rim.
    public var metresPerSecond: Double { self == .walk ? 1.4 : self == .run ? 4 : 8 }
    /// Walk / run follow the ground at eye height; the drone flies free above a clearance.
    public var followsGround: Bool { self != .drone }
    public var icon: String { self == .walk ? "figure.walk" : self == .run ? "figure.run" : "airplane" }
    public var next: Map3DSpeed { self == .walk ? .run : self == .run ? .drone : .walk }
}

public struct Map3DFlyParams: Equatable {
    public var speed: Map3DSpeed = .drone
    public var verticalFactor = 0.6
    public var accelTau = 0.25
    public var brakeTau = 0.15
    public var yawRate = 1.9
    public var pitchRate = 1.2
    public var maxPitch = 1.3              // rad (≈ 75°): the look clamp
    public var eyeHeight = 1.6             // walk / run: eye above the floor
    public var clearance = 0.4             // drone: never closer to the ground than this
    public var followTau = 0.12            // walk / run: eye height follows steps smoothly
    public init(speed: Map3DSpeed = .drone) { self.speed = speed }
}

public struct Map3DFlyState: Equatable {
    public var eye: Map3DVec
    public var yaw: Double                 // 0 = looking along −Z (viewer frame)
    public var pitch: Double               // positive = up
    public var velocity: Map3DVec
    public init(eye: Map3DVec, yaw: Double = 0, pitch: Double = 0, velocity: Map3DVec = .zero) {
        self.eye = eye; self.yaw = yaw; self.pitch = pitch; self.velocity = velocity
    }
}

public enum Map3DFly {
    /// Camera-frame axes on the ground plane (forward, right) for a yaw.
    public static func axes(yaw: Double) -> (forward: Map3DVec, right: Map3DVec) {
        (Map3DVec(-sin(yaw), 0, -cos(yaw)), Map3DVec(cos(yaw), 0, -sin(yaw)))
    }

    /// The stick (x = strafe right, y = forward; clamped to the unit disc) + climb → world velocity in the camera's
    /// heading frame. Walk / run ignore climb (the ground decides the height).
    public static func targetVelocity(stick: (Double, Double), climb: Double, yaw: Double, params p: Map3DFlyParams) -> Map3DVec {
        var mx = stick.0, my = stick.1
        let l = (mx * mx + my * my).squareRoot()
        if l > 1 { mx /= l; my /= l }
        let a = axes(yaw: yaw)
        let s = p.speed.metresPerSecond
        var v = (a.forward * my + a.right * mx) * s
        v.y = p.speed.followsGround ? 0 : max(-1, min(1, climb)) * s * p.verticalFactor
        return v
    }

    /// The look clamp.
    public static func clampPitch(_ pitch: Double, params p: Map3DFlyParams = Map3DFlyParams()) -> Double {
        max(-p.maxPitch, min(p.maxPitch, pitch))
    }

    /// The ground clamp: walk / run hold the eye at ground + eyeHeight (smoothed over `dt` for steps), the drone stays
    /// at least `clearance` above it. No ground known = unchanged.
    public static func groundClamp(_ eyeY: Double, ground: Double?, dt: Double, params p: Map3DFlyParams) -> Double {
        guard let g = ground else { return eyeY }
        if p.speed.followsGround {
            let want = g + p.eyeHeight
            if dt <= 0 || p.followTau <= 1e-4 { return want }
            let a = 1 - exp(-dt / p.followTau)
            let y = eyeY + (want - eyeY) * a
            return max(y, g + p.clearance)
        }
        return max(eyeY, g + p.clearance)
    }

    static func approach(_ v: Map3DVec, _ t: Map3DVec, dt: Double, tau: Double) -> Map3DVec {
        guard tau > 1e-4 else { return t }
        return v + (t - v) * (1 - exp(-dt / tau))
    }

    /// One frame: look (right stick / drag already applied by the caller, or `look` here), velocity toward the stick's
    /// target with smooth accel / brake, move, then the ground clamp. `ground(x, z)` = floor height (viewer y) there.
    public static func step(_ s: Map3DFlyState, stick: (Double, Double), look: (Double, Double) = (0, 0), climb: Double,
                            dt rawDt: Double, params p: Map3DFlyParams, ground: ((Double, Double) -> Double?)? = nil) -> Map3DFlyState {
        let dt = max(0, min(rawDt, 0.1))                    // a hitch never teleports the camera
        var out = s
        out.yaw -= look.0 * p.yawRate * dt
        out.pitch = clampPitch(s.pitch + look.1 * p.pitchRate * dt, params: p)
        let target = targetVelocity(stick: stick, climb: climb, yaw: out.yaw, params: p)
        let tau = target.length >= s.velocity.length ? p.accelTau : p.brakeTau
        var v = approach(s.velocity, target, dt: dt, tau: tau)
        if target == .zero && v.length < 0.01 { v = .zero }
        var e = s.eye + v * dt
        let g = ground?(e.x, e.z)
        let y = groundClamp(e.y, ground: g, dt: dt, params: p)
        if p.speed.followsGround || y != e.y { v.y = 0 }
        e.y = y
        out.eye = e
        out.velocity = v
        return out
    }

    /// Orbit: the smallest pitch (positive = looking down) that keeps the eye `clearance` above the ground, nil = any.
    public static func orbitMinPitch(targetY: Double, distance: Double, groundY: Double?, clearance: Double = 0.3) -> Double? {
        guard let g = groundY, distance > 1e-6 else { return nil }
        let s = (g + clearance - targetY) / distance
        if s <= -1 { return nil }
        return asin(min(1, s))
    }

    /// Gyro look: the attitude change since the last frame → (dYaw, dPitch), wrapped to (−π, π] and scaled.
    public static func gyroDelta(from a: (yaw: Double, pitch: Double), to b: (yaw: Double, pitch: Double), gain: Double = 1) -> (Double, Double) {
        var dy = (b.yaw - a.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if dy > .pi { dy -= 2 * .pi }
        if dy <= -.pi { dy += 2 * .pi }
        return (dy * gain, (b.pitch - a.pitch) * gain)
    }
}

// MARK: - ground under the camera

public struct Map3DFloor: Equatable {
    public var z: Double                   // map z of the floor
    public var bounds: [Double]?           // x0, y0, x1, y1 (map), nil = everywhere
    public init(z: Double, bounds: [Double]? = nil) { self.z = z; self.bounds = bounds }
    public func contains(_ x: Double, _ y: Double) -> Bool {
        guard let b = bounds, b.count >= 4 else { return true }
        return x >= b[0] && x <= b[2] && y >= b[1] && y <= b[3]
    }
}

public enum Map3DGround {
    /// Map z of the ground under (x, y) for an eye at `eyeZ`: the highest storey floor at or below the feet (eye − 0.4 m
    /// slack: stairs) whose plan covers the spot, else the estimated DEM, else the lowest floor; nil = nothing known.
    public static func height(x: Double, y: Double, eyeZ: Double, floors: [Map3DFloor], dem: Double?) -> Double? {
        let under = floors.filter { $0.contains(x, y) && $0.z <= eyeZ - 0.4 }.map(\.z).max()
        if let u = under {
            if let d = dem, d > u { return d }           // outdoors on a slope above the basement's plan bounds
            return u
        }
        if let d = dem { return d }
        let inside = floors.filter { $0.contains(x, y) }.map(\.z).min()
        return inside ?? floors.map(\.z).min()
    }
}

// MARK: - shapes

public enum Map3DShapes {
    /// Apex + 4 far corners (map frame) of a camera's view pyramid. yaw rad about +z (0 = +x), pitch deg (negative =
    /// down), the CameraFrustum convention.
    public static func frustum(camera c: [Double], yaw: Double, pitchDeg: Double, hfovDeg: Double, vfovDeg: Double,
                               far: Double) -> [[Double]] {
        let pitch = pitchDeg * .pi / 180
        let f = [cos(yaw) * cos(pitch), sin(yaw) * cos(pitch), sin(pitch)]
        let right = [sin(yaw), -cos(yaw), 0.0]
        let up = [-cos(yaw) * sin(pitch), -sin(yaw) * sin(pitch), cos(pitch)]
        let th = tan(hfovDeg * .pi / 360), tv = tan(vfovDeg * .pi / 360)
        var out = [c]
        for (sx, sy) in [(-1.0, 1.0), (1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] {
            var q = [0.0, 0.0, 0.0]
            for i in 0..<3 {
                let dir: Double = f[i] + right[i] * (th * sx) + up[i] * (tv * sy)
                q[i] = c[i] + far * dir
            }
            out.append(q)
        }
        return out
    }

    /// The frustum's 8 edges as index pairs into `frustum`'s points.
    public static let frustumEdges: [(Int, Int)] = [(0, 1), (0, 2), (0, 3), (0, 4), (1, 2), (2, 3), (3, 4), (4, 1)]

    /// A height-field mesh of the estimated ground (map frame, z up), every `step` cells, skipping cells with a
    /// non-finite corner. positions xyz flat, CCW from above.
    public static func terrain(origin: [Double], res: Double, w: Int, h: Int, ground: [Float], step: Int = 1)
        -> (positions: [Float], indices: [UInt32]) {
        guard w > 1, h > 1, ground.count == w * h, origin.count >= 2, step >= 1 else { return ([], []) }
        let xs = Array(stride(from: 0, to: w, by: step)), ys = Array(stride(from: 0, to: h, by: step))
        var pos: [Float] = []
        var idx: [UInt32] = []
        var vi = [Int32](repeating: -1, count: xs.count * ys.count)
        for (j, gy) in ys.enumerated() {
            for (i, gx) in xs.enumerated() {
                let z = ground[gy * w + gx]
                guard z.isFinite else { continue }
                vi[j * xs.count + i] = Int32(pos.count / 3)
                pos += [Float(origin[0] + (Double(gx) + 0.5) * res), Float(origin[1] + (Double(gy) + 0.5) * res), z]
            }
        }
        for j in 0..<(ys.count - 1) {
            for i in 0..<(xs.count - 1) {
                let a = vi[j * xs.count + i], b = vi[j * xs.count + i + 1]
                let c = vi[(j + 1) * xs.count + i + 1], d = vi[(j + 1) * xs.count + i]
                guard a >= 0, b >= 0, c >= 0, d >= 0 else { continue }
                idx += [UInt32(a), UInt32(b), UInt32(c), UInt32(a), UInt32(c), UInt32(d)]
            }
        }
        return (pos, idx)
    }

    /// Cell step that keeps a w × h grid under `maxTriangles`.
    public static func terrainStep(w: Int, h: Int, maxTriangles: Int = 40_000) -> Int {
        var s = 1
        while ((w - 1) / s) * ((h - 1) / s) * 2 > maxTriangles { s += 1 }
        return s
    }
}

// MARK: - quality

public enum Map3DQuality {
    /// Detail factor (refine k) from the measured frame rate: ~30 fps target on an iPhone 15 Pro class phone.
    public static func adjust(k: Double, fps: Double, low: Double = 24, high: Double = 45,
                              range: ClosedRange<Double> = 0.6...2.5) -> Double {
        var n = k
        if fps < low { n = k * 0.85 } else if fps > high { n = k * 1.1 }
        return min(range.upperBound, max(range.lowerBound, n))
    }

    /// The tile budget given the memory the OS still grants the app (MB, nil = unknown).
    public static func budget(base: Int = Map3DTiles.BUDGET, availableMB: Double?) -> Int {
        guard let a = availableMB else { return base }
        if a < 300 { return base / 3 }
        if a < 600 { return base / 2 }
        return base
    }
}

/// Frames → fps over a window (the RealityKit scene update events).
public struct Map3DFps {
    public var window: Double
    private var start: Double?
    private var frames = 0
    public private(set) var fps: Double?
    public init(window: Double = 1) { self.window = window }

    /// Count one frame at `t` (s); returns the new fps when a window closes.
    @discardableResult
    public mutating func frame(t: Double) -> Double? {
        guard let s = start else { start = t; frames = 0; return nil }
        frames += 1
        guard t - s >= window else { return nil }
        let f = Double(frames) / (t - s)
        fps = f
        start = t
        frames = 0
        return f
    }
}
