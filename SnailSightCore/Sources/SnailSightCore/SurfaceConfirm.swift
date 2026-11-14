import Foundation

// SnailSight 12.23 "show on confirm" (owner 2026-10-31: "I walk through a constant barrage of random wall data and
// whatnot but the grid seems to make it disappear within seconds"; walk sim docs/SNAILSIGHT-WALK-SIM-2026-10-31.md).
//
// 12.18–12.22 drew every stored base face until the phone's depth had SEEN THROUGH it (DeviceCoverage: hide after
// seen). Everything the phone had not looked at yet was drawn: the next room through a wall whose ARKit occlusion mesh
// was not built yet (or was just reset over its vertex cap), the doubled / offset copies of walls, removed walls,
// objects that moved. That is the barrage; the ARKit mesh (the "grid") growing over a surface occludes it a second
// later, and the device mask hides it after the next observe + rebuild.
//
// The rule now (fail closed): a stored BASE face is drawn only where this phone's LiDAR depth AGREES with it — a depth
// return landed within one 5 cm voxel of the face's drawn place, and later rays have not crossed that place since.
// Everything else (not seen yet, seen through, behind a measured surface) is hidden. So:
//   - a loaded / reloaded tile starts hidden: nothing flashes before the first test;
//   - the next room through a wall is never confirmed (depth stops at the wall in front);
//   - a removed wall / moved object / floater is never confirmed (depth passes through), a duplicate wall more than a
//     voxel off the real one neither;
//   - what is drawn sits on a real surface the phone measured, so the overlay "looks like the real room".
// Live surfaces (server live tiles, Layer B) keep the 12.18 rule (hidden where the phone has looked): they are fresh
// evidence of places this phone has NOT seen, e.g. another agent's change.
//
// A depth "pass" (a ray crossing a voxel ≥ `passMarginM` before its own return, at ≥ 30° to the voxel's surface) lowers
// the voxel's score; a return raises it. Grazing rays along a wall do not count against it.
// Pure Swift (no simd), Linux-tested (SurfaceConfirmTests, WalkSimTests).

/// How the device surface treats one registered mesh.
public enum StoredFacePolicy: String, Equatable {
    /// 12.18: hidden once the phone has observed its place (free space or a return up to 10 cm behind); sticky.
    case hideSeen
    /// 12.23: drawn only where the phone's depth confirms a surface at its drawn place; default hidden.
    case confirm
}

/// Sparse 5 cm voxels (ARKit world, y up) where this phone's depth returned, each with a signed score and the surface
/// normal of its latest return.
public struct DeviceSurfaceHits {
    public struct Vox: Equatable {
        public var score: Int8
        public var nx: Int8, ny: Int8, nz: Int8
        /// Mean return position inside the voxel, offset from its centre in voxM / 254 units.
        public var ox: Int8 = 0, oy: Int8 = 0, oz: Int8 = 0
    }

    public let voxM: Float
    public private(set) var vox: [Int64: Vox] = [:]
    /// Bumped by every observe() that created a voxel or flipped one's confirmed state.
    public private(set) var generation = 0
    public private(set) var recent: [(gen: Int, box: [Float])] = []
    public var maxVoxels = 800_000
    public static let cap: Int8 = 6
    public static let floor: Int8 = -6
    public static let boxKeep = 64
    /// |cos| between a passing ray and the voxel's normal for the pass to count (≥ 30° off the surface plane).
    public static let passCos: Float = 0.5

    public init(voxM: Float = 0.05) { self.voxM = voxM }

    public var count: Int { vox.count }
    /// Swift Dictionary<Int64, 4 B>: ~16 B a slot at ≤ 75 % load.
    public var estimatedBytes: Int { vox.capacity * 20 + 64 }

    @inline(__always) public func index(_ v: Float) -> Int32 { Int32((v / voxM).rounded(.down)) }
    @inline(__always) public func key(x: Float, y: Float, z: Float) -> Int64 {
        DeviceCoverageGrid.key(index(x), index(y), index(z))
    }

    /// Max distance from the measured surface plane (alignment ±2-3 cm + depth noise; a duplicate wall 7 cm off or the
    /// near face of a wall stored 20 cm away is NOT confirmed).
    public static let planeTolM: Float = 0.04
    public static let pointTolM: Float = 0.10

    /// A surface the phone measured at this world point: its voxel or one of the 6 face neighbours has a positive score
    /// and its mean return lies within `planeTolM` of the point along the voxel's normal (`pointTolM` overall).
    /// `n` = the stored face's unit normal (world); when given, the voxel's surface must face the same way
    /// (|cos| ≥ `normalCos`): a wall face whose centroid sits 5 cm above the floor, or the end of a stored wall that
    /// meets a real one, is not "on" that surface.
    public func confirmed(x: Float, y: Float, z: Float, n: (Float, Float, Float)? = nil) -> Bool {
        let i = index(x), j = index(y), k = index(z)
        for (a, b, c) in Self.seven {
            let ii = i + a, jj = j + b, kk = k + c
            guard let v = vox[DeviceCoverageGrid.key(ii, jj, kk)], v.score > 0 else { continue }
            let q = voxM / 254
            let hx = (Float(ii) + 0.5) * voxM + Float(v.ox) * q, hy = (Float(jj) + 0.5) * voxM + Float(v.oy) * q
            let hz = (Float(kk) + 0.5) * voxM + Float(v.oz) * q
            let dx = x - hx, dy = y - hy, dz = z - hz
            let d2 = dx * dx + dy * dy + dz * dz
            if d2 > Self.pointTolM * Self.pointTolM { continue }
            let nx = Float(v.nx) / 127, ny = Float(v.ny) / 127, nz = Float(v.nz) / 127
            if nx * nx + ny * ny + nz * nz < 0.25 {
                if d2 <= Self.planeTolM * Self.planeTolM { return true }
                continue
            }
            if let f = n, abs(f.0 * nx + f.1 * ny + f.2 * nz) < Self.normalCos { continue }
            if abs(dx * nx + dy * ny + dz * nz) <= Self.planeTolM { return true }
        }
        return false
    }

    public static let normalCos: Float = 0.7

    static let seven: [(Int32, Int32, Int32)] = [(0, 0, 0), (1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1),
                                                 (0, 0, -1)]

    public mutating func clear() {
        vox.removeAll(keepingCapacity: false)
        recent.removeAll()
        generation += 1
    }

    /// Over `maxVoxels`, voxels farther than `radius` (horizontal) from (x, z) go; the radius shrinks ×0.75 until ≤ 80 %.
    @discardableResult
    public mutating func prune(x: Float, z: Float, radius: Float, maxVoxels cap: Int) -> Int {
        guard vox.count > cap, cap >= 0 else { return 0 }
        let before = vox.count
        let ci = index(x), ck = index(z)
        var r = max(1, Int32((radius / voxM).rounded(.up)))
        let goal = Int(Double(cap) * 0.8)
        while vox.count > goal {
            let r2 = Int64(r) * Int64(r)
            vox = vox.filter { kv in
                let h = DeviceCoverageGrid.horizontal(kv.key)
                let di = Int64(h.i - ci), dk = Int64(h.k - ck)
                return di * di + dk * dk <= r2
            }
            if r <= 1 { break }
            r = max(1, Int32(Double(r) * 0.75))
        }
        generation += 1                                        // forgotten voxels un-confirm their faces
        recent.removeAll()
        return before - vox.count
    }

    public struct ObserveStats: Equatable {
        public var rays = 0
        public var hits = 0
        public var passes = 0
        public var flips = 0
        public var created = 0
    }

    /// One LiDAR depth frame (same conventions as DeviceCoverageGrid.observe).
    @discardableResult
    public mutating func observe(depth: [Float], width: Int, height: Int, confidence: [UInt8]?, K: [Float],
                                 camToWorld m: [Float], stride st: Int = 4, minConfidence: UInt8 = 1,
                                 maxRange: Float = 4.5, passMarginM: Float = 0.08) -> ObserveStats {
        var s = ObserveStats()
        guard width > 0, height > 0, depth.count >= width * height, K.count >= 4, m.count >= 16 else { return s }
        let fx = K[0], fy = K[1], cx = K[2], cy = K[3]
        let ox = m[12], oy = m[13], oz = m[14]
        var lo: [Float] = [.infinity, .infinity, .infinity], hi: [Float] = [-.infinity, -.infinity, -.infinity]
        func grow(_ px: Float, _ py: Float, _ pz: Float) {
            if px < lo[0] { lo[0] = px }; if py < lo[1] { lo[1] = py }; if pz < lo[2] { lo[2] = pz }
            if px > hi[0] { hi[0] = px }; if py > hi[1] { hi[1] = py }; if pz > hi[2] { hi[2] = pz }
        }
        func ok(_ i: Int) -> Bool {
            let d = depth[i]
            if !(d > 0.05) || d > maxRange { return false }
            if let c = confidence, c.count > i, c[i] < minConfidence { return false }
            return true
        }
        // world point of pixel (u, v) at depth d
        func world(_ u: Int, _ v: Int, _ d: Float) -> (Float, Float, Float) {
            let rx = (Float(u) + 0.5 - cx) / fx * d, ry = -((Float(v) + 0.5 - cy) / fy) * d, rz = -d
            return (ox + m[0] * rx + m[4] * ry + m[8] * rz, oy + m[1] * rx + m[5] * ry + m[9] * rz,
                    oz + m[2] * rx + m[6] * ry + m[10] * rz)
        }
        var v = st / 2
        while v < height {
            var u = st / 2
            while u < width {
                let i = v * width + u
                let uu = u
                u += st
                s.rays += 1
                guard ok(i) else { continue }
                let d = depth[i]
                let p = world(uu, v, d)
                // surface normal from the neighbouring returns (right / down), oriented toward the camera
                var n: (Float, Float, Float) = (0, 0, 0)
                let ur = min(uu + st, width - 1), vd = min(v + st, height - 1)
                let ir = v * width + ur, id = vd * width + uu
                if ur != uu, vd != v, ok(ir), ok(id), abs(depth[ir] - d) < 0.25, abs(depth[id] - d) < 0.25 {
                    let a = world(ur, v, depth[ir]), b = world(uu, vd, depth[id])
                    let e1 = (a.0 - p.0, a.1 - p.1, a.2 - p.2), e2 = (b.0 - p.0, b.1 - p.1, b.2 - p.2)
                    var c = (e1.1 * e2.2 - e1.2 * e2.1, e1.2 * e2.0 - e1.0 * e2.2, e1.0 * e2.1 - e1.1 * e2.0)
                    let l = (c.0 * c.0 + c.1 * c.1 + c.2 * c.2).squareRoot()
                    if l > 1e-9 {
                        c = (c.0 / l, c.1 / l, c.2 / l)
                        if c.0 * (ox - p.0) + c.1 * (oy - p.1) + c.2 * (oz - p.2) < 0 { c = (-c.0, -c.1, -c.2) }
                        n = c
                    }
                }
                // the return
                let pi = index(p.0), pj = index(p.1), pk = index(p.2)
                let ke = DeviceCoverageGrid.key(pi, pj, pk)
                let q = { (x: Float) -> Int8 in Int8(max(-127, min(127, (x * 127).rounded()))) }
                let vm = voxM
                let off = { (v: Float, i: Int32) -> Float in (v - (Float(i) + 0.5) * vm) / vm * 254 }
                let o = (off(p.0, pi), off(p.1, pj), off(p.2, pk))
                if var e = vox[ke] {
                    let was = e.score > 0
                    let w = Float(max(1, Int(e.score)))
                    e.ox = Int8(max(-127, min(127, ((Float(e.ox) * w + o.0) / (w + 1)).rounded())))
                    e.oy = Int8(max(-127, min(127, ((Float(e.oy) * w + o.1) / (w + 1)).rounded())))
                    e.oz = Int8(max(-127, min(127, ((Float(e.oz) * w + o.2) / (w + 1)).rounded())))
                    e.score = min(Self.cap, e.score + 1)
                    if n.0 != 0 || n.1 != 0 || n.2 != 0 { e.nx = q(n.0); e.ny = q(n.1); e.nz = q(n.2) }
                    vox[ke] = e
                    if !was && e.score > 0 { s.flips += 1; grow(p.0, p.1, p.2) }
                } else {
                    vox[ke] = Vox(score: 1, nx: q(n.0), ny: q(n.1), nz: q(n.2),
                                  ox: Int8(max(-127, min(127, o.0.rounded()))), oy: Int8(max(-127, min(127, o.1.rounded()))),
                                  oz: Int8(max(-127, min(127, o.2.rounded()))))
                    s.created += 1
                    grow(p.0, p.1, p.2)
                }
                s.hits += 1
                // the free space in front of it: lower known voxels it crosses (not grazing ones)
                let dx = (p.0 - ox) / max(d, 1e-6), dy = (p.1 - oy) / max(d, 1e-6), dz = (p.2 - oz) / max(d, 1e-6)
                let len = (dx * dx + dy * dy + dz * dz).squareRoot()
                let r = d * len
                let ux = dx / len, uy = dy / len, uz = dz / len
                var t: Float = 0.1
                var last: Int64 = ke
                let tEnd = r - passMarginM
                while t < tEnd {
                    let px = ox + ux * t, py = oy + uy * t, pz = oz + uz * t
                    t += voxM
                    let k = key(x: px, y: py, z: pz)
                    if k == last { continue }
                    last = k
                    guard var e = vox[k] else { continue }
                    let nn = (Float(e.nx) / 127, Float(e.ny) / 127, Float(e.nz) / 127)
                    let ln = nn.0 * nn.0 + nn.1 * nn.1 + nn.2 * nn.2
                    if ln > 0.25 && abs(nn.0 * ux + nn.1 * uy + nn.2 * uz) < Self.passCos { continue }   // grazing
                    let was = e.score > 0
                    e.score = max(Self.floor, e.score - 1)
                    vox[k] = e
                    s.passes += 1
                    if was && e.score <= 0 { s.flips += 1; grow(px, py, pz) }
                }
            }
            v += st
        }
        if s.flips > 0 || s.created > 0 {
            generation += 1
            let pad = voxM * 2
            recent.append((generation, [lo[0] - pad, lo[1] - pad, lo[2] - pad, hi[0] + pad, hi[1] + pad, hi[2] + pad]))
            if recent.count > Self.boxKeep { recent.removeFirst(recent.count - Self.boxKeep) }
        }
        return s
    }

    /// World boxes changed after generation `since`; nil = unknown (older than the kept boxes): test everything.
    public func changedBoxes(since: Int) -> [[Float]]? {
        if since >= generation { return [] }
        guard let first = recent.first, first.gen <= since + 1 else { return nil }
        return recent.filter { $0.gen > since }.map { $0.box }
    }
}

/// The faces of one stored mesh under the confirm rule: `shown` only where the phone's depth confirmed a surface.
public struct ConfirmedFaces {
    public let id: String
    public let centroids: [Float]                   // x, y, z per face (map frame)
    /// Unit face normals ×127 (map frame), 3 per face; empty = unknown (centroid test only).
    public let normals: [Int8]
    public let box: [Float]
    public private(set) var shown: [Bool]
    public private(set) var shownCount = 0
    public private(set) var testedGen = -1
    public private(set) var testedAlign: Align4?

    public init(id: String, centroids: [Float], normals: [Int8] = []) {
        self.id = id
        self.centroids = centroids
        self.normals = normals.count == centroids.count ? normals : []
        shown = [Bool](repeating: false, count: centroids.count / 3)
        box = CoveredFaces(id: id, centroids: centroids).box
    }

    public var faceCount: Int { shown.count }
    public var hiddenCount: Int { shown.count - shownCount }
    /// The mask the owner draws with: true = hidden.
    public var hiddenMask: [Bool] { shown.map { !$0 } }

    /// Re-test the faces whose drawn place lies in a changed region (all of them when the alignment moved or the
    /// history is unknown). Returns (newly shown, newly hidden).
    @discardableResult
    public mutating func update(hits h: DeviceSurfaceHits, align al: Align4, force: Bool = false) -> (shown: Int, hidden: Int) {
        let moved = testedAlign.map { CoveredFaces.moved($0, al) } ?? true
        var boxes: [[Float]]? = force || moved ? nil : h.changedBoxes(since: testedGen)
        if let b = boxes {
            let mine = worldBox(al)
            let near = b.filter { $0[0] <= mine[3] && $0[3] >= mine[0] && $0[1] <= mine[4] && $0[4] >= mine[1]
                                  && $0[2] <= mine[5] && $0[5] >= mine[2] }
            if near.isEmpty { testedGen = h.generation; return (0, 0) }
            boxes = near
        }
        testedGen = h.generation
        testedAlign = al
        let c = Float(cos(al.yaw)), s = Float(sin(al.yaw))
        let ax = Float(al.x), ay = Float(al.y), az = Float(al.z)
        var up = 0, down = 0
        let cnt = shown.count
        var f = 0
        while f < cnt {
            let qx = centroids[f * 3], qy = centroids[f * 3 + 1], qz = centroids[f * 3 + 2]
            f += 1
            guard qx == qx else { continue }
            let dx = qx - ax, dy = qy - ay
            let wx = c * dx + s * dy, wy = qz - az, wz = s * dx - c * dy
            if let bs = boxes {
                var inside = false
                for b in bs where wx >= b[0] && wx <= b[3] && wy >= b[1] && wy <= b[4] && wz >= b[2] && wz <= b[5] {
                    inside = true
                    break
                }
                if !inside { continue }
            }
            var nw: (Float, Float, Float)?
            if !normals.isEmpty {
                let i = (f - 1) * 3
                let nx = Float(normals[i]) / 127, ny = Float(normals[i + 1]) / 127, nz = Float(normals[i + 2]) / 127
                if nx * nx + ny * ny + nz * nz > 0.25 { nw = (c * nx + s * ny, nz, s * nx - c * ny) }
            }
            let now = h.confirmed(x: wx, y: wy, z: wz, n: nw)
            if now != shown[f - 1] {
                shown[f - 1] = now
                if now { up += 1 } else { down += 1 }
            }
        }
        shownCount += up - down
        return (up, down)
    }

    public func worldBox(_ al: Align4) -> [Float] {
        var lo: [Float] = [.infinity, .infinity, .infinity], hi: [Float] = [-.infinity, -.infinity, -.infinity]
        for xi in [0, 3] { for yi in [1, 4] { for zi in [2, 5] {
            let w = al.toArkit([Double(box[xi]), Double(box[yi]), Double(box[zi])])
            for a in 0..<3 { lo[a] = min(lo[a], Float(w[a])); hi[a] = max(hi[a], Float(w[a])) }
        } } }
        return lo + hi
    }

    /// Everything hidden again (world frame change).
    public mutating func reset() {
        shown = [Bool](repeating: false, count: shown.count)
        shownCount = 0
        testedGen = -1
        testedAlign = nil
    }
}

public extension ConfirmedFaces {
    /// Unit face normals ×127 of a triangle mesh (positions xyz, triangle indices), 3 per face.
    static func normals(positions p: [Float], indices idx: [UInt32]) -> [Int8] {
        var out = [Int8]()
        out.reserveCapacity(idx.count)
        let nv = p.count / 3
        var t = 0
        while t + 2 < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            t += 3
            guard a < nv, b < nv, c < nv else { out += [0, 0, 0]; continue }
            let e1 = (p[b * 3] - p[a * 3], p[b * 3 + 1] - p[a * 3 + 1], p[b * 3 + 2] - p[a * 3 + 2])
            let e2 = (p[c * 3] - p[a * 3], p[c * 3 + 1] - p[a * 3 + 1], p[c * 3 + 2] - p[a * 3 + 2])
            let n = (e1.1 * e2.2 - e1.2 * e2.1, e1.2 * e2.0 - e1.0 * e2.2, e1.0 * e2.1 - e1.1 * e2.0)
            let l = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
            guard l > 1e-12 else { out += [0, 0, 0]; continue }
            out.append(Int8((n.0 / l * 127).rounded())); out.append(Int8((n.1 / l * 127).rounded()))
            out.append(Int8((n.2 / l * 127).rounded()))
        }
        return out
    }
}

/// The whole device-surface cycle without ARKit / RealityKit: registered meshes, the two evidence grids, and which mask
/// each owner should draw now (rebuild pacing from the MemPlan). The app's DeviceSurface runs exactly this on its queue;
/// the walk simulation (WalkSimTests) runs it on synthetic LiDAR frames.
public struct DeviceSurfaceEngine {
    public struct Delivery: Equatable {
        public var id: String
        public var hidden: [Bool]                   // empty = draw everything
        public var hiddenCount: Int
    }

    struct Entry {
        var policy: StoredFacePolicy
        var covered: CoveredFaces?
        var confirmed: ConfirmedFaces?
        var appliedHidden = 0                       // hideSeen: hidden count the owner draws
        var pendingShown = 0                        // confirm: flips not delivered yet
        var pendingHidden = 0
        var lastDelivered = -1e9
    }

    public private(set) var grid = DeviceCoverageGrid()
    public private(set) var hits = DeviceSurfaceHits()
    var entries: [String: Entry] = [:]
    public private(set) var lastAlign: Align4?
    public private(set) var pruned = 0
    public static let maxApplyPerCycle = 3

    public init() {}

    public var ids: [String] { Array(entries.keys) }
    public func policy(_ id: String) -> StoredFacePolicy? { entries[id]?.policy }
    // loops, not nested reduce: Xcode timed out type-checking nested reduces (12.20)
    public var faces: Int {
        var n = 0
        for e in entries.values {
            if let c = e.covered { n += c.faceCount } else if let c = e.confirmed { n += c.faceCount }
        }
        return n
    }
    public var hidden: Int {
        var n = 0
        for e in entries.values {
            if let c = e.covered { n += c.hiddenCount } else if let c = e.confirmed { n += c.hiddenCount }
        }
        return n
    }
    public var faceBytes: Int {
        var n = 0
        for e in entries.values {
            if let c = e.covered { n += c.centroids.count * 4 + c.faceCount }
            if let c = e.confirmed { n += c.centroids.count * 4 + c.normals.count + c.faceCount }
        }
        return n
    }

    /// The mask an entry should be drawn with right now (hidden flags; empty = everything drawn).
    public func mask(_ id: String) -> [Bool]? {
        guard let e = entries[id] else { return nil }
        if let c = e.confirmed { return c.hiddenMask }
        if let c = e.covered { return c.hiddenCount > 0 ? c.hidden : [] }
        return nil
    }

    /// A drawn mesh. `active` = the rule is on (depth flows); a confirm mesh registered while active is delivered at
    /// once (hidden except what is already confirmed), so it never draws before its first test.
    public mutating func register(id: String, centroids: [Float], normals: [Int8] = [], policy: StoredFacePolicy,
                                  active: Bool, now: Double = 0) -> Delivery? {
        var e = Entry(policy: policy)
        switch policy {
        case .hideSeen:
            var cf = CoveredFaces(id: id, centroids: centroids)
            if active, let al = lastAlign, grid.count > 0 { cf.update(grid: grid, align: al, force: true) }
            e.appliedHidden = cf.hiddenCount
            e.covered = cf
            entries[id] = e
            return cf.hiddenCount > 0 ? Delivery(id: id, hidden: cf.hidden, hiddenCount: cf.hiddenCount) : nil
        case .confirm:
            var cf = ConfirmedFaces(id: id, centroids: centroids, normals: normals)
            if active, let al = lastAlign, hits.count > 0 { cf.update(hits: hits, align: al, force: true) }
            e.confirmed = cf
            e.lastDelivered = now
            entries[id] = e
            return active ? Delivery(id: id, hidden: cf.hiddenMask, hiddenCount: cf.hiddenCount) : nil
        }
    }

    public mutating func unregister(id: String) { entries[id] = nil }

    /// The rule switched on: every confirm mesh gets its current mask (hidden unless confirmed).
    public mutating func activate(now: Double = 0) -> [Delivery] {
        var out: [Delivery] = []
        for (id, var e) in entries {
            guard let c = e.confirmed else { continue }
            e.pendingShown = 0; e.pendingHidden = 0; e.lastDelivered = now
            entries[id] = e
            out.append(Delivery(id: id, hidden: c.hiddenMask, hiddenCount: c.hiddenCount))
        }
        return out
    }

    public struct Cycle {
        public var coverage = DeviceCoverageGrid.ObserveStats()
        public var surface = DeviceSurfaceHits.ObserveStats()
        public var deliveries: [Delivery] = []
        public var pruned = 0
    }

    /// One depth frame: both grids, the spatial caps, every mesh re-tested, and the masks due for a rebuild (≤ the
    /// plan's per-cycle count; a mesh at most every `maskRebuildMinS`, except confirm meshes with faces to HIDE).
    public mutating func observe(depth: [Float], width: Int, height: Int, confidence: [UInt8]?, K: [Float],
                                 camToWorld m: [Float], align al: Align4, plan: MemPlan, now: Double,
                                 stride st: Int = 4) -> Cycle {
        var cy = Cycle()
        let needCoverage = entries.values.contains { $0.policy == .hideSeen }
        if needCoverage {
            cy.coverage = grid.observe(depth: depth, width: width, height: height, confidence: confidence, K: K,
                                       camToWorld: m, stride: st)
        }
        cy.surface = hits.observe(depth: depth, width: width, height: height, confidence: confidence, K: K,
                                  camToWorld: m, stride: st)
        let cut = grid.prune(x: m[12], z: m[14], radius: Float(plan.deviceKeepRadiusM), maxCells: plan.deviceCellsMax)
            + hits.prune(x: m[12], z: m[14], radius: Float(plan.deviceKeepRadiusM), maxVoxels: plan.deviceCellsMax)
        pruned += cut
        cy.pruned = cut
        lastAlign = al
        let cap = min(Self.maxApplyPerCycle, plan.maskRebuildsPerCycle)
        // confirm meshes with faces to hide first (a false show must go quickly), then the rest
        var order: [(String, Int)] = []
        for (id, var e) in entries {
            switch e.policy {
            case .hideSeen:
                guard var c = e.covered else { continue }
                c.update(grid: grid, align: al)
                e.covered = c
                let pri = CoverageRebuild.due(hidden: c.hiddenCount, applied: e.appliedHidden, faces: c.faceCount) ? 1 : 0
                if pri > 0 { order.append((id, 1)) }
            case .confirm:
                guard var c = e.confirmed else { continue }
                let r = c.update(hits: hits, align: al)
                e.confirmed = c
                e.pendingShown += r.shown
                e.pendingHidden += r.hidden
                if e.pendingHidden > 0 { order.append((id, 2)) }
                else if e.pendingShown > 0 && (e.pendingShown >= 24 || Double(e.pendingShown) >= 0.01 * Double(c.faceCount)) {
                    order.append((id, 1))
                }
            }
            entries[id] = e
        }
        order.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        for (id, pri) in order {
            guard cy.deliveries.count < cap, var e = entries[id] else { continue }
            let throttled = now - e.lastDelivered < plan.maskRebuildMinS
            if throttled && !(pri == 2 && e.policy == .confirm) { continue }
            e.lastDelivered = now
            if let c = e.covered {
                e.appliedHidden = c.hiddenCount
                cy.deliveries.append(Delivery(id: id, hidden: c.hidden, hiddenCount: c.hiddenCount))
            } else if let c = e.confirmed {
                e.pendingShown = 0
                e.pendingHidden = 0
                cy.deliveries.append(Delivery(id: id, hidden: c.hiddenMask, hiddenCount: c.hiddenCount))
            }
            entries[id] = e
        }
        return cy
    }

    /// The ARKit world frame changed: what the device saw belongs to the old one. Returns each mesh's mask after the
    /// reset (hideSeen: everything drawn again; confirm: everything hidden until confirmed again).
    public mutating func reset(now: Double = 0) -> [Delivery] {
        grid.clear()
        hits.clear()
        var out: [Delivery] = []
        for (id, var e) in entries {
            if let c = e.covered {
                e.covered = CoveredFaces(id: id, centroids: c.centroids)
                e.appliedHidden = 0
                out.append(Delivery(id: id, hidden: [], hiddenCount: 0))
            } else if var c = e.confirmed {
                c.reset()
                e.confirmed = c
                e.pendingShown = 0; e.pendingHidden = 0; e.lastDelivered = now
                out.append(Delivery(id: id, hidden: c.hiddenMask, hiddenCount: c.hiddenCount))
            }
            entries[id] = e
        }
        return out
    }
}

/// 12.23: why Live map does not send a keyframe now (nil = it streams). 12.14–12.22 also paused for Record: the owner's
/// 10-31 walk had Live map on for 184 s and sent 13 keyframes, because Record was on for 175 s of it. Recording no
/// longer pauses the live stream (the stream's bye still says `recorded`, so the server knows a capture covers it).
public enum LivePause {
    public static func reason(recording: Bool, scansOpen: Bool, map3DOpen: Bool, thermalCritical: Bool,
                              trackingNormal: Bool, pauseWhileRecording: Bool = false, scanViewOpen: Bool = false) -> String? {
        if recording && pauseWhileRecording { return "recording" }
        if scansOpen { return "Scans" }
        if scanViewOpen { return "the 3D scan view" }              // 12.27: the orbit view hides the camera
        if map3DOpen { return "3D map" }
        if thermalCritical { return "too hot" }
        if !trackingNormal { return "tracking" }
        return nil
    }
}

/// 12.23: Live map changes ONLY on an owner tap, and a tap that would turn it OFF right after Record started / stopped
/// (the sheet relayouts, the sim resumes and ~30 animation clips load: 10-31 the owner's Live map went off 2.7 s after
/// Stop with a quick_action they did not mean) asks for a second tap. Every change is logged with its cause.
public enum LiveTapGuard {
    public enum Decision: String, Equatable { case apply, confirm }
    public static let recordWindowS = 4.0
    public static let confirmWindowS = 4.0

    /// `turningOn` = the tap would turn Live map on; `lastRecordToggle` = when Record last started / stopped;
    /// `pendingConfirmAt` = when a previous guarded tap asked for confirmation.
    public static func decide(now: Double, turningOn: Bool, lastRecordToggle: Double?, pendingConfirmAt: Double?) -> Decision {
        if turningOn { return .apply }
        if let p = pendingConfirmAt, now - p >= 0, now - p <= confirmWindowS { return .apply }
        if let r = lastRecordToggle, now - r >= 0, now - r < recordWindowS { return .confirm }
        return .apply
    }
}
