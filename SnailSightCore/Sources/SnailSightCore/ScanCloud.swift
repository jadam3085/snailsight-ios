import Foundation

// SnailSight 12.27 live coloured point cloud (owner 2026-11-14: "why do Trimble SiteVision / home-scan apps show a
// coloured 3D point cloud instantly on an iPad while our map struggles?" — they accumulate ONE session's LiDAR depth +
// colour on the device). This is that accumulator, in the ARKit session frame (y up), pure Swift (Linux-tested,
// ScanCloudTests); the app feeds it ARKit sceneDepth + confidence + the camera image (Sources/Live/ScanCloudController)
// and draws it with Metal (Scan view: points over the camera in AR, an orbitable 3D view when paused).
//
//  - Voxel dedupe by range: 1.5 cm voxels under 1.5 m, 3 cm under 3 m, 6 cm beyond (the voxel sizes nest inside
//    0.96 m chunks). A finer observation of the same place replaces the coarser voxel; a coarser one never overwrites
//    finer detail.
//  - Quality from the 12.26 capture findings (CaptureQuality: low confidence 38 %, grazing 17 %, far 9 % of the map
//    disagreement): `good` = confidence 2, ≤ 2.5 m, |cos incidence| ≥ 0.3. Confidence 1, 2.5-4 m, or 0.15-0.3 incidence
//    = `faint` (drawn faint or hidden). Confidence 0, > maxRange, < 0.15 incidence = dropped.
//  - Memory governor (MemPlan.cloudMaxPoints / cloudKeepRadiusM): chunks beyond the keep radius go; over the point
//    budget the farthest chunks are decimated to 6 cm, then dropped. `estimatedBytes` is the `mb_scan_cloud` line.
//  - Coverage (ScanCoverage): 25 cm cells with good depth seen in ≥ 2 frames, per surface class (floor / ground, wall,
//    ceiling), for the Rescan coverage indicator.

public enum CloudQuality: UInt8, Comparable {
    case faint = 1, good = 2
    public static func < (a: CloudQuality, b: CloudQuality) -> Bool { a.rawValue < b.rawValue }
}

public struct ScanCloudConfig: Equatable {
    /// Voxel edge per level (each level is 2x the previous: they nest inside a chunk).
    public static let voxelM: [Float] = [0.015, 0.03, 0.06]
    public static let chunkM: Float = 0.96                       // 64 x 1.5 cm = 32 x 3 cm = 16 x 6 cm
    public var level0MaxM: Float = 1.5
    public var level1MaxM: Float = 3.0
    public var minRangeM: Float = 0.15
    public var goodMaxM: Float = Float(CaptureQuality.farM)     // 2.5 m
    public var maxRangeM: Float = 4.0
    public var goodCos: Float = Float(CaptureQuality.grazeCos)  // 0.3
    public var minCos: Float = 0.15
    /// Depth pixel stride (256 x 192 LiDAR depth: stride 2 = 12 k samples a frame).
    public var step = 2
    /// Running means stop at this weight so a voxel keeps adapting (moved chair, better colour later).
    public var maxWeight: UInt16 = 8
    public init() {}

    public func level(range r: Float) -> Int { r < level0MaxM ? 0 : (r < level1MaxM ? 1 : 2) }
}

/// One accumulated point (24 bytes).
public struct CloudPoint: Equatable {
    public var x: Float, y: Float, z: Float
    public var key: Int64
    public var r: UInt8, g: UInt8, b: UInt8
    public var q: UInt8
    public var n: UInt16
}

/// A LiDAR depth frame as the accumulator reads it.
public struct CloudFrameInput {
    public var depth: [Float]            // metres, row-major w x h (0 / non-finite = none)
    public var conf: [UInt8]?            // ARKit confidence 0 / 1 / 2, same size (nil = treated as 1)
    public var width: Int
    public var height: Int
    /// fx, fy, cx, cy at the DEPTH resolution (the camera intrinsics scaled by depth_w / image_w).
    public var K: [Float]
    /// camera → world, row-major 4x4, ARKit camera convention (x right, y up, looking down -z).
    public var T: [Float]
    /// RGB at (colorW x colorH), 3 bytes a pixel; the depth pixel (u, v) samples (u * colorW / w, v * colorH / h).
    public var rgb: [UInt8]?
    public var colorW: Int
    public var colorH: Int

    public init(depth: [Float], conf: [UInt8]?, width: Int, height: Int, K: [Float], T: [Float],
                rgb: [UInt8]? = nil, colorW: Int = 0, colorH: Int = 0) {
        self.depth = depth; self.conf = conf; self.width = width; self.height = height; self.K = K; self.T = T
        self.rgb = rgb; self.colorW = colorW; self.colorH = colorH
    }
}

public struct CloudIntegrateStats: Equatable {
    public var samples = 0
    public var added = 0
    public var merged = 0
    public var superseded = 0          // coarser voxels replaced by finer ones
    public var good = 0
    public var faint = 0
    public var droppedConf = 0
    public var droppedRange = 0
    public var droppedGraze = 0
    public init() {}
}

public struct ScanCloud {
    public var config: ScanCloudConfig

    struct Chunk {
        var points: [CloudPoint] = []
        var index: [Int64: Int32] = [:]
        /// level-2 cell key → bit per level present (stale bits only cost a lookup)
        var levels: [Int64: UInt8] = [:]
        var minLevel = 0                 // 2 after decimation (until the camera comes close again)
        var cx: Float = 0, cy: Float = 0, cz: Float = 0
    }

    private(set) var chunks: [Int64: Chunk] = [:]
    public private(set) var count = 0
    public private(set) var version = 0
    public private(set) var frames = 0
    public private(set) var evictedChunks = 0
    public private(set) var decimatedChunks = 0
    public private(set) var evictedPoints = 0
    public var coverage = ScanCoverage()

    public init(config: ScanCloudConfig = ScanCloudConfig()) { self.config = config }

    public var chunkCount: Int { chunks.count }
    public var goodCount: Int { var n = 0; for (_, c) in chunks { for p in c.points where p.q >= 2 { n += 1 } }; return n }

    /// Points + dictionary entries + chunk overhead (the `mb_scan_cloud` estimate; the GPU copy is the renderer's).
    public var estimatedBytes: Int {
        var levels = 0
        for (_, c) in chunks { levels += c.levels.count }
        return count * (MemoryLayout<CloudPoint>.stride + 20) + levels * 16 + chunks.count * 160 + coverage.estimatedBytes
    }

    public mutating func clear() {
        chunks = [:]
        count = 0
        version += 1
        coverage = ScanCoverage()
    }

    // MARK: keys

    @inline(__always) static func cell(_ v: Float, _ s: Float) -> Int64 { Int64((v / s).rounded(.down)) }

    @inline(__always) static func pack(_ level: Int, _ i: Int64, _ j: Int64, _ k: Int64) -> Int64 {
        let m: Int64 = 0xFFFFF
        return Int64(level) << 60 | (i & m) << 40 | (j & m) << 20 | (k & m)
    }

    @inline(__always) static func voxelKey(_ level: Int, _ x: Float, _ y: Float, _ z: Float) -> Int64 {
        let s = ScanCloudConfig.voxelM[level]
        return pack(level, cell(x, s), cell(y, s), cell(z, s))
    }

    @inline(__always) static func chunkKey(_ x: Float, _ y: Float, _ z: Float) -> Int64 {
        let s = ScanCloudConfig.chunkM
        return pack(3, cell(x, s), cell(y, s), cell(z, s))
    }

    // MARK: insert

    /// One world-frame observation. Returns what happened (for stats).
    enum InsertResult { case added, merged, skipped }

    @discardableResult
    mutating func insert(x: Float, y: Float, z: Float, r: UInt8, g: UInt8, b: UInt8, q: UInt8, level wanted: Int,
                         superseded: inout Int) -> InsertResult {
        let ck = Self.chunkKey(x, y, z)
        var c = chunks[ck] ?? {
            var n = Chunk()
            let s = ScanCloudConfig.chunkM
            n.cx = (Float(Self.cell(x, s)) + 0.5) * s; n.cy = (Float(Self.cell(y, s)) + 0.5) * s; n.cz = (Float(Self.cell(z, s)) + 0.5) * s
            return n
        }()
        let level = max(wanted, c.minLevel)
        let k2 = Self.voxelKey(2, x, y, z)
        let mask = c.levels[k2] ?? 0
        let key = Self.voxelKey(level, x, y, z)
        var result = InsertResult.skipped
        if let i = c.index[key] {
            var p = c.points[Int(i)]
            if q > p.q {                                   // better evidence: restart the mean from it
                p.x = x; p.y = y; p.z = z; p.r = r; p.g = g; p.b = b; p.q = q; p.n = 1
            } else if q == p.q {
                let n = Float(p.n), w = 1 / (n + 1)
                p.x += (x - p.x) * w; p.y += (y - p.y) * w; p.z += (z - p.z) * w
                p.r = UInt8((Float(p.r) * n + Float(r)) * w); p.g = UInt8((Float(p.g) * n + Float(g)) * w)
                p.b = UInt8((Float(p.b) * n + Float(b)) * w)
                if p.n < config.maxWeight { p.n += 1 }
            }
            c.points[Int(i)] = p
            result = .merged
        } else if mask & ((1 << UInt8(level)) - 1) != 0 {
            // a finer level already holds detail in this 6 cm cell: a coarser sample adds nothing
            result = .skipped
        } else {
            // finer than what is there: the coarser voxel(s) containing this point go
            if level < 2 {
                for l in (level + 1)...2 where mask & (1 << UInt8(l)) != 0 {
                    let ok = Self.voxelKey(l, x, y, z)
                    if let i = c.index[ok], c.points[Int(i)].q <= q {
                        Self.removeAt(&c, Int(i))
                        count -= 1
                        superseded += 1
                    }
                }
            }
            c.index[key] = Int32(c.points.count)
            c.points.append(CloudPoint(x: x, y: y, z: z, key: key, r: r, g: g, b: b, q: q, n: 1))
            c.levels[k2] = mask | (1 << UInt8(level))
            count += 1
            result = .added
        }
        chunks[ck] = c
        return result
    }

    static func removeAt(_ c: inout Chunk, _ i: Int) {
        let gone = c.points[i].key
        let last = c.points.count - 1
        if i != last {
            let moved = c.points[last]
            c.points[i] = moved
            c.index[moved.key] = Int32(i)
        }
        c.points.removeLast()
        c.index[gone] = nil
    }

    // MARK: integrate a depth frame

    /// Back-project a LiDAR frame (stride `config.step`) into the cloud. Pure; ~12 k samples at stride 2.
    @discardableResult
    public mutating func integrate(_ f: CloudFrameInput) -> CloudIntegrateStats {
        var st = CloudIntegrateStats()
        let w = f.width, h = f.height, step = max(1, config.step)
        guard w > step, h > step, f.depth.count == w * h, f.K.count == 4, f.T.count == 16, f.K[0] > 0, f.K[1] > 0 else { return st }
        let conf = f.conf.flatMap { $0.count == w * h ? $0 : nil }
        let rgb = f.rgb.flatMap { f.colorW > 0 && f.colorH > 0 && $0.count >= f.colorW * f.colorH * 3 ? $0 : nil }
        let fx = f.K[0], fy = f.K[1], cx = f.K[2], cy = f.K[3]
        let T = f.T
        let camY = T[7]
        frames += 1
        let frame = UInt32(truncatingIfNeeded: frames)
        var superseded = 0
        @inline(__always) func d(_ x: Int, _ y: Int) -> Float {
            let v = f.depth[y * w + x]
            return v.isFinite ? v : 0
        }
        var y = 0
        while y < h - step {
            var x = 0
            while x < w - step {
                let z = d(x, y)
                if z > 0 {
                    st.samples += 1
                    let c = conf.map { $0[y * w + x] } ?? 1
                    if c == 0 { st.droppedConf += 1; x += step; continue }
                    if z < config.minRangeM || z > config.maxRangeM { st.droppedRange += 1; x += step; continue }
                    // camera frame (OpenCV: x right, y down, z forward) for the incidence angle
                    let px = (Float(x) - cx) / fx * z, py = (Float(y) - cy) / fy * z
                    let zx = d(x + step, y), zy = d(x, y + step)
                    var cosI: Float = -1                                  // unknown (occlusion edge / no neighbour)
                    var nCam: (Float, Float, Float)?
                    if zx > 0, zy > 0, abs(zx - z) < 0.35 * max(z, zx), abs(zy - z) < 0.35 * max(z, zy) {
                        let ax = (Float(x + step) - cx) / fx * zx - px, ay = (Float(y) - cy) / fy * zx - py, az = zx - z
                        let bx = (Float(x) - cx) / fx * zy - px, by = (Float(y + step) - cy) / fy * zy - py, bz = zy - z
                        var nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx
                        let nn = (nx * nx + ny * ny + nz * nz).squareRoot()
                        let pn = (px * px + py * py + z * z).squareRoot()
                        if nn > 0, pn > 0 {
                            let dot = nx * px + ny * py + nz * z
                            cosI = abs(dot) / (nn * pn)
                            if dot > 0 { nx = -nx; ny = -ny; nz = -nz }           // face the camera
                            nCam = (nx / nn, ny / nn, nz / nn)
                        }
                    }
                    if cosI >= 0, cosI < config.minCos { st.droppedGraze += 1; x += step; continue }
                    let good = c >= 2 && z <= config.goodMaxM && (cosI < 0 || cosI >= config.goodCos)
                    let q: UInt8 = good ? 2 : 1
                    if good { st.good += 1 } else { st.faint += 1 }
                    // ARKit camera: (x, -y, -z) of the OpenCV point, then camera → world
                    let ax = px, ay = -py, az = -z
                    let wx = T[0] * ax + T[1] * ay + T[2] * az + T[3]
                    let wy = T[4] * ax + T[5] * ay + T[6] * az + T[7]
                    let wz = T[8] * ax + T[9] * ay + T[10] * az + T[11]
                    var r: UInt8 = 200, g: UInt8 = 200, b: UInt8 = 200
                    if let rgb {
                        let u = min(f.colorW - 1, x * f.colorW / w), v = min(f.colorH - 1, y * f.colorH / h)
                        let o = (v * f.colorW + u) * 3
                        r = rgb[o]; g = rgb[o + 1]; b = rgb[o + 2]
                    }
                    switch insert(x: wx, y: wy, z: wz, r: r, g: g, b: b, q: q, level: config.level(range: z),
                                  superseded: &superseded) {
                    case .added: st.added += 1
                    case .merged: st.merged += 1
                    case .skipped: break
                    }
                    // world up component of the ARKit-camera normal (n.x, -n.y, -n.z)
                    let up: Float? = nCam.map { n in T[4] * n.0 - T[5] * n.1 - T[6] * n.2 }
                    coverage.observe(x: wx, y: wy, z: wz, upDot: up, camY: camY, good: good, frame: frame)
                }
                x += step
            }
            y += step
        }
        st.superseded = superseded
        if st.added > 0 || st.merged > 0 || superseded > 0 { version += 1 }
        return st
    }

    // MARK: memory governor

    public struct EnforceResult: Equatable {
        public var evictedChunks = 0
        public var evictedPoints = 0
        public var decimatedChunks = 0
        public init() {}
    }

    /// Chunks beyond `keepRadiusM` (horizontal, ARKit x / z) go; over `maxPoints` the farthest chunks (≥ 3 m away)
    /// are decimated to 6 cm, then the farthest are dropped. maxPoints 0 = clear.
    @discardableResult
    public mutating func enforce(camX: Float, camY: Float, camZ: Float, maxPoints: Int, keepRadiusM: Float) -> EnforceResult {
        var res = EnforceResult()
        if maxPoints <= 0 {
            if count > 0 { res.evictedPoints = count; res.evictedChunks = chunks.count; clear() }
            return res
        }
        @inline(__always) func d2(_ c: Chunk) -> Float { (c.cx - camX) * (c.cx - camX) + (c.cz - camZ) * (c.cz - camZ) }
        let r2 = keepRadiusM * keepRadiusM
        for (k, c) in chunks {
            let dd = d2(c)
            if dd > r2 {
                count -= c.points.count
                res.evictedPoints += c.points.count
                res.evictedChunks += 1
                chunks[k] = nil
            } else if c.minLevel > 0, dd < 4 {                // the camera is back near a decimated chunk: detail again
                chunks[k]?.minLevel = 0
            }
        }
        if count > maxPoints {
            let order = chunks.map { (k: $0.key, d: d2($0.value), lvl: $0.value.minLevel) }.sorted { $0.d > $1.d }
            for o in order where count > maxPoints && o.lvl < 2 && o.d > 9 {
                guard var c = chunks[o.k] else { continue }
                let before = c.points.count
                Self.decimate(&c)
                count -= before - c.points.count
                chunks[o.k] = c
                res.decimatedChunks += 1
            }
            for o in order where count > maxPoints {
                guard let c = chunks[o.k] else { continue }
                count -= c.points.count
                res.evictedPoints += c.points.count
                res.evictedChunks += 1
                chunks[o.k] = nil
            }
        }
        coverage.prune(camX: camX, camZ: camZ, radius: max(keepRadiusM, 8) * 1.5)
        evictedChunks += res.evictedChunks
        evictedPoints += res.evictedPoints
        decimatedChunks += res.decimatedChunks
        if res.evictedPoints > 0 || res.decimatedChunks > 0 { version += 1 }
        return res
    }

    /// Re-voxel a chunk at 6 cm (weighted means; the best quality in the cell wins).
    static func decimate(_ c: inout Chunk) {
        var out: [CloudPoint] = []
        var idx: [Int64: Int32] = [:]
        var levels: [Int64: UInt8] = [:]
        for p in c.points {
            let k = voxelKey(2, p.x, p.y, p.z)
            if let i = idx[k] {
                var a = out[Int(i)]
                if p.q > a.q { a = CloudPoint(x: p.x, y: p.y, z: p.z, key: k, r: p.r, g: p.g, b: p.b, q: p.q, n: p.n) }
                else if p.q == a.q {
                    let wa = Float(a.n), wp = Float(p.n), w = 1 / (wa + wp)
                    a.x = (a.x * wa + p.x * wp) * w; a.y = (a.y * wa + p.y * wp) * w; a.z = (a.z * wa + p.z * wp) * w
                    a.r = UInt8((Float(a.r) * wa + Float(p.r) * wp) * w); a.g = UInt8((Float(a.g) * wa + Float(p.g) * wp) * w)
                    a.b = UInt8((Float(a.b) * wa + Float(p.b) * wp) * w)
                    a.n = UInt16(min(Float(UInt16.max), wa + wp))
                }
                out[Int(i)] = a
            } else {
                idx[k] = Int32(out.count)
                out.append(CloudPoint(x: p.x, y: p.y, z: p.z, key: k, r: p.r, g: p.g, b: p.b, q: p.q, n: p.n))
                levels[k] = 1 << 2
            }
        }
        c.points = out
        c.index = idx
        c.levels = levels
        c.minLevel = 2
    }

    // MARK: export for the GPU

    /// Bytes per exported vertex: float x, y, z + RGBA8 (the Metal `CloudVertex`, packed_float3 + uchar4).
    public static let vertexStride = 16

    /// Writes up to `capacity` vertices; faint points get alpha `faintAlpha` (0 = left out). Returns the count.
    public func export(into ptr: UnsafeMutableRawPointer, capacity: Int, faintAlpha: UInt8 = 90) -> Int {
        var n = 0
        let o = ptr
        for (_, c) in chunks {
            for p in c.points {
                if n >= capacity { return n }
                let a: UInt8 = p.q >= 2 ? 255 : faintAlpha
                if a == 0 { continue }
                let base = o.advanced(by: n * Self.vertexStride)
                base.storeBytes(of: p.x, toByteOffset: 0, as: Float.self)
                base.storeBytes(of: p.y, toByteOffset: 4, as: Float.self)
                base.storeBytes(of: p.z, toByteOffset: 8, as: Float.self)
                base.storeBytes(of: p.r, toByteOffset: 12, as: UInt8.self)
                base.storeBytes(of: p.g, toByteOffset: 13, as: UInt8.self)
                base.storeBytes(of: p.b, toByteOffset: 14, as: UInt8.self)
                base.storeBytes(of: a, toByteOffset: 15, as: UInt8.self)
                n += 1
            }
        }
        return n
    }

    /// All points (tests, the orbit view's centre).
    public var points: [CloudPoint] { var a: [CloudPoint] = []; a.reserveCapacity(count); for (_, c) in chunks { a += c.points }; return a }

    /// Bounding box centre + radius (orbit view framing). nil when empty.
    public var bounds: (center: [Float], radius: Float)? {
        guard count > 0 else { return nil }
        var lo: [Float] = [.infinity, .infinity, .infinity], hi: [Float] = [-.infinity, -.infinity, -.infinity]
        for (_, c) in chunks where !c.points.isEmpty {
            let h = ScanCloudConfig.chunkM / 2
            lo[0] = min(lo[0], c.cx - h); lo[1] = min(lo[1], c.cy - h); lo[2] = min(lo[2], c.cz - h)
            hi[0] = max(hi[0], c.cx + h); hi[1] = max(hi[1], c.cy + h); hi[2] = max(hi[2], c.cz + h)
        }
        let ctr = [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2]
        let dx = hi[0] - lo[0], dy = hi[1] - lo[1], dz = hi[2] - lo[2]
        return (ctr, max(0.5, (dx * dx + dy * dy + dz * dz).squareRoot() / 2))
    }
}

// MARK: - coverage

/// The Rescan coverage indicator: 25 cm cells (ARKit world) with depth seen; a cell is `covered` once good-quality
/// depth landed in it in ≥ 2 frames. Surface class from the normal: up-facing below the camera = floor (outdoors:
/// ground), down-facing above = ceiling, else wall (outdoors: walls / fences / objects).
public struct ScanCoverage: Equatable {
    public static let cellM: Float = 0.25
    public static let goodFrames: UInt8 = 2
    public static let maxCells = 250_000

    public enum Surface: Int, CaseIterable { case floor = 0, wall, ceiling, other }

    struct Cell: Equatable {
        var seenFrame: UInt32 = 0
        var goodFrame: UInt32 = 0
        var good: UInt8 = 0
        var frames: UInt8 = 0
        var cls: [UInt16] = [0, 0, 0, 0]
    }

    private(set) var cells: [Int64: Cell] = [:]
    public private(set) var samples = 0
    public private(set) var goodSamples = 0
    public init() {}

    public var count: Int { cells.count }
    public var estimatedBytes: Int { cells.count * 64 }

    static func key(_ x: Float, _ y: Float, _ z: Float) -> Int64 {
        ScanCloud.pack(0, ScanCloud.cell(x, cellM), ScanCloud.cell(y, cellM), ScanCloud.cell(z, cellM))
    }

    static func unpack(_ k: Int64) -> (Int64, Int64, Int64) {
        func s(_ v: Int64) -> Int64 { v & 0x80000 != 0 ? v - 0x100000 : v }
        return (s(k >> 40 & 0xFFFFF), s(k >> 20 & 0xFFFFF), s(k & 0xFFFFF))
    }

    /// `upDot` = world-normal · up (nil = no normal).
    public mutating func observe(x: Float, y: Float, z: Float, upDot: Float?, camY: Float, good: Bool, frame: UInt32) {
        samples += 1
        if good { goodSamples += 1 }
        let k = Self.key(x, y, z)
        if cells[k] == nil, cells.count >= Self.maxCells { return }
        var c = cells[k] ?? Cell()
        if c.seenFrame != frame { c.seenFrame = frame; if c.frames < 255 { c.frames += 1 } }
        if good, c.goodFrame != frame { c.goodFrame = frame; if c.good < 255 { c.good += 1 } }
        let s: Surface
        if let u = upDot {
            if u > 0.7, y < camY { s = .floor } else if u < -0.7, y > camY { s = .ceiling } else if abs(u) < 0.5 { s = .wall } else { s = .other }
        } else { s = .other }
        if c.cls[s.rawValue] < UInt16.max { c.cls[s.rawValue] += 1 }
        cells[k] = c
    }

    static func surface(_ c: Cell) -> Surface {
        var best = 3, n: UInt16 = 0
        for i in 0..<3 where c.cls[i] > n { n = c.cls[i]; best = i }
        return Surface(rawValue: best) ?? .other
    }

    public struct Summary: Equatable {
        public var seen: [Int] = [0, 0, 0, 0]          // per Surface
        public var covered: [Int] = [0, 0, 0, 0]
        public var cells = 0
        public var coveredCells = 0
        public var goodShare = 0.0                    // good samples / all samples
        public init() {}
        public func pct(_ s: Surface) -> Int? { seen[s.rawValue] >= 4 ? Int((Double(covered[s.rawValue]) / Double(seen[s.rawValue]) * 100).rounded()) : nil }
        public var coveragePct: Int { cells > 0 ? Int((Double(coveredCells) / Double(cells) * 100).rounded()) : 0 }
        /// Surface area with good depth (m², 25 cm cells).
        public var coveredM2: Double { Double(coveredCells) * Double(ScanCoverage.cellM * ScanCoverage.cellM) }

        /// "Floor 80 % · Walls 55 % · Ceiling 20 %" (outdoors: Ground / Walls+objects / Overhead).
        public func line(outdoor: Bool) -> String {
            var parts: [String] = []
            let names = outdoor ? ["Ground", "Walls + objects", "Overhead"] : ["Floor", "Walls", "Ceiling"]
            for s in [Surface.floor, .wall, .ceiling] {
                if let p = pct(s) { parts.append("\(names[s.rawValue]) \(p) %") }
                else if !(outdoor && s == .ceiling) { parts.append("\(names[s.rawValue]) –") }
            }
            return parts.joined(separator: " · ")
        }

        public var json: [String: Any] {
            ["coverage_pct": coveragePct, "covered_m2": (coveredM2 * 10).rounded() / 10, "good_share": (goodShare * 1000).rounded() / 1000,
             "cells": cells, "floor_pct": pct(.floor) ?? -1, "wall_pct": pct(.wall) ?? -1, "ceiling_pct": pct(.ceiling) ?? -1]
        }
    }

    public var summary: Summary {
        var s = Summary()
        for (_, c) in cells {
            let sf = Self.surface(c)
            s.seen[sf.rawValue] += 1
            s.cells += 1
            if c.good >= Self.goodFrames { s.covered[sf.rawValue] += 1; s.coveredCells += 1 }
        }
        s.goodShare = samples > 0 ? Double(goodSamples) / Double(samples) : 0
        return s
    }

    /// Top-down mini map around the camera: n x n cells of `spanM` metres; 0 = nothing, 1 = seen (weak), 2 = covered.
    /// Row 0 = ahead is not applied (world-aligned: row = +z / south, col = +x).
    public func topDown(camX: Float, camZ: Float, spanM: Float = 8, n: Int = 24) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n * n)
        let s = spanM / Float(n), x0 = camX - spanM / 2, z0 = camZ - spanM / 2
        for (k, c) in cells {
            let (i, _, kk) = Self.unpack(k)
            let wx = (Float(i) + 0.5) * Self.cellM, wz = (Float(kk) + 0.5) * Self.cellM
            let col = Int(((wx - x0) / s).rounded(.down)), row = Int(((wz - z0) / s).rounded(.down))
            guard col >= 0, col < n, row >= 0, row < n else { continue }
            let v: UInt8 = c.good >= Self.goodFrames ? 2 : 1
            if v > out[row * n + col] { out[row * n + col] = v }
        }
        return out
    }

    /// Spatial cap: cells beyond `radius` (horizontal) go when over maxCells / 2.
    public mutating func prune(camX: Float, camZ: Float, radius: Float) {
        guard cells.count > Self.maxCells / 2 else { return }
        let r2 = radius * radius
        for (k, _) in cells {
            let (i, _, kk) = Self.unpack(k)
            let dx = (Float(i) + 0.5) * Self.cellM - camX, dz = (Float(kk) + 0.5) * Self.cellM - camZ
            if dx * dx + dz * dz > r2 { cells[k] = nil }
        }
    }
}
