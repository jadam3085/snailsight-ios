import Foundation

// SnailSight 11.0 (plan §3.1, API §5.6): coarse hints sent with every POST /v1/localize. The server uses them only as a
// geometry-search PRIOR (search a 12 m disc around the last tile first, then the whole map), never as a placement, so a
// stale hint costs time, not correctness. The app persists the last successful lock's tile across launches.

public struct LocHint: Codable, Equatable {
    public var mapID: String
    public var tile: String?
    public var level: Int?
    /// Map-frame position [x, y] of the camera at the lock.
    public var xy: [Double]
    /// Unix time of the lock.
    public var at: Double

    public init(mapID: String, tile: String?, level: Int?, xy: [Double], at: Double) {
        self.mapID = mapID; self.tile = tile; self.level = level; self.xy = xy; self.at = at
    }

    /// A hint older than this is not sent (a week: the phone may be anywhere by then; the server would down-weight it
    /// anyway, but it stops being worth the bytes).
    public static let maxAgeS = 7 * 24 * 3600.0

    /// From a locked answer: the server's tile / level / camera_map when given, else the app's own map position.
    public static func from(answer tile: String?, level: Int?, cameraMap: [Double]?, fallbackMap: [Double], mapID: String,
                            now: Double) -> LocHint {
        let p = (cameraMap?.count ?? 0) >= 2 ? cameraMap! : fallbackMap
        let xy = p.count >= 2 ? [Self.round3(p[0]), Self.round3(p[1])] : []
        return LocHint(mapID: mapID, tile: tile ?? Self.tileKey(level: level, map: p), level: level, xy: xy, at: now)
    }

    /// The request's `hints` object (nil = send none: no lock yet, another map, or too old).
    public func body(mapID want: String, now: Double) -> [String: Any]? {
        guard want == mapID, now - at <= Self.maxAgeS, now >= at - 60 else { return nil }
        var h: [String: Any] = ["last_pose_age_s": Self.round1(max(0, now - at))]
        if let t = tile { h["last_tile"] = t }
        if let l = level { h["last_level"] = l }
        if xy.count == 2 { h["last_xy"] = xy }
        return h.count > 1 ? h : nil
    }

    /// "L/tx/ty" (4 m tiles, tx = floor(x / 4)) when the level is known.
    public static func tileKey(level: Int?, map p: [Double]) -> String? {
        guard let l = level, p.count >= 2 else { return nil }
        return "\(l)/\(Int((p[0] / 4).rounded(.down)))/\(Int((p[1] / 4).rounded(.down)))"
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
