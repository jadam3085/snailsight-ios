import Foundation

// 10.7 Follow LATEST (live shared-map plan M1, API §5.11). The map server says which version of the shared map clients
// should show NOW (`GET /v1/maps/site/head`, and `{"type":"rev"}` on the live WS): the newest version whose phone mesh is
// BUILT. The app shows the cached head at launch, checks the server in the background, prefetches a newer version and
// swaps it in at a still moment (never mid-walk, never an AR session restart), then says "Map updated · rev N".
// Pure logic here (no ARKit / UIKit), so it is tested on Linux CI.

/// The server's map head (or a `rev` WS message: same fields plus `"type":"rev"`).
public struct MapHead: Codable, Equatable {
    public struct Phone: Codable, Equatable {
        public var usdzURL: String
        public var bytes: Int?
        public var triangles: Int?
        public var built: Double?
        public var rebuilding: Bool?

        enum CodingKeys: String, CodingKey {
            case bytes, triangles, built, rebuilding
            case usdzURL = "usdz_url"
        }

        public init(usdzURL: String, bytes: Int? = nil, built: Double? = nil) {
            self.usdzURL = usdzURL; self.bytes = bytes; self.built = built
        }
    }

    public struct Collision: Codable, Equatable {
        public var url: String
        public var bytes: Int?
        public init(url: String, bytes: Int? = nil) { self.url = url; self.bytes = bytes }
    }

    public struct Pending: Codable, Equatable {
        public var version: Int
        public var phone: String?
        public var geometry: String?
        public init(version: Int, phone: String? = nil, geometry: String? = nil) {
            self.version = version; self.phone = phone; self.geometry = geometry
        }
    }

    public var mapID: String
    public var rev: Int?
    public var ready: Bool
    public var latestVersion: Int?
    public var version: Int?
    public var scene: String?
    public var etag: String?
    public var phone: Phone?
    public var collision: Collision?
    public var pending: Pending?
    public var serverTime: Double?

    enum CodingKeys: String, CodingKey {
        case rev, ready, version, scene, etag, phone, collision, pending
        case mapID = "map_id", latestVersion = "latest_version", serverTime = "server_time"
    }

    public init(mapID: String = "site", rev: Int?, etag: String? = nil, phone: Phone? = nil,
                collision: Collision? = nil, pending: Pending? = nil, latestVersion: Int? = nil) {
        self.mapID = mapID; self.rev = rev; self.ready = rev != nil; self.version = rev
        self.scene = rev.map { "\(mapID)@\($0)" }
        self.etag = etag ?? rev.map { "\($0)-0" }
        self.phone = phone; self.collision = collision; self.pending = pending
        self.latestVersion = latestVersion ?? rev
    }

    /// Decode a head body or a `rev` message. nil for any other JSON (or a message of another type).
    public static func decode(_ data: Data) -> MapHead? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let t = obj["type"] as? String, t != "rev" { return nil }
        guard obj["map_id"] is String else { return nil }
        return try? JSONDecoder().decode(MapHead.self, from: data)
    }

    /// Shown content can be this head: a built version with a usdz.
    public var usable: Bool { ready && rev != nil && scene != nil }

    /// "site@14".
    public var sceneID: String? { scene ?? rev.map { "\(mapID)@\($0)" } }

    /// Is `self` newer than `other` (a higher rev, or the same rev rebuilt: a new etag)? Never older.
    public func isNewer(than other: MapHead?) -> Bool {
        guard usable, let r = rev else { return false }
        guard let o = other, let orv = o.rev else { return true }
        if r != orv { return r > orv }
        return etag != nil && etag != o.etag
    }
}

/// Which head is on screen, which one is downloaded and waiting for a still moment.
public struct MapFollow: Equatable {
    public private(set) var shown: MapHead?
    public private(set) var known: MapHead?
    public private(set) var staged: MapHead?
    public private(set) var stagedAt: Double?
    /// Swap at the latest this long after the download finished, even while moving (plan M1 gate: ≤ 60 s).
    public static let maxWaitS = 30.0

    public init(cached: MapHead? = nil) {
        shown = (cached?.usable ?? false) ? cached : nil
        known = shown
    }

    /// A head from the server (HTTP or WS). true = it is newer than what is on screen and staged: fetch its content.
    @discardableResult
    public mutating func offer(_ h: MapHead) -> Bool {
        guard h.usable else { return false }          // nothing built yet: keep what is shown
        if h.isNewer(than: known) { known = h }
        guard h.isNewer(than: shown) else { return false }
        if let s = staged, !h.isNewer(than: s) { return false }
        return true
    }

    /// The content of `h` is on the phone now (downloaded / cached). Ignored when something newer is already staged.
    public mutating func didPrefetch(_ h: MapHead, now: Double) {
        guard h.isNewer(than: shown) else { return }
        if let s = staged, !h.isNewer(than: s) { return }
        staged = h
        stagedAt = now
    }

    /// The head to swap in now, if any: at once when nothing is shown yet, else at a still moment or after maxWaitS.
    public func swapDue(now: Double, still: Bool) -> MapHead? {
        guard let s = staged, s.isNewer(than: shown) else { return nil }
        if shown == nil || still { return s }
        return now - (stagedAt ?? now) >= Self.maxWaitS ? s : nil
    }

    /// `h` is on screen now. Returns the toast ("Map updated · rev N"), nil for the first map of the run.
    @discardableResult
    public mutating func didSwap(_ h: MapHead) -> String? {
        let had = shown
        shown = h
        if staged == h { staged = nil; stagedAt = nil }
        guard had != nil, let r = h.rev else { return nil }
        return MapFollow.toast(rev: r)
    }

    public static func toast(rev: Int) -> String { "Map updated · rev \(rev)" }

    /// The followed version (content shown when there is no lock to match).
    public var followVersion: Int? { shown?.rev }
}

/// Which map version the AR content uses. The content must be in the frame of the lock: the lock's version while that
/// is not newer than the followed head (the localizer can run ahead of the phone mesh for a few minutes after a merge,
/// or stay on an older version when it cannot load the new one); the followed version otherwise and before any lock.
public enum ARContentPick {
    public static func version(lock: Int?, follow: Int?) -> Int? {
        guard let f = follow else { return lock }
        guard let l = lock else { return f }
        return l <= f ? l : f
    }
}

/// "Still" = the camera moved < maxSpeed m/s and turned < maxTurnDegS °/s over the last `window` seconds.
public struct StillDetector {
    public var window: Double = 1.0
    public var maxSpeed: Double = 0.25
    public var maxTurnDegS: Double = 25
    private var samples: [(t: Double, p: [Double], yaw: Double)] = []

    public init() {}

    /// One camera sample (position in metres, heading in degrees).
    public mutating func add(t: Double, position p: [Double], yawDeg: Double) {
        samples.append((t, p, yawDeg))
        while let f = samples.first, t - f.t > window * 2 { samples.removeFirst() }
    }

    public func isStill(now: Double) -> Bool {
        let w = samples.filter { now - $0.t <= window + 1e-9 }
        guard w.count >= 2, let a = w.first, let b = w.last, b.t - a.t >= window * 0.6 else { return false }
        var dist = 0.0, turn = 0.0
        for i in 1..<w.count {
            let p = w[i - 1].p, q = w[i].p
            var sq = 0.0
            for k in 0..<min(p.count, q.count) {
                let dk: Double = q[k] - p[k]
                sq += dk * dk
            }
            dist += sq.squareRoot()
            var d = abs(w[i].yaw - w[i - 1].yaw).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            turn += d
        }
        let dt = b.t - a.t
        return dist / dt < maxSpeed && turn / dt < maxTurnDegS
    }
}
