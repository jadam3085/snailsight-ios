import Foundation

// SnailSight P2a (plan §7 P2a): persistent places. A "place" = one saved ARKit world map (one floor / connected group
// of rooms) + the sim entities that live in it. Each entity is a named ARAnchor in the world map ("sim.<id>") plus a
// record here with its species, home area and behaviour. Pure + Codable so it is unit-tested on the macOS runner;
// the app (Sources/Places) does the ARKit side.

/// One sim body that lives in a place.
public struct SimEntityRecord: Codable, Equatable {
    public var id: String                   // stable id (UUID string); the ARAnchor is named "sim.<id>"
    public var kind: String                 // deer | fox | rabbit | robot
    public var behaviour: String            // roam | pace | wander | graze | stay (AnimalOrder.name); robot: manual
    public var heading: Double              // ground-frame heading at save, relative to the anchor's yaw
    public var anchor: [Double]             // anchor world position (x, y, z) when saved (diagnostics; ARKit is truth)
    public var home: HomeArea?              // anchor-relative
    public var paceLoop: [V2]?              // anchor-relative waypoints for "pace"
    public var room: String?                // room / area name, when known
    public var scale: Double?               // 9.8 per-body Sim scale override (nil = follow the global Sim scale)

    public init(id: String, kind: String, behaviour: String, heading: Double, anchor: [Double],
                home: HomeArea? = nil, paceLoop: [V2]? = nil, room: String? = nil, scale: Double? = nil) {
        self.id = id; self.kind = kind; self.behaviour = behaviour; self.heading = heading; self.anchor = anchor
        self.home = home; self.paceLoop = paceLoop; self.room = room; self.scale = scale
    }

    public static let anchorPrefix = "sim."
    public var anchorName: String { Self.anchorPrefix + id }

    /// "sim.<id>" → "<id>", nil for anything else (cubes, rulers, mesh anchors).
    public static func id(fromAnchorName n: String?) -> String? {
        guard let n, n.hasPrefix(anchorPrefix), n.count > anchorPrefix.count else { return nil }
        return String(n.dropFirst(anchorPrefix.count))
    }

    /// The order to restore. Unknown names fall back to roaming (or wandering without a home).
    public func order(worldLoop: [V2]?) -> AnimalOrder {
        switch behaviour {
        case "pace": if let l = worldLoop, l.count >= 2 { return .pace(l) } else { return home == nil ? .wander : .roam }
        case "roam": return home == nil ? .wander : .roam
        case "graze": return .graze
        case "stay": return .stay
        case "wander": return .wander
        default: return home == nil ? .wander : .roam
        }
    }

    /// What is saved for a live order (goTo / follow / flee are transient: they come back as roam).
    public static func behaviour(of o: AnimalOrder) -> String {
        switch o {
        case .pace: return "pace"
        case .graze: return "graze"
        case .stay: return "stay"
        case .wander: return "wander"
        default: return "roam"
        }
    }
}

/// Optional "where am I" hints for picking which map to try first. All optional: the app only fills what it may read
/// without new permissions (none today: Wi-Fi SSID needs an entitlement, GPS a location prompt). Kept so a hint
/// source can be added without a schema change.
public struct PlaceHints: Codable, Equatable {
    public var ssid: String?
    public var lat: Double?
    public var lon: Double?
    public init(ssid: String? = nil, lat: Double? = nil, lon: Double? = nil) { self.ssid = ssid; self.lat = lat; self.lon = lon }
}

/// place.json — everything about a place except the world-map bytes.
public struct PlaceManifest: Codable, Equatable {
    public static let currentSchema = 1
    public var schema: Int = PlaceManifest.currentSchema
    public var id: String                   // place-<8 hex>
    public var name: String                 // "Basement", "Area 2"
    public var created: Double
    public var updated: Double
    public var lastUsed: Double             // last time it was the active place (localized or saved)
    public var lastLocalized: Double?
    public var localizeCount: Int = 0
    public var failStreak: Int = 0          // tries in a row that timed out (reset on success)
    public var lastLocalizeSeconds: Double?
    public var version: Int = 0             // local save counter
    public var serverVersion: Int?          // version the server stored for the last upload
    public var uploaded: Int?               // local `version` that upload carried (phone bookkeeping)
    public var mapBytes: Int = 0
    public var mapCenter: [Double]?
    public var mapExtent: [Double]?
    public var featurePoints: Int?
    public var appVersion: String = ""
    public var agentID: String = ""
    public var entities: [SimEntityRecord] = []
    public var hints: PlaceHints?

    public init(id: String, name: String, now: Double) {
        self.id = id; self.name = name; created = now; updated = now; lastUsed = now
    }

    public static func newID(_ uuid: UUID = UUID()) -> String {
        "place-" + uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

    public static func isValidID(_ s: String) -> Bool {
        s.count >= 3 && s.count <= 64 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            && s.unicodeScalars.allSatisfy { $0.isASCII }
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ d: Data) throws -> PlaceManifest { try JSONDecoder().decode(PlaceManifest.self, from: d) }

    /// A save landed: new local version, sizes, entities.
    public mutating func saved(now: Double, mapBytes: Int, entities: [SimEntityRecord]) {
        version += 1
        updated = now
        lastUsed = now
        self.mapBytes = mapBytes
        self.entities = entities
    }

    public mutating func localized(now: Double, seconds: Double) {
        lastLocalized = now
        lastUsed = now
        localizeCount += 1
        failStreak = 0
        lastLocalizeSeconds = seconds
    }

    public mutating func timedOut() { failStreak += 1 }

    /// This version is not on the server yet.
    public var needsUpload: Bool { version > 0 && uploaded != version }

    /// Sizes the phone keeps sane: warn above this (owner sees "big map: start a new place for the next floor").
    public static let bigMapBytes = 60 * 1024 * 1024
    /// Refused above this (the server's cap too).
    public static let maxMapBytes = 120 * 1024 * 1024
}

/// The one-file container for a place, on disk and on the wire (`application/x-snailsight-place`, API §2.2):
/// "SSWM" · version byte (1) · UInt32 big-endian manifest length · manifest JSON · ARWorldMap archive bytes.
public enum PlaceCodec {
    public static let magic = Data("SSWM".utf8)
    public static let version: UInt8 = 1
    public static let contentType = "application/x-snailsight-place"

    public enum CodecError: Error, Equatable { case notAPlace, badVersion(UInt8), truncated, badManifest }

    public static func encode(manifest: PlaceManifest, map: Data) throws -> Data {
        let m = try manifest.encoded()
        var out = Data()
        out.reserveCapacity(9 + m.count + map.count)
        out.append(magic)
        out.append(version)
        let n = UInt32(m.count)
        out.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        out.append(m)
        out.append(map)
        return out
    }

    /// Manifest + the world-map bytes.
    public static func decode(_ d: Data) throws -> (PlaceManifest, Data) {
        let b = [UInt8](d.prefix(9))
        guard b.count >= 4, Data(b[0..<4]) == magic else { throw CodecError.notAPlace }
        guard b.count == 9 else { throw CodecError.truncated }
        guard b[4] == version else { throw CodecError.badVersion(b[4]) }
        let n = Int(b[5]) << 24 | Int(b[6]) << 16 | Int(b[7]) << 8 | Int(b[8])
        let start = d.startIndex + 9
        guard d.count >= 9 + n else { throw CodecError.truncated }
        guard let m = try? PlaceManifest.decode(d.subdata(in: start..<(start + n))) else { throw CodecError.badManifest }
        return (m, d.subdata(in: (start + n)..<d.endIndex))
    }
}

public enum PlaceNaming {
    /// "Area N" with the smallest N not already used.
    public static func nextAreaName(existing: [String]) -> String {
        let used = Set(existing.compactMap { n -> Int? in
            guard n.hasPrefix("Area ") else { return nil }
            return Int(n.dropFirst(5))
        })
        var k = 1
        while used.contains(k) { k += 1 }
        return "Area \(k)"
    }

    /// A clean display name (trimmed, ≤ 40 chars), nil when empty.
    public static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(40))
    }
}

/// Which saved place to try first on launch, then next.
public enum PlaceRanking {
    /// Places with this many timeouts in a row go after the others (still tried: it may be the right one).
    public static let demoteAfterFails = 3

    /// Order: hint match (same Wi-Fi SSID, or within 80 m by GPS) first, then not-demoted before demoted, then the most
    /// recently used. Places with no map bytes are skipped.
    public static func order(_ places: [PlaceManifest], hint: PlaceHints? = nil) -> [String] {
        func match(_ p: PlaceManifest) -> Bool {
            guard let h = hint, let ph = p.hints else { return false }
            if let a = h.ssid, let b = ph.ssid, !a.isEmpty, a == b { return true }
            if let la = h.lat, let lo = h.lon, let pla = ph.lat, let plo = ph.lon {
                return metres(la, lo, pla, plo) <= 80
            }
            return false
        }
        return places.filter { $0.mapBytes > 0 }.sorted { a, b in
            let ma = match(a), mb = match(b)
            if ma != mb { return ma }
            let da = a.failStreak >= demoteAfterFails, db = b.failStreak >= demoteAfterFails
            if da != db { return !da }
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            return a.id < b.id
        }.map { $0.id }
    }

    static func metres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, d = Double.pi / 180
        let dlat = (lat2 - lat1) * d, dlon = (lon2 - lon1) * d
        let a = sin(dlat / 2) * sin(dlat / 2) + cos(lat1 * d) * cos(lat2 * d) * sin(dlon / 2) * sin(dlon / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}

/// The relaunch state machine (HUD banner + "try the next map"). Pure: fed tracking codes and the clock.
///  fresh            — no saved place (or the user started a new one): sim allowed, nothing to restore
///  relocalizing     — running with a saved map as initialWorldMap; sim hidden; after `timeout` s → next candidate
///  localized        — ARKit relocalized: restore the place's entities
///  waiting          — every candidate timed out once: keep cycling, banner offers Pick place / Start new
public enum RelocPhase: Equatable {
    case fresh
    case relocalizing(place: String, since: Double)
    case localized(place: String, seconds: Double)
}

public enum RelocAction: Equatable {
    case none
    case localized(place: String, seconds: Double)
    case tryNext(place: String, failed: String)          // re-run the session with the next map
}

public struct RelocTracker: Equatable {
    public static let timeout = 20.0
    /// ARKit says "normal" a moment before the anchors move into place on some launches; never call it localized in
    /// the first half second of a run.
    public static let minSettle = 0.5
    public private(set) var phase: RelocPhase = .fresh
    public private(set) var candidates: [String] = []
    public private(set) var index = 0
    public private(set) var rounds = 0                   // full passes over the candidates without success
    public private(set) var sawRelocalizing = false
    public private(set) var lastReason = ""
    public var pinned = false                            // the user picked this place: no automatic switching

    public init() {}

    public var current: String? {
        if case .relocalizing(let p, _) = phase { return p }
        if case .localized(let p, _) = phase { return p }
        return nil
    }

    public var isLocalized: Bool { if case .localized = phase { return true } else { return false } }
    public var isRelocalizing: Bool { if case .relocalizing = phase { return true } else { return false } }

    /// Start with ranked candidates. Returns the place to load first (nil = nothing saved → fresh).
    public mutating func begin(candidates c: [String], now: Double) -> String? {
        candidates = c
        index = 0
        rounds = 0
        pinned = false
        guard let first = c.first else { phase = .fresh; return nil }
        start(first, now: now)
        return first
    }

    /// The user picked a place: load it and stay on it.
    public mutating func pick(_ place: String, now: Double) {
        if let i = candidates.firstIndex(of: place) { index = i } else { candidates.insert(place, at: 0); index = 0 }
        pinned = true
        start(place, now: now)
    }

    /// The user chose "Start new place": no relocalization, the next save creates a place.
    public mutating func startFresh() {
        phase = .fresh
        pinned = false
    }

    private mutating func start(_ place: String, now: Double) {
        phase = .relocalizing(place: place, since: now)
        sawRelocalizing = false
        lastReason = ""
    }

    /// The session actually re-ran with the map (the file load took a moment): time from here.
    public mutating func runStarted(now: Double) {
        guard case .relocalizing(let p, _) = phase else { return }
        start(p, now: now)
    }

    /// ARKit tracking changed (TrackingStatus.code: "normal", "limited:relocalizing", …).
    public mutating func tracking(_ code: String, now: Double) -> RelocAction {
        guard case .relocalizing(let p, let since) = phase else { return .none }
        if code.hasPrefix("limited:") {
            lastReason = String(code.dropFirst(8))
            if code == "limited:relocalizing" { sawRelocalizing = true }
            return .none
        }
        guard code == "normal", now - since >= Self.minSettle else { return .none }
        let secs = now - since
        phase = .localized(place: p, seconds: secs)
        return .localized(place: p, seconds: secs)
    }

    /// Clock tick (HUD 2 Hz): a candidate that has not localized after `timeout` s gives way to the next.
    public mutating func tick(now: Double) -> RelocAction {
        guard case .relocalizing(let p, let since) = phase, !pinned, candidates.count > 1,
              now - since >= Self.timeout else { return .none }
        index += 1
        if index >= candidates.count { index = 0; rounds += 1 }
        let next = candidates[index]
        start(next, now: now)
        return .tryNext(place: next, failed: p)
    }

    /// Seconds spent on the current try.
    public func elapsed(now: Double) -> Double {
        if case .relocalizing(_, let since) = phase { return max(0, now - since) }
        return 0
    }
}
