import Foundation

// SnailSight 12.0 "Mesh (live)": ONE feed of the mesh as it is being made, for AR and the Map.
// - Live tiles (API §6b.1, 4 m squares, 5 cm untextured TSDF surface) arrive on the downlink for EVERY placed agent:
//   this phone's own walk (Live map on), other phones, replays, sim rovers / drones. A tile rebuilt again (newer `ver`)
//   is applied in place (same key, new mesh). `hw` names the streams fused into it, so the feed knows whose walk built it.
// - Base tiles (M4 tile sync, API §5.13) swapped in place by TileStreamer are noted here too (`noteBase`), so the same
//   "fresh" highlight shows where the shared map just changed.
// - Freshness: a tile that just arrived or changed is "fresh" for `fadeS` seconds; AR and the Map draw it brighter in
//   three literal steps (2 fresh, 1 fading, 0 settled) so materials are swapped at most twice per arrival.
// - The Map draws each live tile as a small top-down raster (TilePlanRaster), built once per arrival.
// Pure, Linux-tested (LiveMeshFeedTests, and a replay of a real downlink capture when SNAILSIGHT_DOWNLINK_REPLAY is set).

/// The header fields of a downlink `tile` message the feed needs (json transport; the binary SSTL header is the same).
public struct LiveTileHeader: Decodable, Equatable {
    public var type: String?
    public var layer: String
    public var key: String
    public var level: Int?
    public var tx: Int?
    public var ty: Int?
    public var ver: TileVer?
    public var origin: [Double]?
    public var sizeM: Double?
    public var hw: [String: Int]?
    public var hwWall: Double?
    public var keyframes: Int?
    public var triangles: Int?

    enum CodingKeys: String, CodingKey {
        case type, layer, key, level, tx, ty, ver, origin, hw, keyframes, triangles
        case sizeM = "size_m", hwWall = "hw_wall"
    }

    public init(layer: String, key: String, level: Int? = nil, tx: Int? = nil, ty: Int? = nil, ver: TileVer? = nil,
                origin: [Double]? = nil, sizeM: Double? = 4, hw: [String: Int]? = nil, hwWall: Double? = nil) {
        self.layer = layer; self.key = key; self.level = level; self.tx = tx; self.ty = ty; self.ver = ver
        self.origin = origin; self.sizeM = sizeM; self.hw = hw; self.hwWall = hwWall
    }

    /// nil unless `data` is a `tile` message.
    public static func parse(_ data: Data) -> LiveTileHeader? {
        guard let h = try? JSONDecoder().decode(LiveTileHeader.self, from: data), h.type == "tile" else { return nil }
        return h
    }

    /// Agent ids whose streams were fused into this tile ("<agent>/<stream>" keys).
    public var agents: [String] {
        Array(Set((hw ?? [:]).keys.map { k in k.split(separator: "/").first.map(String.init) ?? k })).sorted()
    }

    /// The tile's square [x0, y0, x1, y1] (from `origin` + `size_m`, else from the key "<level>/<tx>/<ty>").
    public var square: [Double]? {
        let s = sizeM ?? 4
        if let o = origin, o.count >= 2 { return [o[0], o[1], o[0] + s, o[1] + s] }
        let p = key.split(separator: "/").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return [Double(p[1]) * s, Double(p[2]) * s, Double(p[1] + 1) * s, Double(p[2] + 1) * s]
    }

    /// Storey from `level`, else the key's first field.
    public var levelIndex: Int { level ?? key.split(separator: "/").first.flatMap { Int($0) } ?? 0 }
}

/// What the feed knows about one tile.
public struct LiveMeshTileInfo: Equatable {
    public enum Source: String, Equatable { case live, base }
    public var key: String
    public var source: Source
    public var level: Int
    public var square: [Double]?
    public var floorZ: Double?
    public var agents: [String]
    public var ver: TileVer?
    public var triangles: Int
    public var arrivedAt: Double            // first time we saw it
    public var changedAt: Double            // last arrival / swap (drives the highlight)
    public var updates: Int                 // in-place replacements after the first
    public var mine: Bool                   // this phone's own walk is in it
}

public struct LiveMeshFeed: Equatable {
    public private(set) var tiles: [String: LiveMeshTileInfo] = [:]
    public var fadeS: Double = 6
    public private(set) var lastArrival: Double?
    public private(set) var received = 0
    public init() {}

    public enum Applied: Equatable { case new, updated }

    /// A live mesh tile was accepted (LiveTileStore said newer) and drawn. `me` = this phone's agent id.
    @discardableResult
    public mutating func apply(_ h: LiveTileHeader, triangles: Int, floorZ: Double?, me: String, now: Double) -> Applied {
        received += 1
        lastArrival = now
        let k = "live|" + h.key
        let agents = h.agents
        if var t = tiles[k] {
            t.ver = h.ver ?? t.ver
            t.triangles = triangles
            t.changedAt = now
            t.updates += 1
            t.agents = Array(Set(t.agents + agents)).sorted()
            t.mine = t.mine || agents.contains(me)
            if let s = h.square { t.square = s }
            tiles[k] = t
            return .updated
        }
        tiles[k] = LiveMeshTileInfo(key: h.key, source: .live, level: h.levelIndex, square: h.square, floorZ: floorZ,
                                    agents: agents, ver: h.ver, triangles: triangles, arrivedAt: now, changedAt: now,
                                    updates: 0, mine: agents.contains(me))
        return .new
    }

    /// A base (living-map) tile was swapped in place by the M4 sync (`fresh` = a replacement, not a first load).
    public mutating func noteBase(key: String, square: [Double]?, level: Int, now: Double) {
        let k = "base|" + key
        lastArrival = now
        if var t = tiles[k] {
            t.changedAt = now
            t.updates += 1
            if let s = square { t.square = s }
            tiles[k] = t
        } else {
            tiles[k] = LiveMeshTileInfo(key: key, source: .base, level: level, square: square, floorZ: nil, agents: [],
                                        ver: nil, triangles: 0, arrivedAt: now, changedAt: now, updates: 1, mine: false)
        }
    }

    /// 1 just changed → 0 after `fadeS`.
    public func freshness(_ t: LiveMeshTileInfo, now: Double) -> Double {
        let age = now - t.changedAt
        if age <= 0 { return 1 }
        return max(0, 1 - age / fadeS)
    }

    /// 2 fresh (first third), 1 fading, 0 settled: the three literal looks.
    public func step(_ t: LiveMeshTileInfo, now: Double) -> Int {
        let f = freshness(t, now: now)
        return f > 0.66 ? 2 : (f > 0 ? 1 : 0)
    }

    public func step(key: String, source: LiveMeshTileInfo.Source = .live, now: Double) -> Int {
        tiles[source.rawValue + "|" + key].map { step($0, now: now) } ?? 0
    }

    /// Tiles still highlighted.
    public func fresh(now: Double) -> [LiveMeshTileInfo] {
        tiles.values.filter { freshness($0, now: now) > 0 }.sorted { $0.changedAt > $1.changedAt }
    }

    /// Live tiles on one storey (the Map).
    public func live(level: Int) -> [LiveMeshTileInfo] {
        tiles.values.filter { $0.source == .live && $0.level == level }.sorted { $0.key < $1.key }
    }

    /// A rebase keeps drawing old tiles until re-fused ones arrive (API §6b.1): nothing is dropped here.
    public var liveCount: Int { tiles.values.filter { $0.source == .live }.count }
    public var mineCount: Int { tiles.values.filter { $0.source == .live && $0.mine }.count }
    public var otherAgents: [String] {
        Array(Set(tiles.values.flatMap(\.agents))).sorted()
    }

    /// "Mesh live · 11 tiles (3 yours) · 2 s ago" for the layers sheet / status card.
    public func summary(now: Double, me: String) -> String {
        guard liveCount > 0 || tiles.values.contains(where: { $0.source == .base }) else { return "Mesh live · waiting for tiles" }
        var s = "Mesh live · \(liveCount) tile\(liveCount == 1 ? "" : "s")"
        if mineCount > 0 { s += " (\(mineCount) yours)" }
        let others = otherAgents.filter { $0 != me }
        if !others.isEmpty { s += " · \(others.count) other agent\(others.count == 1 ? "" : "s")" }
        if let l = lastArrival { s += " · \(LiveMeshFeed.ago(now - l))" }
        return s
    }

    static func ago(_ s: Double) -> String {
        if s < 1.5 { return "just now" }
        if s < 90 { return "\(Int(s.rounded())) s ago" }
        return "\(Int((s / 60).rounded())) min ago"
    }
}

/// A live mesh tile seen from above for the Map: `n × n` cells over its 4 m square. Cell values: 0 nothing, 1 floor
/// (upward surface near the storey floor), 2 raised surface (furniture / steps), 3 wall (steep). Walls win over the rest
/// so thin walls stay visible.
public enum TilePlanRaster {
    public static let empty: UInt8 = 0, floor: UInt8 = 1, raised: UInt8 = 2, wall: UInt8 = 3

    public static func raster(_ m: FlatMesh, square s: [Double], floorZ: Double?, n: Int = 40) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n * n)
        guard s.count == 4, n > 0, s[2] > s[0], s[3] > s[1] else { return out }
        let cw = (s[2] - s[0]) / Double(n), ch = (s[3] - s[1]) / Double(n)
        let p = m.positions
        func v(_ i: UInt32) -> (Double, Double, Double) {
            let j = Int(i) * 3
            return (Double(p[j]), Double(p[j + 1]), Double(p[j + 2]))
        }
        var fz = floorZ
        if fz == nil, !p.isEmpty {                        // no storey floor: the lowest 10th percentile of z
            var zs = stride(from: 2, to: p.count, by: 3).map { Double(p[$0]) }
            zs.sort()
            fz = zs[zs.count / 10]
        }
        var t = 0
        let idx = m.indices
        while t + 2 < idx.count {
            let a = v(idx[t]), b = v(idx[t + 1]), c = v(idx[t + 2])
            t += 3
            let ux = b.0 - a.0, uy = b.1 - a.1, uz = b.2 - a.2
            let wx = c.0 - a.0, wy = c.1 - a.1, wz = c.2 - a.2
            let nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            guard len > 1e-12 else { continue }
            let cz = abs(nz / len)
            let zc = (a.2 + b.2 + c.2) / 3
            let cls: UInt8
            if cz < 0.45 { cls = wall }
            else if let f = fz, zc - f > 0.12 { cls = raised }
            else { cls = floor }
            // cells under the triangle's xy box (triangles are ≤ ~10 cm: the box is the triangle)
            let x0 = min(a.0, b.0, c.0), x1 = max(a.0, b.0, c.0), y0 = min(a.1, b.1, c.1), y1 = max(a.1, b.1, c.1)
            let i0 = max(0, Int(((x0 - s[0]) / cw).rounded(.down))), i1 = min(n - 1, Int(((x1 - s[0]) / cw).rounded(.down)))
            let j0 = max(0, Int(((y0 - s[1]) / ch).rounded(.down))), j1 = min(n - 1, Int(((y1 - s[1]) / ch).rounded(.down)))
            guard i0 <= i1, j0 <= j1 else { continue }
            for j in j0...j1 {
                for i in i0...i1 {
                    let o = j * n + i                    // row 0 = min y
                    if cls > out[o] { out[o] = cls }
                }
            }
        }
        return out
    }

    /// Share of cells with anything in them (0…1).
    public static func coverage(_ r: [UInt8]) -> Double {
        r.isEmpty ? 0 : Double(r.filter { $0 != 0 }.count) / Double(r.count)
    }
}
