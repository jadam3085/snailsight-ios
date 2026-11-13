import Foundation

// SnailSight 12.18: Layer B consumer (live world plan P4, API §6b.7 "Live surface, Layer B: block-mesh deltas").
// The server's live, editable surface is a hashed TSDF in the map frame; it is sent per 4 m tile as deltas of 0.40 m
// blocks on the live downlink (layer `surface`, JSON transport here):
//   {"type":"tile","layer":"surface","key":"0/-2/1","level","tx","ty","ver":{base_version,live_seq},"since":int|null,
//    "voxel_m":0.04,"block_m":0.4,"blocks":[{"b":[bx,by,bz],"s":"surface"|"empty","rev","nv","nt","tracked","src",
//    "data":base64(<u32 nv><u32 nt> f32 xyz[3nv] map frame, u32 idx[3nt]),"rgb":base64 u8[3nv]?}…],
//    "removed":[[bx,by,bz]…],"hw","hw_wall","stages":{capture_to_commit_ms}?}
// Rules (§6b.7 "Versions and deltas"): since == held (or older) → apply; since newer than held → gap: ignore, fetch the
// tile in full; since null → drop the tile's blocks, then apply. `surface` blocks draw their mesh; `surface` AND `empty`
// cubes hide the base faces inside them; `removed` blocks are dropped (base shows again). Epoch change = start over.
// 12.24 (live 0.12, API §6b.7 `hm`): a block may carry a per-voxel supersede mask, base64 of 125 bytes = 1000 bits,
// bit i = local voxel ix*100 + iy*10 + iz (4 cm voxels of the 0.4 m block), byte i >> 3, LSB first. Such a block hides
// ONLY the base inside its set voxels (the rest of its base stays drawn); no mask = the whole cube, as before. The
// subscribe says `"hmask": 1` so the server sends masked blocks at all (older apps never get them).
// Pure, Linux-tested (LayerBTests).

/// Block index [bx, by, bz] packed (21 bits each, offset 2^20).
public struct BlockKey: Hashable, Comparable {
    public let x: Int32, y: Int32, z: Int32
    public init(_ x: Int, _ y: Int, _ z: Int) { self.x = Int32(x); self.y = Int32(y); self.z = Int32(z) }
    public var packed: Int64 { DeviceCoverageGrid.key(x, y, z) }
    public static func < (a: BlockKey, b: BlockKey) -> Bool { (a.z, a.y, a.x) < (b.z, b.y, b.x) }
}

public struct SurfaceBlock: Equatable {
    public var key: BlockKey
    public var surface: Bool                  // false = "empty" (seen through: hides the base, draws nothing)
    public var rev: Int
    public var tracked: Int
    public var settled: Bool
    public var mesh: FlatMesh?
    public var rgb: [UInt8]?
    /// 12.24: per-voxel supersede mask (125 bytes); nil = the whole cube hides the base.
    public var hideMask: [UInt8]? = nil
}

/// 12.24: the `hm` voxel mask of a Layer B block (API §6b.7, live 0.12).
public enum HideMask {
    public static let voxels = 10
    public static let bytes = 125
    /// base64 → 125 bytes (nil when malformed: the block then hides its whole cube, the safe old rule).
    public static func decode(_ s: String?) -> [UInt8]? {
        guard let s, let d = Data(base64Encoded: s), d.count >= bytes else { return nil }
        return [UInt8](d.prefix(bytes))
    }
    /// Is local voxel (ix, iy, iz) set?
    @inline(__always)
    public static func bit(_ m: [UInt8], _ ix: Int, _ iy: Int, _ iz: Int) -> Bool {
        let i = ix * 100 + iy * 10 + iz
        return (m[i >> 3] >> UInt8(i & 7)) & 1 == 1
    }
    /// Local voxel of a map coordinate inside block index b (clamped to 0...9).
    @inline(__always)
    public static func local(_ v: Float, block b: Int32, blockM: Float) -> Int {
        let q = Int(((v / blockM - Float(b)) * Float(voxels)).rounded(.down))
        return min(max(q, 0), voxels - 1)
    }
}

/// One decoded `surface` tile frame.
public struct SurfaceFrame: Equatable {
    public var key: String
    public var level: Int
    public var tx: Int
    public var ty: Int
    public var ver: TileVer
    public var since: Int?
    public var blockM: Double
    public var blocks: [SurfaceBlock]
    public var removed: [BlockKey]
    public var hwWall: Double?
    public var agents: [String]
    public var captureToCommitMs: Double?
    /// 12.26: the frame came as ssq1 (WireQ), for the downlink stats.
    public var ssq1 = false

    struct RawBlock: Decodable {
        var b: [Int]
        var s: String
        var rev: Int?
        var tracked: Int?
        var src: String?
        var data: String?
        var rgb: String?
        var hm: String?
        var nv: Int?                          // 12.26 ssq1: vertex count (records exist for nv > 0 only)
    }

    struct Raw: Decodable {
        var type: String?
        var layer: String?
        var key: String
        var level: Int?
        var tx: Int?
        var ty: Int?
        var ver: TileVer?
        var since: Int?
        var block_m: Double?
        var blocks: [RawBlock]?
        var removed: [[Int]]?
        var hw: [String: Int]?
        var hw_wall: Double?
        var stages: [String: Double]?
        // 12.26 ssq1 (WireQ): enc, block table, quantised meshes, quantum, colour bin
        var enc: String?
        var bt: String?
        var q: String?
        var q_m: Double?
        var cq: Int?
    }

    /// Is this downlink message a Layer B tile? (cheap check before the full decode)
    public static func isSurface(_ data: Data) -> Bool {
        guard data.count > 30 else { return false }
        let head = data.prefix(400)
        return head.range(of: Data(#""layer":"surface""#.utf8)) != nil
    }

    public static func parse(_ data: Data) -> SurfaceFrame? {
        guard let r = try? JSONDecoder().decode(Raw.self, from: data), r.type == "tile", r.layer == "surface" else { return nil }
        let p = r.key.split(separator: "/").compactMap { Int($0) }
        let blockM = r.block_m ?? 0.4
        // 12.26 ssq1: the block table and every block mesh come packed (WireQ); decoded = the f32 values exactly
        var raws = r.blocks ?? []
        var qrec: [Int: WireQ.Record] = [:]          // index in raws → decoded mesh
        if r.enc == WireQ.enc {
            guard let bt = r.bt.flatMap({ Data(base64Encoded: $0) }),
                  let tab = try? Inflate.zlib(bt), let list = try? JSONDecoder().decode([RawBlock].self, from: tab)
            else { return nil }
            raws = list
            let withMesh = raws.indices.filter { (raws[$0].nv ?? 0) > 0 && raws[$0].b.count == 3 }
            if !withMesh.isEmpty {
                guard let qd = r.q.flatMap({ Data(base64Encoded: $0) }),
                      let recs = try? WireQ.unpack(qd, origins: withMesh.map { i in raws[i].b.map { Double($0) * blockM } },
                                                   qm: r.q_m ?? 0.001, cq: r.cq ?? 4),
                      recs.count == withMesh.count else { return nil }
                for (k, i) in withMesh.enumerated() { qrec[i] = recs[k] }
            }
        }
        var blocks: [SurfaceBlock] = []
        for (bi, b) in raws.enumerated() where b.b.count == 3 {
            let surf = b.s == "surface"
            var mesh: FlatMesh?
            var rgb: [UInt8]?
            if let rec = qrec[bi] {
                if surf { mesh = rec.mesh; rgb = rec.rgb }
            } else if surf, let d = b.data { mesh = LiveMeshTile.decode(enc: "f32", base64: d) }
            if rgb == nil, let c = b.rgb, let d = Data(base64Encoded: c), let m = mesh, d.count == m.vertexCount * 3 { rgb = [UInt8](d) }
            blocks.append(SurfaceBlock(key: BlockKey(b.b[0], b.b[1], b.b[2]), surface: surf, rev: b.rev ?? 0,
                                       tracked: b.tracked ?? 0, settled: b.src == "settled", mesh: mesh, rgb: rgb,
                                       hideMask: HideMask.decode(b.hm)))
        }
        let agents = Array(Set((r.hw ?? [:]).keys.map { k in k.split(separator: "/").first.map(String.init) ?? k })).sorted()
        var f = SurfaceFrame(key: r.key, level: r.level ?? (p.first ?? 0), tx: r.tx ?? (p.count == 3 ? p[1] : 0),
                            ty: r.ty ?? (p.count == 3 ? p[2] : 0), ver: r.ver ?? TileVer(base: 0, seq: 0), since: r.since,
                            blockM: blockM, blocks: blocks,
                            removed: (r.removed ?? []).filter { $0.count == 3 }.map { BlockKey($0[0], $0[1], $0[2]) },
                            hwWall: r.hw_wall, agents: agents, captureToCommitMs: r.stages?["capture_to_commit_ms"])
        f.ssq1 = r.enc == WireQ.enc
        return f
    }
}

/// What the app holds of Layer B: per tile its live_seq and blocks.
public struct LayerBStore {
    public struct Tile: Equatable {
        public var key: String
        public var level: Int
        public var tx: Int
        public var ty: Int
        public var ver: TileVer
        public var blocks: [BlockKey: SurfaceBlock] = [:]
        public var changedAt: Double = 0
        public var agents: [String] = []
        public var surfaceCount: Int { blocks.values.filter(\.surface).count }
    }

    public enum Applied: Equatable {
        /// applied: the blocks whose state changed (drawn / hidden cubes), whether it was a full replacement
        case applied(changed: Set<BlockKey>, full: Bool)
        /// a missed delta: re-fetch this tile in full
        case gap(held: Int?, since: Int)
    }

    public private(set) var tiles: [String: Tile] = [:]
    public private(set) var blockM: Double = 0.4
    public private(set) var epoch: String?
    /// Packed keys of every block present (surface or empty) = cubes where the base is hidden.
    public private(set) var superseded = Set<Int64>()
    /// 12.24: packed key → voxel mask, for the present blocks that hide only part of their cube.
    public private(set) var masks: [Int64: [UInt8]] = [:]
    public private(set) var frames = 0
    public private(set) var gaps = 0
    public init() {}

    public mutating func setEpoch(_ e: String?) {
        guard let e, e != epoch else { return }
        if epoch != nil { reset() }
        epoch = e
    }

    public mutating func reset() {
        tiles.removeAll()
        superseded.removeAll()
        masks.removeAll()
    }

    public mutating func apply(_ f: SurfaceFrame, now: Double) -> Applied {
        frames += 1
        blockM = f.blockM
        let held = tiles[f.key]?.ver
        if let s = f.since {
            guard let h = held, h.base == f.ver.base, s <= h.seq else {
                gaps += 1
                return .gap(held: held?.seq, since: s)
            }
        }
        var t = tiles[f.key] ?? Tile(key: f.key, level: f.level, tx: f.tx, ty: f.ty, ver: f.ver)
        var changed = Set<BlockKey>()
        if f.since == nil {
            for k in t.blocks.keys { changed.insert(k); superseded.remove(k.packed); masks.removeValue(forKey: k.packed) }
            t.blocks.removeAll()
        }
        for k in f.removed where t.blocks.removeValue(forKey: k) != nil {
            changed.insert(k)
            superseded.remove(k.packed)
            masks.removeValue(forKey: k.packed)
        }
        for b in f.blocks {
            t.blocks[b.key] = b
            superseded.insert(b.key.packed)
            if let m = b.hideMask { masks[b.key.packed] = m } else { masks.removeValue(forKey: b.key.packed) }
            changed.insert(b.key)
        }
        t.ver = f.ver
        t.level = f.level
        t.changedAt = now
        t.agents = f.agents
        tiles[f.key] = t
        return .applied(changed: changed, full: f.since == nil)
    }

    /// 12.20 spatial LRU: drop a far tile (its cubes stop hiding base faces; a resubscribe gets it back in full because
    /// it is no longer in `held`). Returns the blocks that changed.
    @discardableResult
    public mutating func forget(_ key: String) -> Set<BlockKey> {
        guard let t = tiles.removeValue(forKey: key) else { return [] }
        for k in t.blocks.keys { superseded.remove(k.packed); masks.removeValue(forKey: k.packed) }
        return Set(t.blocks.keys)
    }

    /// Centre (map x, y) of a tile (4 m squares).
    public func centre(_ key: String) -> (x: Double, y: Double)? {
        guard let t = tiles[key] else { return nil }
        return ((Double(t.tx) + 0.5) * 4, (Double(t.ty) + 0.5) * 4)
    }

    /// Estimated bytes of the blocks' meshes and colour.
    public var estimatedBytes: Int {
        var n = superseded.count * 9 + masks.count * (HideMask.bytes + 16)
        for t in tiles.values {
            for b in t.blocks.values {
                n += 64
                if let m = b.mesh { n += (m.positions.count + m.indices.count) * 4 }
                if let c = b.rgb { n += c.count }
            }
        }
        return n
    }

    /// `since.tiles.surface` for a (re)subscribe: {key: ver}.
    public var held: [String: TileVer] { tiles.mapValues(\.ver) }

    /// Does Layer B hide the base at this map point? Inside a held block (surface or empty): yes, unless the block has
    /// a voxel mask (12.24) and the point's voxel is not set.
    public func supersedes(x: Float, y: Float, z: Float) -> Bool {
        guard !superseded.isEmpty else { return false }
        let m = Float(blockM)
        let bx = Int32((x / m).rounded(.down)), by = Int32((y / m).rounded(.down)), bz = Int32((z / m).rounded(.down))
        let k = DeviceCoverageGrid.key(bx, by, bz)
        guard superseded.contains(k) else { return false }
        guard let hm = masks[k] else { return true }
        return HideMask.bit(hm, HideMask.local(x, block: bx, blockM: m), HideMask.local(y, block: by, blockM: m),
                            HideMask.local(z, block: bz, blockM: m))
    }

    /// 12.24: held blocks that hide only part of their cube.
    public var maskedBlocks: Int { masks.count }

    /// The tile's surface blocks as one mesh (map frame) + per-vertex colour (grey 150 where a block has none).
    public func tileMesh(_ key: String) -> (mesh: FlatMesh, rgb: [UInt8]?)? {
        guard let t = tiles[key] else { return nil }
        var pos = [Float](), idx = [UInt32](), rgb = [UInt8]()
        var anyColour = false
        for k in t.blocks.keys.sorted() {
            guard let b = t.blocks[k], b.surface, let m = b.mesh else { continue }
            let off = UInt32(pos.count / 3)
            pos += m.positions
            idx += m.indices.map { $0 + off }
            if let c = b.rgb { rgb += c; anyColour = true } else { rgb += [UInt8](repeating: 150, count: m.vertexCount * 3) }
        }
        return (FlatMesh(positions: pos, indices: idx), anyColour ? rgb : nil)
    }

    /// Faces of a mesh (centroids, map frame) inside superseded cubes.
    public func hiddenFaces(centroids c: [Float]) -> (mask: [Bool], count: Int) {
        var mask = [Bool](repeating: false, count: c.count / 3)
        guard !superseded.isEmpty else { return (mask, 0) }
        var n = 0
        for f in 0..<mask.count {
            let x = c[f * 3]
            if x == x, supersedes(x: x, y: c[f * 3 + 1], z: c[f * 3 + 2]) { mask[f] = true; n += 1 }
        }
        return (mask, n)
    }

    public var blockCount: Int { superseded.count }
    public var surfaceBlocks: Int { tiles.values.reduce(0) { $0 + $1.surfaceCount } }
}
