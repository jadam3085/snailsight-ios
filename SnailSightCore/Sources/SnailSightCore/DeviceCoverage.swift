import Foundation

// SnailSight 12.18 "device surface is truth near you" (live world build 2026-10-28 item 1; research rank 2, what ARKit,
// Quest and HoloLens do). In AR the phone's own LiDAR sees the room as it is NOW; the stored base tiles are a slightly
// misaligned (±6 cm) snapshot of the past. Drawing both doubles everything (the owner's red compressor tank).
//
// The rule: a stored face (base tile or server live tile) whose place this device has OBSERVED this session is hidden
// and stays hidden for the session; the device mesh (RealityKit occlusion from ARMeshAnchors, depth-only, plus the
// optional live-surface wire) and the camera picture are what you see there. Stored faces are drawn only where the
// device has no coverage (far away, behind walls, rooms not walked yet). Never two surfaces of the same place.
//
// "Observed" = a LiDAR depth ray (confidence ≥ medium, ≤ `maxRange`) passed through the place (free space: the stored
// surface is not there any more, or is misplaced) or ended at it within `behindM` (the device has its own surface
// there). Places behind a measured surface by more than `behindM` are occluded: no evidence, the stored face stays
// (and RealityKit's occlusion mesh hides it anyway).
//
// Everything is kept in the ARKit WORLD frame (what the device saw does not move when the map alignment is refined);
// stored faces are tested at their DRAWN place (map → world through the shown alignment). The grid is cleared when the
// ARKit world frame changes (session reset / relocalization jump).
// Pure Swift (no simd), Linux-tested (DeviceCoverageTests).

/// Sparse set of `cellM` voxels (ARKit world frame, y up) the device has observed this session.
public struct DeviceCoverageGrid {
    public let cellM: Float
    public private(set) var cells = Set<Int64>()
    /// Bumped by every observe() that marked at least one new cell.
    public private(set) var generation = 0
    /// Boxes (world, [x0, y0, z0, x1, y1, z1]) of the cells newly marked per generation (newest last, ≤ `boxKeep`).
    public private(set) var recent: [(gen: Int, box: [Float])] = []
    public var maxCells = 2_500_000
    public private(set) var saturated = false
    public static let boxKeep = 64

    public init(cellM: Float = 0.10) { self.cellM = cellM }

    public var count: Int { cells.count }

    @inline(__always)
    public func index(_ v: Float) -> Int32 { Int32((v / cellM).rounded(.down)) }

    @inline(__always)
    public static func key(_ i: Int32, _ j: Int32, _ k: Int32) -> Int64 {
        let m: Int64 = (1 << 21) - 1
        return ((Int64(i) + (1 << 20)) & m) | (((Int64(j) + (1 << 20)) & m) << 21) | (((Int64(k) + (1 << 20)) & m) << 42)
    }

    @inline(__always)
    public func key(x: Float, y: Float, z: Float) -> Int64 { Self.key(index(x), index(y), index(z)) }

    public func contains(x: Float, y: Float, z: Float) -> Bool { cells.contains(key(x: x, y: y, z: z)) }

    /// Horizontal cell indices (world x, z: ARKit is y up) of a packed key.
    @inline(__always)
    public static func horizontal(_ key: Int64) -> (i: Int32, k: Int32) {
        let m: Int64 = (1 << 21) - 1
        return (Int32((key & m) - (1 << 20)), Int32(((key >> 42) & m) - (1 << 20)))
    }

    /// 12.20 spatial cap (12.19 walk: 9.6 k -> 201 k cells in 100 s; a 30 min walk would reach the 2.5 M hard cap and
    /// stop hiding). Over `maxCells`, cells farther than `radius` (horizontal, world) from (x, z) go; the radius shrinks
    /// ×0.75 until ≤ 80 % of the cap. Faces already hidden stay hidden (CoveredFaces is sticky), so what goes is only the
    /// memory of far places. Returns the number of cells removed.
    @discardableResult
    public mutating func prune(x: Float, z: Float, radius: Float, maxCells: Int) -> Int {
        guard cells.count > maxCells, maxCells >= 0 else { return 0 }
        let before = cells.count
        let ci = index(x), ck = index(z)
        var r = max(1, Int32((radius / cellM).rounded(.up)))
        let goal = Int(Double(maxCells) * 0.8)
        while cells.count > goal {
            let r2 = Int64(r) * Int64(r)
            cells = cells.filter { key in
                let h = Self.horizontal(key)
                let di = Int64(h.i - ci), dk = Int64(h.k - ck)
                return di * di + dk * dk <= r2
            }
            if r <= 1 { break }
            r = max(1, Int32(Double(r) * 0.75))
        }
        saturated = false                                   // removing cells hides nothing new: generation stays
        return before - cells.count
    }

    /// Estimated bytes (Swift Set<Int64>: ~8 B a key at ≤ 75 % load + metadata).
    public var estimatedBytes: Int { cells.capacity * 9 + 64 }

    public mutating func clear() {
        cells.removeAll(keepingCapacity: false)
        recent.removeAll()
        saturated = false
        generation += 1
    }

    public struct ObserveStats: Equatable {
        public var rays = 0
        public var skipped = 0
        public var marked = 0
    }

    /// One LiDAR depth frame. `depth` metres, row-major `width × height`; `confidence` ARKit 0 low / 1 medium / 2 high
    /// (nil = all trusted); `K` = [fx, fy, cx, cy] at the DEPTH resolution; `camToWorld` = ARKit camera → world,
    /// column-major 4×4 (ARKit: camera x right, y up, looks along −z; pixel v grows downwards).
    @discardableResult
    public mutating func observe(depth: [Float], width: Int, height: Int, confidence: [UInt8]?, K: [Float],
                                 camToWorld m: [Float], stride st: Int = 4, minConfidence: UInt8 = 1,
                                 maxRange: Float = 4.5, behindM: Float = 0.10) -> ObserveStats {
        var s = ObserveStats()
        guard width > 0, height > 0, depth.count >= width * height, K.count >= 4, m.count >= 16, !saturated else { return s }
        let fx = K[0], fy = K[1], cx = K[2], cy = K[3]
        let ox = m[12], oy = m[13], oz = m[14]
        let step = cellM * 0.5
        var lo: [Float] = [.infinity, .infinity, .infinity], hi: [Float] = [-.infinity, -.infinity, -.infinity]
        var v = st / 2
        while v < height {
            var u = st / 2
            while u < width {
                let i = v * width + u
                u += st
                let d = depth[i]
                s.rays += 1
                if !(d > 0.05) || d > maxRange || (confidence.map { $0.count > i && $0[i] < minConfidence } ?? false) {
                    s.skipped += 1
                    continue
                }
                // camera ray (ARKit camera axes), unit length per metre of depth along the optical axis
                let rx = (Float(u) + 0.5 - cx) / fx, ry = -((Float(v) + 0.5 - cy) / fy), rz: Float = -1
                let wx = m[0] * rx + m[4] * ry + m[8] * rz
                let wy = m[1] * rx + m[5] * ry + m[9] * rz
                let wz = m[2] * rx + m[6] * ry + m[10] * rz
                let len = (wx * wx + wy * wy + wz * wz).squareRoot()
                let r = d * len                                 // range along the ray
                let tEnd = r + behindM
                let dx = wx / len, dy = wy / len, dz = wz / len
                var t: Float = 0.1
                var last: Int64 = .min
                while t <= tEnd {
                    let px = ox + dx * t, py = oy + dy * t, pz = oz + dz * t
                    let k = key(x: px, y: py, z: pz)
                    if k != last {
                        last = k
                        if cells.insert(k).inserted {
                            s.marked += 1
                            if px < lo[0] { lo[0] = px }; if py < lo[1] { lo[1] = py }; if pz < lo[2] { lo[2] = pz }
                            if px > hi[0] { hi[0] = px }; if py > hi[1] { hi[1] = py }; if pz > hi[2] { hi[2] = pz }
                        }
                    }
                    t += step
                }
            }
            v += st
        }
        if s.marked > 0 {
            generation += 1
            let pad = cellM
            recent.append((generation, [lo[0] - pad, lo[1] - pad, lo[2] - pad, hi[0] + pad, hi[1] + pad, hi[2] + pad]))
            if recent.count > Self.boxKeep { recent.removeFirst(recent.count - Self.boxKeep) }
        }
        if cells.count > maxCells { saturated = true }
        return s
    }

    /// Did anything get marked inside `box` (world) after generation `since`? nil = cannot tell (older than the kept
    /// boxes): test everything.
    public func changed(in box: [Float], since: Int) -> Bool {
        if since >= generation { return false }
        guard let first = recent.first, first.gen <= since + 1 else { return true }
        for r in recent where r.gen > since {
            let b = r.box
            if b[0] <= box[3] && b[3] >= box[0] && b[1] <= box[4] && b[4] >= box[1] && b[2] <= box[5] && b[5] >= box[2] {
                return true
            }
        }
        return false
    }
}

/// The faces of one drawn mesh (a base tile, a live tile) as centroids in the MAP frame (z up), with their sticky
/// hidden flags.
public struct CoveredFaces {
    public let id: String
    public let centroids: [Float]                   // x, y, z per face (map frame)
    public private(set) var hidden: [Bool]
    public private(set) var hiddenCount = 0
    public private(set) var testedGen = -1
    public private(set) var testedAlign: Align4?
    /// Map-frame box of the centroids [x0, y0, z0, x1, y1, z1].
    public let box: [Float]

    public init(id: String, centroids: [Float]) {
        self.id = id
        self.centroids = centroids
        hidden = [Bool](repeating: false, count: centroids.count / 3)
        var lo: [Float] = [.infinity, .infinity, .infinity], hi: [Float] = [-.infinity, -.infinity, -.infinity]
        var i = 0
        while i + 2 < centroids.count {
            for a in 0..<3 { lo[a] = min(lo[a], centroids[i + a]); hi[a] = max(hi[a], centroids[i + a]) }
            i += 3
        }
        box = centroids.isEmpty ? [0, 0, 0, 0, 0, 0] : lo + hi
    }

    public var faceCount: Int { hidden.count }
    public var allHidden: Bool { hiddenCount == hidden.count && !hidden.isEmpty }

    /// Face centroids of a triangle mesh (positions xyz, triangle indices).
    public static func centroids(positions p: [Float], indices idx: [UInt32]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(idx.count)
        var t = 0
        let nv = p.count / 3
        while t + 2 < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            t += 3
            guard a < nv, b < nv, c < nv else { out += [.nan, .nan, .nan]; continue }
            out.append((p[a * 3] + p[b * 3] + p[c * 3]) / 3)
            out.append((p[a * 3 + 1] + p[b * 3 + 1] + p[c * 3 + 1]) / 3)
            out.append((p[a * 3 + 2] + p[b * 3 + 2] + p[c * 3 + 2]) / 3)
        }
        return out
    }

    /// The world box of this face set under alignment `al` (map → ARKit world).
    public func worldBox(_ al: Align4) -> [Float] {
        var lo: [Float] = [.infinity, .infinity, .infinity], hi: [Float] = [-.infinity, -.infinity, -.infinity]
        for xi in [0, 3] { for yi in [1, 4] { for zi in [2, 5] {
            let w = al.toArkit([Double(box[xi]), Double(box[yi]), Double(box[zi])])
            for a in 0..<3 { lo[a] = min(lo[a], Float(w[a])); hi[a] = max(hi[a], Float(w[a])) }
        } } }
        return lo + hi
    }

    /// Hide every face whose drawn place (map → world through `al`) is an observed cell. Sticky: hidden faces stay
    /// hidden. Skips the work when nothing new was marked near this mesh and the alignment barely moved.
    /// Returns the number of newly hidden faces.
    @discardableResult
    public mutating func update(grid g: DeviceCoverageGrid, align al: Align4, force: Bool = false) -> Int {
        let moved = testedAlign.map { Self.moved($0, al) } ?? true
        if !force && !moved && !g.changed(in: worldBox(al), since: testedGen) {
            testedGen = g.generation
            return 0
        }
        testedGen = g.generation
        testedAlign = al
        let c = Float(cos(al.yaw)), s = Float(sin(al.yaw))
        let ax = Float(al.x), ay = Float(al.y), az = Float(al.z)
        var n = 0
        var f = 0
        let cnt = hidden.count
        while f < cnt {
            if !hidden[f] {
                let qx = centroids[f * 3], qy = centroids[f * 3 + 1], qz = centroids[f * 3 + 2]
                if qx == qx {                                    // not NaN
                    // Align4.toArkit: [c·dx + s·dy, q.z − z, s·dx − c·dy]
                    let dx = qx - ax, dy = qy - ay
                    if g.contains(x: c * dx + s * dy, y: qz - az, z: s * dx - c * dy) {
                        hidden[f] = true
                        n += 1
                    }
                }
            }
            f += 1
        }
        hiddenCount += n
        return n
    }

    /// > 2 cm or > 0.3° between two alignments: the drawn faces moved, test again.
    static func moved(_ a: Align4, _ b: Align4) -> Bool {
        let d = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
        var dy = abs(a.yaw - b.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if dy > .pi { dy = 2 * .pi - dy }
        return d > 0.02 || dy > 0.3 * .pi / 180
    }

    /// Triangle indices with the hidden faces removed (same vertex buffer).
    public func keptIndices(_ idx: [UInt32]) -> [UInt32] {
        var out = [UInt32]()
        out.reserveCapacity(idx.count - hiddenCount * 3)
        var t = 0, f = 0
        while t + 2 < idx.count {
            if f >= hidden.count || !hidden[f] { out.append(idx[t]); out.append(idx[t + 1]); out.append(idx[t + 2]) }
            t += 3
            f += 1
        }
        return out
    }
}

/// When a masked mesh is worth rebuilding (a rebuild costs a MeshResource on the main thread).
public enum CoverageRebuild {
    /// Rebuild when at least `minFaces` more faces are hidden than drawn-hidden, or a share ≥ `minShare` of the mesh,
    /// or everything is hidden (the whole tile simply goes).
    public static func due(hidden: Int, applied: Int, faces: Int, minFaces: Int = 24, minShare: Double = 0.01) -> Bool {
        let d = hidden - applied
        guard d > 0 else { return false }
        if hidden == faces { return true }
        return d >= minFaces || Double(d) >= minShare * Double(max(1, faces))
    }
}
