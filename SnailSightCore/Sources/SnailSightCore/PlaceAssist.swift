import Foundation

// 10.3 master-map-first localization (owner on 10.0.105, standing in the bathroom with "Area 1" — a bedroom ARWorldMap —
// loaded at launch: "Why do I see localized and localizing at the same time? Usually when it's like this, I need to
// select the map again."). ARKit sat in limited/relocalizing for a place the phone was not in (sim paused, no mesh)
// while the map server had already locked the phone on the master house map.
//
// Now:
//  - every launch / reset starts a CLEAN ARKit session (tracking normal at once) and localizes against the master map;
//  - a saved ARWorldMap is only an accelerator: tried when the server has not locked within `serverGrace` s AND there is
//    evidence the phone is in that place (the last server fix lies inside the place's bounds), aborted after
//    `autoTimeout` s of relocalizing (a re-run without the world map);
//  - a server lock that arrives while a saved map is still relocalizing cancels it at once (the lock is carried over
//    the session reset, see FrameCarry);
//  - saved places' animals are moved into the master map (PlaceMigration), so dropping the world map loses nothing.
// Pure: fed the clock, tracking codes and the server lock; the app (PlaceController) does the ARKit side.

public enum PlaceAssistPhase: Equatable {
    case clean                                                // no world map in the session (the default)
    case trying(place: String, since: Double, picked: Bool)   // relocalizing a saved ARWorldMap
    case matched(place: String, seconds: Double)              // ARKit relocalized into it
}

public enum PlaceAssistAction: Equatable {
    case none
    case tryPlace(String)                                     // re-run the session with this place's world map
    case abort(place: String, reason: String, keepLock: Bool) // re-run WITHOUT the world map (keepLock: carry the lock)
    case matched(place: String, seconds: Double)              // restore the place's bodies
}

public struct PlaceAssist: Equatable {
    /// The server gets this long to lock a clean session before a saved map is tried.
    public static let serverGrace = 5.0
    /// An automatic try that has not relocalized after this long is aborted.
    public static let autoTimeout = 8.0
    /// A place the user picked gets longer (they are probably walking to it).
    public static let pickTimeout = 20.0
    /// ARKit says "normal" a moment before the anchors move on some launches: never call it matched before this.
    public static let minSettle = 0.5

    public private(set) var phase: PlaceAssistPhase = .clean
    public private(set) var sessionStart = 0.0                // the current clean run (grace counted from here)
    public private(set) var tried: Set<String> = []           // automatic tries this session (each place once)
    public private(set) var lastReason = ""
    public private(set) var sawRelocalizing = false

    public init() {}

    public var current: String? {
        switch phase {
        case .clean: return nil
        case .trying(let p, _, _), .matched(let p, _): return p
        }
    }
    public var isTrying: Bool { if case .trying = phase { return true } else { return false } }
    public var isMatched: Bool { if case .matched = phase { return true } else { return false } }
    public var isPicked: Bool { if case .trying(_, _, let p) = phase { return p } else { return false } }

    public func elapsed(now: Double) -> Double {
        if case .trying(_, let since, _) = phase { return max(0, now - since) }
        return 0
    }

    public func timeout(picked: Bool) -> Double { picked ? Self.pickTimeout : Self.autoTimeout }

    /// Launch / Reset AR: a clean session, every place may be tried again.
    public mutating func reset(now: Double) {
        phase = .clean
        sessionStart = now
        tried = []
        lastReason = ""
        sawRelocalizing = false
    }

    /// The session re-ran with the map (the file load took a moment): time the try from here.
    public mutating func runStarted(now: Double) {
        guard case .trying(let p, _, let picked) = phase else { return }
        phase = .trying(place: p, since: now, picked: picked)
    }

    /// Is an automatic try possible now? (The caller computes the evidence only then.)
    public func wantsEvidence(now: Double, serverLocked: Bool) -> Bool {
        guard case .clean = phase, !serverLocked else { return false }
        return now - sessionStart >= Self.serverGrace
    }

    /// 2 Hz clock. `evidence`: the saved place the phone is probably in (PlaceEvidence), nil = none.
    public mutating func tick(now: Double, serverLocked: Bool, evidence: String?) -> PlaceAssistAction {
        switch phase {
        case .trying(let p, let since, let picked):
            if serverLocked {                                  // the lock event was missed: same rule
                return serverLock(now: now)
            }
            guard now - since >= timeout(picked: picked) else { return .none }
            phase = .clean
            sessionStart = now
            return .abort(place: p, reason: "timeout", keepLock: false)
        case .clean:
            guard wantsEvidence(now: now, serverLocked: serverLocked), let e = evidence, !tried.contains(e) else {
                return .none
            }
            tried.insert(e)
            start(e, now: now, picked: false)
            return .tryPlace(e)
        case .matched:
            return .none
        }
    }

    /// The map server locked this session. A saved map still relocalizing is cancelled (no need to re-select it).
    public mutating func serverLock(now: Double) -> PlaceAssistAction {
        guard case .trying(let p, _, _) = phase else { return .none }
        phase = .clean
        sessionStart = now
        return .abort(place: p, reason: "server_locked", keepLock: true)
    }

    /// ARKit tracking changed (TrackingStatus.code).
    public mutating func tracking(_ code: String, now: Double) -> PlaceAssistAction {
        guard case .trying(let p, let since, _) = phase else { return .none }
        if code.hasPrefix("limited:") {
            lastReason = String(code.dropFirst(8))
            if code == "limited:relocalizing" { sawRelocalizing = true }
            return .none
        }
        guard code == "normal", now - since >= Self.minSettle else { return .none }
        let secs = now - since
        phase = .matched(place: p, seconds: secs)
        return .matched(place: p, seconds: secs)
    }

    /// The user picked a place. Refused (`.none`) while the house map holds a lock: it is the better fix, and the
    /// place's animals are in the house map already.
    public mutating func pick(_ place: String, now: Double, serverLocked: Bool) -> PlaceAssistAction {
        guard !serverLocked else { return .none }
        if case .matched(let p, _) = phase, p == place { return .none }
        tried.insert(place)
        start(place, now: now, picked: true)
        return .tryPlace(place)
    }

    /// The user cancelled a try / started a new place / deleted the place being tried.
    public mutating func cancel(now: Double) -> PlaceAssistAction {
        let p = current
        let wasTrying = isTrying
        phase = .clean
        sessionStart = now
        guard wasTrying, let p else { return .none }
        return .abort(place: p, reason: "cancelled", keepLock: false)
    }

    private mutating func start(_ place: String, now: Double, picked: Bool) {
        phase = .trying(place: place, since: now, picked: picked)
        lastReason = ""
        sawRelocalizing = false
    }
}

// MARK: evidence

/// The last accepted server fix: where the phone was in the master map (map frame, z-up metres). Persisted, so the next
/// launch knows which saved place could help.
public struct LastMapFix: Codable, Equatable {
    public var mapID: String
    public var position: [Double]
    public var at: Double
    public init(mapID: String, position: [Double], at: Double) { self.mapID = mapID; self.position = position; self.at = at }
}

public enum PlaceEvidence {
    /// An older fix says nothing about where the phone is now.
    public static let maxAge = 6 * 3600.0
    /// Horizontal slack around a place's mapped box (m).
    public static let marginM = 0.75
    /// Vertical slack (m): the same floor, not the one above / below.
    public static let floorBandM = 1.5

    /// Is the map point inside the place's world-map box (place ARKit frame, y up), carried with the place's alignment?
    public static func contains(_ p: PlaceManifest, alignment al: MapAlignment, mapPoint: [Double]) -> Bool {
        guard let c = p.mapCenter, let e = p.mapExtent, c.count == 3, e.count == 3, mapPoint.count == 3 else { return false }
        let q = al.toArkit(map: mapPoint)
        return abs(q[0] - c[0]) <= e[0] / 2 + marginM && abs(q[2] - c[2]) <= e[2] / 2 + marginM
            && abs(q[1] - c[1]) <= e[1] / 2 + floorBandM
    }

    /// The saved place the phone is probably in, or nil (no recent fix, no place with a known alignment contains it).
    /// Several match → the smallest box (most specific room), then the most recently used.
    public static func candidate(places: [PlaceManifest], alignments: [String: MapAlignment], fix: LastMapFix?,
                                 now: Double) -> String? {
        guard let f = fix, now - f.at <= maxAge, now >= f.at - 60 else { return nil }
        let hits = places.filter { p in
            guard p.mapBytes > 0, let al = alignments[p.id], al.mapID == f.mapID else { return false }
            return contains(p, alignment: al, mapPoint: f.position)
        }
        func area(_ p: PlaceManifest) -> Double { (p.mapExtent?[0] ?? 0) * (p.mapExtent?[2] ?? 0) }
        return hits.sorted { a, b in
            if area(a) != area(b) { return area(a) < area(b) }
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            return a.id < b.id
        }.first?.id
    }
}

// MARK: carrying a lock over a session reset

/// Aborting a saved map needs a session re-run with `.resetTracking`: the new ARKit frame starts at the phone, gravity
/// aligned, heading = the phone's. The camera pose just before (old frame) and just after (new frame) is the same
/// physical pose, so T_old←new = T_old_cam · T_new_cam⁻¹ — reduced to yaw + translation (both frames are y-up).
public enum FrameCarry {
    public static func oldFromNew(oldCam: Mat4, newCam: Mat4) -> Mat4 {
        let full = oldCam * newCam.inverse
        // rotation about +y: [[c, 0, s], [0, 1, 0], [-s, 0, c]] → yaw from the carried x axis
        let yaw = atan2(-full[2, 0], full[0, 0])
        let c = cos(yaw), s = sin(yaw)
        let po = oldCam.translation, pn = newCam.translation
        let rp = [c * pn[0] + s * pn[2], pn[1], -s * pn[0] + c * pn[2]]
        let t = [po[0] - rp[0], po[1] - rp[1], po[2] - rp[2]]
        return Mat4([c, 0, s, t[0],
                     0, 1, 0, t[1],
                     -s, 0, c, t[2],
                     0, 0, 0, 1])
    }

    /// The map ← new-ARKit alignment from the old one.
    public static func carry(_ al: MapAlignment, oldCam: Mat4, newCam: Mat4, now: Double) -> MapAlignment {
        var a = al
        a.T = al.T * oldFromNew(oldCam: oldCam, newCam: newCam)
        a.at = now
        return a
    }
}

// MARK: saved places' animals → the master map

public enum PlaceMigration {
    /// Entities of saved places that the master map does not have yet (and never had: `known` = ids this phone has seen
    /// in the map, so a body deleted from the map is not resurrected from an old place file). Each place's records are
    /// in that place's ARKit frame (sim anchors are pure translations), carried with the place's cached alignment.
    public static func orphans(places: [PlaceManifest], alignments: [String: MapAlignment], mapID: String,
                               present: Set<String>, known: Set<String>, agentID: String) -> [MapEntity] {
        var out: [MapEntity] = []
        var seen = present.union(known)
        for p in places.sorted(by: { $0.updated > $1.updated }) {     // the newest copy of a body wins
            guard let al = alignments[p.id], al.mapID == mapID else { continue }
            for r in p.entities where !seen.contains(r.id) && r.anchor.count == 3 {
                seen.insert(r.id)
                let pose = al.mapPose(arkit: r.anchor, groundYaw: 0)
                out.append(MapEntity.from(r, pose: pose, mapVersion: al.version, agentID: agentID, placeID: p.id))
            }
        }
        return out
    }

    /// PUT /v1/maps/{map}/entities/{id} body (one entity, its own map version).
    public static func putBody(_ e: MapEntity) throws -> Data {
        try JSONEncoder().encode(One(kind: e.kind, pose: e.pose, mapVersion: e.mapVersion, record: e.record,
                                     agentID: e.agentID, placeID: e.placeID, name: e.name))
    }

    struct One: Encodable {
        var kind: String
        var pose: MapPose
        var mapVersion: Int
        var record: SimEntityRecord?
        var agentID: String?
        var placeID: String?
        var name: String?
        enum CodingKeys: String, CodingKey {
            case kind, pose, record, name
            case mapVersion = "map_version", agentID = "agent_id", placeID = "place_id"
        }
    }
}

// MARK: the saved-place line (secondary info in the status card, never the headline)

public struct SavedPlaceNote: Equatable {
    public enum State: Equatable {
        case trying(seconds: Double, timeout: Double)
        case matched
        case active                         // saved / grown in this session
    }
    public var name: String
    public var state: State
    public init(name: String, state: State) { self.name = name; self.state = state }

    /// One line for the localization card.
    public var row: String {
        switch state {
        case .trying(let s, let t): return String(format: "Saved place %@: also trying its AR map · %.0f / %.0f s", name, s, t)
        case .matched: return "Saved place \(name): AR map matched"
        case .active: return "Saved place \(name)"
        }
    }
}

public enum PlaceLineTone: String, Equatable { case neutral, working, good }

public struct PlaceLine: Equatable {
    public var title: String
    public var detail: String
    public var tone: PlaceLineTone
    public var trying: Bool

    public init(title: String, detail: String, tone: PlaceLineTone, trying: Bool) {
        self.title = title; self.detail = detail; self.tone = tone; self.trying = trying
    }

    /// The place card. While the house map holds a lock a saved place is never shown as something to wait for.
    public static func make(note: SavedPlaceNote?, masterLocked: Bool, savedCount: Int, bodies: Int,
                            version: Int? = nil) -> PlaceLine {
        guard let n = note else {
            if savedCount == 0 {
                return PlaceLine(title: "NO SAVED PLACE", detail: "Animals live in the house map once localized",
                                 tone: .neutral, trying: false)
            }
            return PlaceLine(title: "SAVED PLACES · not loaded",
                             detail: masterLocked ? "Not needed: localized on the house map"
                                                  : "Places ▸ load one if the house map cannot find you",
                             tone: .neutral, trying: false)
        }
        switch n.state {
        case .trying(let s, let t):
            return PlaceLine(title: String(format: "SAVED PLACE · trying %@ · %.0f s", n.name, s),
                             detail: String(format: "Look around where you saved it · gives up after %.0f s or when the house map finds you", t),
                             tone: .working, trying: true)
        case .matched:
            return PlaceLine(title: "SAVED PLACE · \(n.name)",
                             detail: "AR map matched · \(bodies) sim bod\(bodies == 1 ? "y" : "ies") · Save place keeps changes",
                             tone: .good, trying: false)
        case .active:
            return PlaceLine(title: "SAVED PLACE · \(n.name)",
                             detail: version.map { "Saved v\($0) · Save place keeps changes" } ?? "Save place keeps changes",
                             tone: .good, trying: false)
        }
    }
}
