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

    struct RawBlock: Decodable {
        var b: [Int]
        var s: String
        var rev: Int?
        var tracked: Int?
        var src: String?
        var data: String?
        var rgb: String?
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
        var blocks: [SurfaceBlock] = []
        for b in r.blocks ?? [] where b.b.count == 3 {
            let surf = b.s == "surface"
            var mesh: FlatMesh?
            if surf, let d = b.data { mesh = LiveMeshTile.decode(enc: "f32", base64: d) }
            var rgb: [UInt8]?
            if let c = b.rgb, let d = Data(base64Encoded: c), let m = mesh, d.count == m.vertexCount * 3 { rgb = [UInt8](d) }
            blocks.append(SurfaceBlock(key: BlockKey(b.b[0], b.b[1], b.b[2]), surface: surf, rev: b.rev ?? 0,
                                       tracked: b.tracked ?? 0, settled: b.src == "settled", mesh: mesh, rgb: rgb))
        }
        let agents = Array(Set((r.hw ?? [:]).keys.map { k in k.split(separator: "/").first.map(String.init) ?? k })).sorted()
        return SurfaceFrame(key: r.key, level: r.level ?? (p.first ?? 0), tx: r.tx ?? (p.count == 3 ? p[1] : 0),
                            ty: r.ty ?? (p.count == 3 ? p[2] : 0), ver: r.ver ?? TileVer(base: 0, seq: 0), since: r.since,
                            blockM: r.block_m ?? 0.4, blocks: blocks,
                            removed: (r.removed ?? []).filter { $0.count == 3 }.map { BlockKey($0[0], $0[1], $0[2]) },
                            hwWall: r.hw_wall, agents: agents, captureToCommitMs: r.stages?["capture_to_commit_ms"])
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
            for k in t.blocks.keys { changed.insert(k); superseded.remove(k.packed) }
            t.blocks.removeAll()
        }
        for k in f.removed where t.blocks.removeValue(forKey: k) != nil {
            changed.insert(k)
            superseded.remove(k.packed)
        }
        for b in f.blocks {
            t.blocks[b.key] = b
            superseded.insert(b.key.packed)
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
        for k in t.blocks.keys { superseded.remove(k.packed) }
        return Set(t.blocks.keys)
    }

    /// Centre (map x, y) of a tile (4 m squares).
    public func centre(_ key: String) -> (x: Double, y: Double)? {
        guard let t = tiles[key] else { return nil }
        return ((Double(t.tx) + 0.5) * 4, (Double(t.ty) + 0.5) * 4)
    }

    /// Estimated bytes of the blocks' meshes and colour.
    public var estimatedBytes: Int {
        var n = superseded.count * 9
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

    /// Is the map point inside a block Layer B holds (surface or empty)?
    public func supersedes(x: Float, y: Float, z: Float) -> Bool {
        guard !superseded.isEmpty else { return false }
        let m = Float(blockM)
        return superseded.contains(DeviceCoverageGrid.key(Int32((x / m).rounded(.down)), Int32((y / m).rounded(.down)),
                                                          Int32((z / m).rounded(.down))))
    }

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
