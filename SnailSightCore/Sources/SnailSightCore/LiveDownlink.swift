import Foundation

// SnailSight 10.1 L3/L4 client side (plan §8.4 "Downlink", §8.9 L3/L4; API §6b read side + §7 planned downlink).
// Downlink WS /v1/maps/{map_id}/live (API §6b.1): subscribe {layers, since{epoch, base_version, seq, tiles}, accept,
// transport}; the server sends only newer tiles. Messages: head {epoch, base_version, seq}; snapshot; correction;
// agent (one per stream, ≤ 2 Hz, pose in the map frame); tile {layer, key, ver, enc, data} (json transport: `f32`
// mesh); doc {kind, revision, url}; change {id/key, state confirmed|updated|cleared|dynamic, kind added|removed,
// bbox[6]}; rebase {to_version}; commit {version}. Unknown types are ignored.
// Other agents also come from GET /v1/live/state (API §6b, exists today) when the downlink is not available.
// Pure, Linux-tested (LiveDownlinkTests).

/// A tile's version vector {base_version, live_seq} (an Int is read as {base_version: 0, live_seq: n}).
public struct TileVer: Codable, Equatable, Comparable {
    public var base: Int
    public var seq: Int
    public init(base: Int, seq: Int) { self.base = base; self.seq = seq }
    enum CodingKeys: String, CodingKey { case base = "base_version", seq = "live_seq" }
    public init(from d: Decoder) throws {
        if let c = try? d.singleValueContainer(), let n = try? c.decode(Int.self) { base = 0; seq = n; return }
        let c = try d.container(keyedBy: CodingKeys.self)
        base = (try? c.decodeIfPresent(Int.self, forKey: .base)) ?? 0
        seq = (try? c.decodeIfPresent(Int.self, forKey: .seq)) ?? 0
    }
    public static func < (a: TileVer, b: TileVer) -> Bool { a.base != b.base ? a.base < b.base : a.seq < b.seq }
}

/// One downlink message, decoded tolerantly.
public enum LiveDownMessage: Equatable {
    case head(baseVersion: Int?, seq: Int?, epoch: String?)
    case correction(agentID: String, streamID: String?, T: Mat4, placed: Bool?)
    case tile(layer: String, key: String, ver: TileVer, enc: String, data: String?)
    case doc(kind: String, revision: Int?)
    case change(key: String, kind: String, state: String?, bbox: [Double]?)
    case rebase(toVersion: Int)
    case commit(version: Int)
    case agents([LiveAgent])
    case error(String)
    case other(String)

    struct Raw: Decodable {
        var type: String?
        var epoch: String?
        var id: String?
        var state: String?
        var to_version: Int?
        var base_version: Int?
        var seq: Int?
        var agent_id: String?
        var stream_id: String?
        var T_map_odom: Mat4?
        var placed: Bool?
        var layer: String?
        var key: String?
        var ver: TileVer?
        var enc: String?
        var data: String?
        var kind: String?
        var revision: Int?
        var bbox: [Double]?
        var change: String?
        var version: Int?
        var agents: [LiveAgent]?
        var detail: String?
    }

    public static func parse(_ data: Data) -> LiveDownMessage? { parseWithSeq(data)?.message }

    /// The message and its feed `seq` (for `since.seq` on a resume).
    public static func parseWithSeq(_ data: Data) -> (message: LiveDownMessage, seq: Int?)? {
        guard let r = try? JSONDecoder().decode(Raw.self, from: data), let t = r.type else { return nil }
        guard let m = make(t, r, data) else { return nil }
        return (m, r.seq)
    }

    private static func make(_ t: String, _ r: Raw, _ data: Data) -> LiveDownMessage? {
        switch t {
        case "head", "welcome", "subscribed": return .head(baseVersion: r.base_version, seq: r.seq, epoch: r.epoch)
        case "correction":
            guard let a = r.agent_id, let T = r.T_map_odom else { return .other(t) }
            return .correction(agentID: a, streamID: r.stream_id, T: T, placed: r.placed)
        case "tile":
            guard let l = r.layer, let k = r.key else { return .other(t) }
            return .tile(layer: l, key: k, ver: r.ver ?? TileVer(base: r.base_version ?? 0, seq: r.seq ?? 0),
                         enc: r.enc ?? "", data: r.data)
        case "doc": return .doc(kind: r.kind ?? "?", revision: r.revision)
        case "change": return .change(key: r.key ?? r.id ?? "", kind: r.change ?? r.kind ?? "changed", state: r.state, bbox: r.bbox)
        case "rebase": return r.to_version.map { .rebase(toVersion: $0) } ?? .other(t)
        case "commit": return r.version.map { .commit(version: $0) } ?? .other(t)
        case "agents": return .agents(r.agents ?? [])
        case "agent":
            if let one = try? JSONDecoder().decode(LiveAgent.self, from: data) { return .agents([one]) }
            return .other(t)
        case "error": return .error(r.detail ?? "?")
        default: return .other(t)
        }
    }
}

/// The subscribe message (plan §8.4). `accept` names the tile encodings the phone can draw (it cannot decode meshopt
/// GLB): `f32` mesh tiles (LiveMeshTile below); other encodings arrive as "this tile changed" only.
public enum LiveSubscribe {
    /// Terrain / occupancy tiles are PNGs the phone does not draw yet: not subscribed (bandwidth).
    public static let layers = ["corrections", "agents", "changes", "docs", "mesh"]

    public static func message(agentID: String, mapID: String, baseVersion: Int?, tiles: [String: TileVer],
                               epoch: String? = nil, seq: Int? = nil,
                               bbox: [Double]? = nil, layers: [String] = LiveSubscribe.layers) -> Data {
        var since: [String: Any] = ["tiles": tiles.mapValues { ["base_version": $0.base, "live_seq": $0.seq] }]
        if let b = baseVersion { since["base_version"] = b }
        if let e = epoch { since["epoch"] = e }
        if let q = seq { since["seq"] = q }
        var o: [String: Any] = ["type": "subscribe", "agent_id": agentID, "map_id": mapID, "layers": layers,
                                "since": since, "transport": "json", "accept": ["mesh": ["f32"]]]
        if let b = bbox, b.count == 4 { o["bbox"] = b }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }
}

/// Which tile versions we hold: newer-only acceptance, and the `since.tiles` vector for a reconnect.
public struct LiveTileStore: Equatable {
    public private(set) var have: [String: TileVer] = [:]       // "layer|key" → ver
    public private(set) var baseVersion: Int?
    public init() {}

    /// true = draw it (newer than what we hold).
    public mutating func accept(layer: String, key: String, ver: TileVer) -> Bool {
        let k = layer + "|" + key
        if let h = have[k], !(h < ver) { return false }
        have[k] = ver
        return true
    }

    /// A commit / new base version: tiles of older bases are part of the committed map now (the server resends what
    /// still differs).
    public mutating func rebase(_ v: Int) {
        baseVersion = v
        have = have.filter { $0.value.base >= v }
    }

    public func since(layer: String) -> [String: TileVer] {
        var out: [String: TileVer] = [:]
        for (k, v) in have where k.hasPrefix(layer + "|") { out[String(k.dropFirst(layer.count + 1))] = v }
        return out
    }

    public var allSince: [String: TileVer] {
        var out: [String: TileVer] = [:]
        for (k, v) in have { out[k.replacingOccurrences(of: "|", with: ":")] = v }
        return out
    }
}

/// `f32` mesh tile: base64 of little-endian u32 vertexCount, u32 triangleCount, f32[3·V] xyz (map frame), u32[3·T].
public enum LiveMeshTile {
    public static func decode(enc: String, base64: String?) -> FlatMesh? {
        guard enc == "f32", let s = base64, let d = Data(base64Encoded: s), d.count >= 8 else { return nil }
        return d.withUnsafeBytes { (r: UnsafeRawBufferPointer) -> FlatMesh? in
            let nv = Int(UInt32(littleEndian: r.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
            let nt = Int(UInt32(littleEndian: r.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            guard nv <= 2_000_000, nt <= 4_000_000, d.count >= 8 + nv * 12 + nt * 12 else { return nil }
            var pos = [Float](repeating: 0, count: nv * 3)
            for i in 0..<(nv * 3) {
                pos[i] = Float(bitPattern: UInt32(littleEndian: r.loadUnaligned(fromByteOffset: 8 + i * 4, as: UInt32.self)))
            }
            let off = 8 + nv * 12
            var idx = [UInt32](repeating: 0, count: nt * 3)
            for i in 0..<(nt * 3) {
                let v = UInt32(littleEndian: r.loadUnaligned(fromByteOffset: off + i * 4, as: UInt32.self))
                guard Int(v) < nv else { return nil }
                idx[i] = v
            }
            return FlatMesh(positions: pos, indices: idx)
        }
    }

    public static func encode(_ m: FlatMesh) -> String {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(UInt32(m.vertexCount)); u32(UInt32(m.triangleCount))
        for p in m.positions { u32(p.bitPattern) }
        for i in m.indices { u32(i) }
        return d.base64EncodedString()
    }
}

/// L4 change markers: subtle, short-lived (plan §8.3 point 5: added / removed / changed / dynamic).
public struct ChangeMarkers: Equatable {
    public struct Marker: Equatable {
        public var key: String
        public var kind: String
        public var center: [Double]               // map x, y, z
        public var size: [Double]                 // extents (≥ 0.2 m)
        public var at: Double
    }
    public private(set) var markers: [Marker] = []
    public var lifetime = 90.0
    public var maxCount = 24
    public init() {}

    /// `bbox` [xmin, ymin, zmin, xmax, ymax, zmax] or [xmin, ymin, xmax, ymax] (z = `floorZ`). State (API §6b.1):
    /// `cleared` (put back) removes the marker; `dynamic` regions (a door in use) are not flagged. true = changed.
    @discardableResult
    public mutating func add(key: String, kind: String, state: String? = nil, bbox: [Double]?, floorZ: Double,
                             now: Double) -> Bool {
        if state == "cleared" {
            let n = markers.count
            markers.removeAll { $0.key == key }
            return markers.count != n
        }
        guard kind != "dynamic", state != "dynamic", let b = bbox, b.count == 6 || b.count == 4 else { return false }
        let lo = b.count == 6 ? [b[0], b[1], b[2]] : [b[0], b[1], floorZ]
        let hi = b.count == 6 ? [b[3], b[4], b[5]] : [b[2], b[3], floorZ + 1]
        let m = Marker(key: key, kind: kind, center: (0..<3).map { (lo[$0] + hi[$0]) / 2 },
                       size: (0..<3).map { max(0.2, hi[$0] - lo[$0]) }, at: now)
        markers.removeAll { $0.key == key && !key.isEmpty }
        markers.append(m)
        if markers.count > maxCount { markers.removeFirst(markers.count - maxCount) }
        return true
    }

    /// Drops expired markers; true when something went.
    @discardableResult
    public mutating func expire(now: Double) -> Bool {
        let n = markers.count
        markers.removeAll { now - $0.at > lifetime }
        return markers.count != n
    }

    /// 1 → 0 over the lifetime (first 2 s full), for the marker's opacity.
    public func fade(_ m: Marker, now: Double) -> Double {
        let age = now - m.at
        if age < 2 { return 1 }
        return max(0, 1 - (age - 2) / max(lifetime - 2, 1))
    }
}

// MARK: other agents

/// An agent in GET /v1/live/state (API §6b) or a downlink `agents` message.
public struct LiveAgent: Decodable, Equatable {
    public var agentID: String
    public var agentType: String?
    public var streamID: String?
    public var connected: Bool?
    public var placed: Bool?
    public var via: String?
    public var T_map_odom: Mat4?
    public var path: [[Double]]?
    public var lastWall: Double?
    public var pose: MapPose?                     // downlink agents may send a pose directly
    enum CodingKeys: String, CodingKey {
        case connected, placed, via, path, pose
        case T_map_odom
        case agentID = "agent_id", agentType = "agent_type", streamID = "stream_id", lastWall = "last_wall"
    }
}

public struct LiveStateDoc: Decodable, Equatable {
    public var mapID: String?
    public var anchored: Bool?
    public var baseVersion: Int?
    public var agents: [LiveAgent]
    enum CodingKeys: String, CodingKey { case anchored, agents, mapID = "map_id", baseVersion = "base_version" }
}

/// Downlink `agent` messages come one stream at a time (≤ 2 Hz): keep the latest per agent, grow a trail from
/// successive poses (≥ 10 cm apart), forget agents silent for 60 s.
public struct AgentTrails: Equatable {
    public private(set) var latest: [String: LiveAgent] = [:]
    public private(set) var trails: [String: [[Double]]] = [:]
    private var seen: [String: Double] = [:]
    public init() {}

    public mutating func update(_ a: LiveAgent, now: Double) {
        latest[a.agentID] = a
        seen[a.agentID] = now
        guard let p = a.pose, a.placed == true else { return }
        var t = trails[a.agentID] ?? []
        if let l = t.last, hypot(l[0] - p.x, l[1] - p.y) < 0.1, abs(l[2] - p.z) < 0.1 { return }
        t.append([p.x, p.y, p.z])
        if t.count > AgentMark.trailMax { t.removeFirst(t.count - AgentMark.trailMax) }
        trails[a.agentID] = t
    }

    public mutating func expire(now: Double, after: Double = 60) {
        for (id, t) in seen where now - t > after { seen[id] = nil; latest[id] = nil; trails[id] = nil }
    }

    /// Marks with the locally grown trails.
    public func marks(me: String, now: Double) -> [AgentMark] {
        AgentMark.from(Array(latest.values), me: me, now: now).map { m in
            var m = m
            if let t = trails[m.id] { m.trail = t }
            return m
        }
    }
}

/// What AR / Scans draw for another agent.
public struct AgentMark: Equatable {
    public var id: String
    public var type: String
    public var position: [Double]                 // map frame
    public var heading: Double                    // rad about +z
    public var trail: [[Double]]                  // newest last, ≤ trailMax
    public var live: Bool                         // connected and seen recently
    public var label: String

    public static let trailMax = 120

    /// Placed agents only (an unplaced one's path is in its own frame: never drawn as if it were in the map). `me`
    /// is skipped. `now` = UNIX time; > 30 s since the last keyframe = not live.
    public static func from(_ agents: [LiveAgent], me: String, now: Double) -> [AgentMark] {
        agents.compactMap { a in
            guard a.agentID != me, a.placed == true else { return nil }
            let live = (a.connected ?? false) && (a.lastWall.map { now - $0 < 30 } ?? true)
            if let p = a.pose {
                return AgentMark(id: a.agentID, type: a.agentType ?? "agent", position: [p.x, p.y, p.z], heading: p.yaw,
                                 trail: [], live: live, label: label(a))
            }
            guard let path = a.path?.filter({ $0.count >= 3 }), let last = path.last else { return nil }
            var heading = 0.0
            if let prev = path.dropLast().last(where: { hypot($0[0] - last[0], $0[1] - last[1]) > 0.05 }) {
                heading = atan2(last[1] - prev[1], last[0] - prev[0])
            }
            return AgentMark(id: a.agentID, type: a.agentType ?? "agent", position: last, heading: heading,
                             trail: Array(path.suffix(trailMax)), live: live, label: label(a))
        }.sorted { $0.id < $1.id }
    }

    static func label(_ a: LiveAgent) -> String {
        let t = a.agentType ?? "agent"
        let short = a.agentID.count > 14 ? String(a.agentID.prefix(14)) + "…" : a.agentID
        return t == "phone" ? "📱 \(short)" : "\(t) · \(short)"
    }
}

/// The feature switches a server advertises in GET /v1 `features` (§1), and the user's Settings overrides.
public struct ServerFeatures: Equatable {
    public var list: Set<String>
    public init(_ list: [String]) { self.list = Set(list) }

    public static func parse(_ data: Data) -> ServerFeatures {
        struct R: Decodable { var features: [String]? }
        return ServerFeatures((try? JSONDecoder().decode(R.self, from: data))?.features ?? [])
    }

    /// L3 downlink: the server advertises it (any of the names lane A may pick), or the user forced it on.
    public func liveDownlink(forced: Bool) -> Bool {
        forced || !list.isDisjoint(with: ["live_downlink", "live_deltas", "live_subscribe", "map_live"])
    }

    /// 12.0: the surveyed-vs-estimated world (API §5.16).
    public var estimatedWorld: Bool { list.contains("estimated_world") }

    /// S2 server-authoritative sim.
    public func serverSim(forced: Bool) -> Bool {
        forced || !list.isDisjoint(with: ["sim", "sim_server", "sim_entities", "server_sim", "map_sim"])
    }
}
