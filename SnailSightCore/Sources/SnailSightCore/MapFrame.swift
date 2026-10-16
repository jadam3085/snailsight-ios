import Foundation

// SnailSight P2b (plan §7 P2b, API §5.6/§5.7): the phone localized against the map server's MASTER map (`site`, all
// sessions merged). The server answers T_map_arkit: map frame (RTAB-Map, z-up metres) ← this ARKit session's world
// (y-up). Sim entities are stored server-side in map coordinates, so any device / launch / start point shows them in
// the same place once localized; the device's ARWorldMap (P2a) is only a fast cache.
//
// Ground frame used by the sim (SimFrame): g = (ARKit x, −ARKit z), heading about ARKit +Y. That is exactly the client
// odometry frame of API §4.5 (x = x_ark, y = −z_ark, z = y_ark), so a map pose's yaw = ground yaw + correction yaw.

/// A rigid 4×4 (row-major, metres), as on the wire.
public struct Mat4: Codable, Equatable {
    public var m: [Double]                     // 16, row-major

    public init(_ m: [Double]) {
        precondition(m.count == 16, "Mat4 needs 16 numbers")
        self.m = m
    }

    public static let identity = Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let v = try c.decode([Double].self)
        guard v.count == 16 || v.count == 12 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "need 12 or 16 numbers")
        }
        m = v.count == 16 ? v : v + [0, 0, 0, 1]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(m)
    }

    public subscript(r: Int, c: Int) -> Double { m[r * 4 + c] }

    public func apply(_ p: [Double]) -> [Double] {
        (0..<3).map { r in self[r, 0] * p[0] + self[r, 1] * p[1] + self[r, 2] * p[2] + self[r, 3] }
    }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        var o = [Double](repeating: 0, count: 16)
        for r in 0..<4 { for c in 0..<4 { o[r * 4 + c] = (0..<4).reduce(0.0) { $0 + a[r, $1] * b[$1, c] } } }
        return Mat4(o)
    }

    /// Inverse of a rigid transform.
    public var inverse: Mat4 {
        var o = [Double](repeating: 0, count: 16)
        for r in 0..<3 { for c in 0..<3 { o[r * 4 + c] = self[c, r] } }
        for r in 0..<3 { o[r * 4 + 3] = -(o[r * 4] * self[0, 3] + o[r * 4 + 1] * self[1, 3] + o[r * 4 + 2] * self[2, 3]) }
        o[15] = 1
        return Mat4(o)
    }

    public var translation: [Double] { [self[0, 3], self[1, 3], self[2, 3]] }

    /// Column-major floats (simd_float4x4 column order) for the app.
    public var columnsMajor: [Float] { (0..<4).flatMap { c in (0..<4).map { r in Float(self[r, c]) } } }

    public init(columnsMajor f: [Float]) {
        precondition(f.count == 16)
        var o = [Double](repeating: 0, count: 16)
        for c in 0..<4 { for r in 0..<4 { o[r * 4 + c] = Double(f[c * 4 + r]) } }
        self.init(o)
    }
}

/// map ← ARKit world transform of one ARKit session, with the frame conversions the sim needs.
public struct MapAlignment: Codable, Equatable {
    public var mapID: String
    public var version: Int
    public var T: Mat4                          // T_map_arkit
    public var at: Double                       // when it was locked / last refined (unix s)
    public var inliers: Int?
    public var spreadCm: Double?
    public var method: String?                  // server: geometry | visual | both (10.4, API §5.6c), or the older
                                                //   visual | visual+mesh | mesh (§5.6b); nil = cached/older

    public init(mapID: String, version: Int, T: Mat4, at: Double, inliers: Int? = nil, spreadCm: Double? = nil,
                method: String? = nil) {
        self.mapID = mapID; self.version = version; self.T = T; self.at = at; self.inliers = inliers
        self.spreadCm = spreadCm; self.method = method
    }

    /// The lock was checked against the house mesh (the phone's LiDAR depth ICP-aligned to it, API §5.6b).
    public var meshAligned: Bool { LocMethod.usesGeometry(method) }

    /// Heading of the map ← odom correction about the map's +z (rad). With X = Rx(+90°): T·X⁻¹ = correction.
    public var yaw: Double {
        // correction = T · X⁻¹, X⁻¹ = Rx(−90°): column 0 of the correction = column 0 of T.
        atan2(T[1, 0], T[0, 0])
    }

    /// Degrees between ARKit +Y carried into the map and the map's +Z (gravity consistency, 0 = perfect).
    public var tiltDeg: Double {
        let up = [T[0, 1], T[1, 1], T[2, 1]]
        let n = (up[0] * up[0] + up[1] * up[1] + up[2] * up[2]).squareRoot()
        return acos(max(-1, min(1, up[2] / max(n, 1e-12)))) * 180 / .pi
    }

    public func toMap(arkit p: [Double]) -> [Double] { T.apply(p) }
    public func toArkit(map p: [Double]) -> [Double] { T.inverse.apply(p) }

    /// An ARKit floor point + sim ground heading → a map pose.
    public func mapPose(arkit p: [Double], groundYaw: Double) -> MapPose {
        let q = toMap(arkit: p)
        return MapPose(x: q[0], y: q[1], z: q[2], yaw: MapAlignment.wrap(groundYaw + yaw))
    }

    /// A map pose → ARKit position + sim ground heading.
    public func arkit(_ pose: MapPose) -> (position: [Double], groundYaw: Double) {
        (toArkit(map: [pose.x, pose.y, pose.z]), MapAlignment.wrap(pose.yaw - yaw))
    }

    /// How far apart two alignments put the same ARKit point (cm) and their rotation difference (deg).
    public func delta(_ o: MapAlignment, at probe: [Double] = [0, 0, 0]) -> (cm: Double, deg: Double) {
        let a = toMap(arkit: probe), b = o.toMap(arkit: probe)
        let cm = ((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2])).squareRoot() * 100
        let R = T.inverse * o.T                  // rotation part only matters
        let tr = R[0, 0] + R[1, 1] + R[2, 2]
        let deg = acos(max(-1, min(1, (tr - 1) / 2))) * 180 / .pi
        return (cm, deg)
    }

    static func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }
}

/// A sim body's home spot in the map frame (z-up metres, yaw about +z).
public struct MapPose: Codable, Equatable {
    public var x: Double, y: Double, z: Double, yaw: Double
    public init(x: Double, y: Double, z: Double, yaw: Double) { self.x = x; self.y = y; self.z = z; self.yaw = yaw }
}

/// One entity as stored on the server (API §5.7).
public struct MapEntity: Codable, Equatable {
    public var id: String
    public var kind: String
    public var pose: MapPose
    public var mapVersion: Int
    public var record: SimEntityRecord?
    public var agentID: String?
    public var placeID: String?
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, pose, record, name
        case mapVersion = "map_version", agentID = "agent_id", placeID = "place_id"
    }

    public init(id: String, kind: String, pose: MapPose, mapVersion: Int, record: SimEntityRecord?, agentID: String? = nil,
                placeID: String? = nil, name: String? = nil) {
        self.id = id; self.kind = kind; self.pose = pose; self.mapVersion = mapVersion; self.record = record
        self.agentID = agentID; self.placeID = placeID; self.name = name
    }

    /// The entity built from a sim snapshot record and its anchor's map pose.
    public static func from(_ r: SimEntityRecord, pose: MapPose, mapVersion: Int, agentID: String, placeID: String?) -> MapEntity {
        MapEntity(id: r.id, kind: r.kind, pose: pose, mapVersion: mapVersion, record: r, agentID: agentID, placeID: placeID,
                  name: r.room)
    }

    /// The record to restore (anchor = where it goes in this ARKit session; the record's polygon / loop are
    /// anchor-relative, so they need no transform). Entities written by other tools without a record get a default.
    public func restoreRecord(arkitAnchor p: [Double]) -> SimEntityRecord {
        var r = record ?? SimEntityRecord(id: id, kind: kind, behaviour: "roam", heading: 0, anchor: p)
        r.id = id
        r.anchor = p
        return r
    }
}

/// GET /v1/maps/{map}/entities
public struct MapEntitiesDoc: Codable, Equatable {
    public var mapID: String
    public var revision: Int
    public var mapVersion: Int?
    public var entities: [MapEntity]
    enum CodingKeys: String, CodingKey {
        case revision, entities
        case mapID = "map_id", mapVersion = "map_version"
    }
}

/// PUT /v1/maps/{map}/entities (bulk replace) body.
public struct MapEntitiesPut: Encodable {
    public var entities: [String: Item]
    public var agentID: String
    public var reason: String
    public struct Item: Encodable {
        public var kind: String
        public var pose: MapPose
        public var mapVersion: Int
        public var record: SimEntityRecord?
        public var agentID: String?
        public var placeID: String?
        public var name: String?
        enum CodingKeys: String, CodingKey {
            case kind, pose, record, name
            case mapVersion = "map_version", agentID = "agent_id", placeID = "place_id"
        }
    }
    enum CodingKeys: String, CodingKey { case entities, reason, agentID = "agent_id" }

    public init(_ list: [MapEntity], agentID: String, reason: String) {
        var d: [String: Item] = [:]
        for e in list {
            d[e.id] = Item(kind: e.kind, pose: e.pose, mapVersion: e.mapVersion, record: e.record, agentID: e.agentID,
                           placeID: e.placeID, name: e.name)
        }
        entities = d
        self.agentID = agentID
        self.reason = reason
    }
}

/// POST /v1/localize answer (the parts the app uses).
public struct LocalizeAnswer: Decodable {
    public var ok: Bool?
    public var mapID: String
    public var mapVersion: Int
    public var locked: Bool
    public var events: [String]
    public var T_map_arkit: Mat4?
    public var timeToLockS: Double?
    public var matchedSession: String?
    public var latencyMs: Double?
    public var gate: Gate?
    public var frames: [Frame]
    public var versionChanged: Bool?
    public var method: String?                  // this answer's newest accepted fix: visual | visual+mesh | mesh | mesh-global | none
    public var lockMethod: String?              // the method of the fix that last set / refined the lock
    public var lockSource: String?              // 10.4 (§5.6c): what the lock rests on: geometry | visual | both
    public var hint: Hint?                      // 10.4: while searching, what the user can do ("Turn to see a corner")
    public var geometry: Geometry?              // 10.4: the whole-map geometry search's state

    public struct Hint: Decodable, Equatable {
        public var code: String
        public var text: String
    }
    public struct Geometry: Decodable {
        public var state: String?               // off | waiting | searching | locked
        public var last: Last?
        public struct Last: Decodable {
            public var ok: Bool?
            public var reason: String?
            public var ambiguity: Double?
        }
    }

    public struct Gate: Decodable {
        public var locked: Bool
        public var fixes: Int?
        public var cluster: Int?
        public var spreadCm: Double?
        public var inliers: [Int]?
        enum CodingKeys: String, CodingKey { case locked, fixes, cluster, inliers, spreadCm = "spread_cm" }
    }
    public struct Frame: Decodable {
        public var node: Int
        public var inliers: Int
        public var accepted: Bool?
        public var reason: String?
        public var event: String?
        public var ms: Double?
        public var method: String?
        public var icp: ICP?
    }
    /// Per-frame mesh ICP diagnostics (API §5.6b).
    public struct ICP: Decodable {
        public var ok: Bool?
        public var fitness: Double?
        public var rmseCm: Double?
        enum CodingKeys: String, CodingKey { case ok, fitness, rmseCm = "rmse_cm" }
    }
    enum CodingKeys: String, CodingKey {
        case ok, locked, events, gate, frames
        case T_map_arkit
        case mapID = "map_id", mapVersion = "map_version", timeToLockS = "time_to_lock_s"
        case matchedSession = "matched_session", latencyMs = "latency_ms", versionChanged = "version_changed"
        case method, lockMethod = "lock_method", lockSource = "lock_source", hint, geometry
    }

    /// What the HUD names the lock by: what it rests on (10.4), else the lock's method, else this answer's.
    public var shownMethod: String? { lockSource ?? lockMethod ?? ((method == "none") ? nil : method) }
    /// The geometry search found a candidate that passed its gates (waiting for a second agreeing one): progress, so
    /// the app must not call the room "not in map".
    public var geometryCandidate: Bool { geometry?.last?.ok == true }

    public var bestInliers: Int { frames.map(\.inliers).max() ?? 0 }
    /// A frame of this answer was accepted into the stream's gate (a fix, visual or mesh).
    public var anyAccepted: Bool { frames.contains { $0.accepted == true } }
    /// The best (lowest) point-to-plane RMSE of a passing mesh ICP in this answer, cm.
    public var bestRmseCm: Double? { frames.compactMap { $0.icp?.ok == true ? $0.icp?.rmseCm : nil }.min() }
    public var anyMatch: Bool { frames.contains { $0.node > 0 } }
}

/// When to send the next localization attempt.
public struct LocalizeCadence: Equatable {
    public static let searching = 1.0           // s between attempts until locked ("Find me", automatic on launch)
    public static let refining = 8.0            // s between refinements once locked
    public static let refineCount = 12          // refinements per lock, then idle until the AR session changes
    public static let hotFactor = 3.0           // thermal serious: attempts 3× rarer, refinements stop

    public static func interval(locked: Bool, refinements: Int, thermalSerious: Bool) -> Double? {
        if locked {
            if refinements >= refineCount || thermalSerious { return nil }
            return refining
        }
        return searching * (thermalSerious ? hotFactor : 1)
    }
}

/// What to do with the bodies when a map lock arrives while a place already restored them (cross-check, P2b).
public enum MapRestorePlan: Equatable {
    case keep(maxCm: Double)                    // the place restore agrees with the map: leave the bodies alone
    case restore(reason: String)                // (re)spawn every body from the map entities
    case migrate                                // the map has none yet: write the place's bodies into the map

    /// `current`: body id → ARKit floor position of the bodies on screen now; `map`: the server's entities, already
    /// converted to ARKit positions with the new alignment.
    public static func decide(current: [String: [Double]], map: [String: [Double]], tolCm: Double = 15) -> MapRestorePlan {
        if map.isEmpty { return current.isEmpty ? .keep(maxCm: 0) : .migrate }
        if current.isEmpty { return .restore(reason: "no_bodies") }
        guard Set(current.keys) == Set(map.keys) else { return .restore(reason: "different_set") }
        var worst = 0.0
        for (id, p) in current {
            let q = map[id]!
            let d = ((p[0] - q[0]) * (p[0] - q[0]) + (p[1] - q[1]) * (p[1] - q[1]) + (p[2] - q[2]) * (p[2] - q[2])).squareRoot() * 100
            worst = max(worst, d)
        }
        return worst <= tolCm ? .keep(maxCm: worst) : .restore(reason: String(format: "moved %.0f cm", worst))
    }
}

/// 10.4: what a lock rests on. The server (API §5.6c) runs a whole-map GEOMETRY search (the phone's LiDAR against the
/// house mesh, light-independent) beside visual photo matching and says `lock_source`: geometry | visual | both. Older
/// servers / cached alignments carry a fix method instead (visual | visual+mesh | mesh | mesh-global).
public enum LocMethod {
    /// "geometry", "visual", "both" or nil (unknown).
    public static func kind(_ m: String?) -> String? {
        switch m {
        case "geometry", "mesh", "mesh-global": return "geometry"
        case "both", "visual+mesh": return "both"
        case "visual": return "visual"
        default: return nil
        }
    }
    public static func usesGeometry(_ m: String?) -> Bool { let k = kind(m); return k == "geometry" || k == "both" }
    /// Short label: "geometry", "geometry+visual", "visual".
    public static func label(_ m: String?) -> String {
        switch kind(m) {
        case "geometry": return "geometry"
        case "both": return "geometry+visual"
        default: return "visual"
        }
    }
}

/// HUD wording.
public enum MapLocText {
    public static func mapName(_ id: String) -> String { id == "site" ? "whole house" : id }

    /// "LOCALIZED · whole house v7 · 1.8 s"; "LOCALIZED · geometry · whole house v10 · 1.8 s" when the lock rests on
    /// the phone's LiDAR against the house mesh (10.4: geometry / geometry+visual, API §5.6c)
    public static func locked(mapID: String, version: Int, seconds: Double?, method: String? = nil) -> String {
        var s = "LOCALIZED"
        if LocMethod.usesGeometry(method) { s += " · " + LocMethod.label(method) }
        s += " · \(mapName(mapID)) v\(version)"
        if let t = seconds { s += String(format: " · %.1f s", t) }
        return s
    }

    /// "Finding you in the whole house map · 4 s · 2 matches"; 10.4: the server's hint (geometry search: "Turn to see a
    /// corner of the room") replaces the generic advice
    public static func searching(mapID: String, seconds: Double, attempts: Int, matches: Int, hint: String? = nil) -> String {
        var s = String(format: "Finding you in the %@ map · %.0f s", mapName(mapID), seconds)
        if matches > 0 { s += " · \(matches) match\(matches == 1 ? "" : "es")" }
        if let h = hint, !h.isEmpty { s += " · " + h }
        else if matches == 0 && attempts >= 5 { s += " · look at furniture / walls with detail" }
        return s
    }
}
