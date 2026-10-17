import Foundation

// 10.2 "Am I localized?" pill (owner: "I may open the app in any place, but don't necessarily want to record. Can I have
// the localized as a status pill at the top margin to see if it's localized?"). Localization against the house map runs
// whenever the app is open and online (MapLocalizer), independent of recording / sim; this is the pure part: the pill's
// wording + tone, the error estimate, the "not in map" rule and the battery-friendly attempt cadence.

/// Where the localizer is (fed by MapLocalizer, read by the pill).
public enum LocPhase: String, Equatable {
    case off            // no server configured / AR not running
    case searching      // sending attempts, no lock yet
    case locked         // T_map_arkit known (server lock, or a saved place's cached alignment)
}

/// The pill's colour: green = localized, amber = finding you, grey = offline / not in the map.
public enum LocPillTone: String, Equatable {
    case good, working, idle
}

public struct LocPillInput: Equatable {
    public var online: Bool
    public var phase: LocPhase
    public var mapID: String
    public var version: Int?
    public var method: String?          // lock source (10.4): geometry | visual | both, or an older method; nil = cached
    public var source: String           // "server" | "place_cache" | ""
    public var errCm: Double?           // LocPill.errorEstimate
    public var searchSeconds: Double
    public var attempts: Int
    public var matches: Int
    public var lastFixAge: Double?      // s since the last accepted fix (lock / refinement)
    public var trackingCode: String     // 10.3: ARKit TrackingStatus.code ("normal", "limited:excessiveMotion", …)
    public var notInMap: Bool           // LocPill.notInMap, or the server said 404 (other map)
    public var savedPlace: SavedPlaceNote?   // 10.3: a saved ARWorldMap tried / matched / active (secondary info)
    public var hint: String?            // 10.4: the server's search hint ("Turn to see a corner of the room")
    public var retry: String?           // 10.6.x: "retrying (server slow)" after an error / timeout (LocRetry.note)
    public var paused: String?          // 10.6.x: why no attempt can run now ("Scans open", "AR paused", …)

    public init(online: Bool, phase: LocPhase, mapID: String = "site", version: Int? = nil, method: String? = nil,
                source: String = "", errCm: Double? = nil, searchSeconds: Double = 0, attempts: Int = 0,
                matches: Int = 0, lastFixAge: Double? = nil, trackingCode: String = "normal", notInMap: Bool = false,
                savedPlace: SavedPlaceNote? = nil, hint: String? = nil, retry: String? = nil, paused: String? = nil) {
        self.online = online; self.phase = phase; self.mapID = mapID; self.version = version; self.method = method
        self.source = source; self.errCm = errCm; self.searchSeconds = searchSeconds; self.attempts = attempts
        self.matches = matches; self.lastFixAge = lastFixAge; self.trackingCode = trackingCode; self.notInMap = notInMap
        self.savedPlace = savedPlace; self.hint = hint; self.retry = retry; self.paused = paused
    }

    public var trackingOK: Bool { trackingCode == "normal" }

    /// 10.3: ARKit is limited in a way the user must act on. Not: the first second of a session (initializing), nor
    /// "relocalizing" while a saved map is being tried on purpose (that is FINDING YOU, with the place as a detail).
    public var trackingBlocked: Bool {
        if trackingCode == "normal" || trackingCode == "limited:initializing" { return false }
        if trackingCode == "limited:relocalizing", case .trying = savedPlace?.state { return false }
        return true
    }
}

/// What the pill shows: one line + the detail card's rows.
public struct LocPillState: Equatable {
    public var tone: LocPillTone
    public var text: String
    public var rows: [String]
    public init(tone: LocPillTone, text: String, rows: [String]) { self.tone = tone; self.text = text; self.rows = rows }
}

public enum LocPill {
    /// No match after this long and this many attempts: "NOT IN MAP" (grey) and the slow retry cadence.
    public static let notInMapSeconds = 45.0
    public static let notInMapAttempts = 25

    public static func notInMap(searchSeconds: Double, attempts: Int, matches: Int) -> Bool {
        matches == 0 && attempts >= notInMapAttempts && searchSeconds >= notInMapSeconds
    }

    /// 10.4: "geometry" (the phone's LiDAR on the house mesh), "geometry+visual" (both agree / visual refined on the
    /// mesh), "visual" (photo match only), "saved place" for a cached alignment not yet confirmed by the server.
    public static func methodLabel(method: String?, source: String) -> String {
        if source == "place_cache" { return "saved place" }
        if source == "carried" { return "re-anchored" }
        return LocMethod.label(method)
    }

    /// ± error estimate (cm) shown on the pill: the larger of the lock's fix spread and the mesh ICP residual, never
    /// below a floor per method — measured on site v10 (API §5.6b): mesh-refined fixes put the phone's depth on the mesh
    /// within ~1.5 cm RMSE, the visual answer is ~3 cm off the mesh (graph vs mesh), a cached place alignment is only as
    /// good as that place's last lock + ARKit relocalization (~5 cm).
    public static func errorEstimate(spreadCm: Double?, rmseCm: Double?, method: String?, source: String) -> Double? {
        let floor: Double
        if source == "place_cache" { floor = 5 }
        else if source == "carried" { floor = 8 }         // 10.3: carried over a session reset, until the server confirms
        else if source == "server" { floor = LocMethod.usesGeometry(method) ? 2 : 3 }
        else { return nil }
        let measured = max(spreadCm ?? 0, rmseCm ?? 0)
        return max(floor, measured.isFinite ? measured : floor)
    }

    public static func cm(_ v: Double) -> String { String(format: "±%.0f cm", max(1, v.rounded(.up))) }

    public static func age(_ s: Double) -> String {
        if s < 1 { return "just now" }
        if s < 90 { return String(format: "%.0f s ago", s) }
        if s < 5400 { return String(format: "%.0f min ago", s / 60) }
        return String(format: "%.1f h ago", s / 3600)
    }

    /// What the user should do when ARKit is limited (the pill's headline then).
    public static func trackingAdvice(_ code: String) -> String {
        switch code {
        case "limited:excessiveMotion": return "move slowly"
        case "limited:insufficientFeatures": return "point at detail"
        case "limited:relocalizing": return "look around slowly"
        case "notAvailable": return "camera blocked"
        default: return "move slowly"
        }
    }

    /// 10.3: ONE state for the top pill, from both systems (the map-server lock and ARKit tracking); a saved place is
    /// only ever a detail row.
    public static func make(_ i: LocPillInput) -> LocPillState {
        let map = MapLocText.mapName(i.mapID)
        let placeRow = i.savedPlace.map { [$0.row] } ?? []
        if !i.online && i.phase != .locked {
            return LocPillState(tone: .idle, text: "OFFLINE",
                                rows: ["No map server reachable (Wi-Fi / Tailscale)", "Localization resumes when it is back"]
                                    + placeRow)
        }
        if i.trackingBlocked && i.phase != .off {
            var rows = ["ARKit tracking is limited (\(i.trackingCode.replacingOccurrences(of: "limited:", with: ""))): the sim waits"]
            if i.phase == .locked {
                rows.append("House map lock kept (\(map)\(i.version.map { " v\($0)" } ?? "")): bodies resume when tracking is back")
            } else {
                rows.append(MapLocText.searching(mapID: i.mapID, seconds: i.searchSeconds, attempts: i.attempts,
                                                 matches: i.matches))
            }
            return LocPillState(tone: .working, text: "TRACKING LIMITED — " + trackingAdvice(i.trackingCode),
                                rows: rows + placeRow)
        }
        switch i.phase {
        case .locked:
            var t = "LOCALIZED · \(map)"
            if let v = i.version { t += " v\(v)" }
            t += " · " + methodLabel(method: i.method, source: i.source)
            if let e = i.errCm { t += " · " + cm(e) }
            var rows = ["Map: \(map)" + (i.version.map { " v\($0)" } ?? ""),
                        "Method: " + methodDetail(method: i.method, source: i.source)]
            if let e = i.errCm { rows.append("Error estimate: \(cm(e))") }
            if let a = i.lastFixAge { rows.append("Last fix: \(age(a))") }
            if !i.online { rows.append("Server offline: holding the last lock (ARKit keeps tracking)") }
            return LocPillState(tone: .good, text: t, rows: rows + placeRow)
        case .searching:
            if i.notInMap {
                return LocPillState(tone: .idle, text: "NOT IN MAP",
                                    rows: ["No match in the \(map) map after \(Int(i.searchSeconds)) s / \(i.attempts) tries",
                                           "This room may not be mapped yet: Map mesh can add it",
                                           "Still retrying slowly · Retry / Pick place below"] + placeRow)
            }
            var rows = [MapLocText.searching(mapID: i.mapID, seconds: i.searchSeconds, attempts: i.attempts,
                                             matches: i.matches)]
            if let h = i.hint, !h.isEmpty { rows.append("Tip: " + h) }
            var text = String(format: "FINDING YOU… %.0f s", max(0, i.searchSeconds))
            if let p = i.paused {                       // 10.6.x: never a stale "finding" while nothing can run
                text = "FINDING YOU · paused (\(p))"
                rows.insert("Localization resumes by itself when this ends", at: 0)
            } else if let r = i.retry {
                text += " · " + r
                rows.insert("The map server did not answer: retrying with backoff (2, 4, 8, 10 s)", at: 0)
            }
            return LocPillState(tone: .working, text: text, rows: rows + placeRow)
        case .off:
            return LocPillState(tone: .idle, text: i.online ? "NOT LOCALIZED" : "OFFLINE",
                                rows: ["Localization starts when the AR view runs"])
        }
    }

    public static func methodDetail(method: String?, source: String) -> String {
        switch methodLabel(method: method, source: source) {
        case "saved place": return "saved place (confirming with the map server)"
        case "re-anchored": return "re-anchored over an AR reset (confirming with the map server)"
        case "geometry": return "geometry (LiDAR on the house mesh, works in the dark)"
        case "geometry+visual": return "geometry + visual (LiDAR on the house mesh, photo match agrees)"
        default: return "visual (photo match)"
        }
    }
}

/// Battery / thermal friendly attempt cadence (10.2: localization runs whenever the app is open): fast until locked,
/// a short burst of refinements, then an occasional refresh. nil = no attempt (never: the pill must stay truthful).
public enum LocCadence {
    public static let searching = 1.0           // s between attempts until locked
    /// 11.1: the first seconds of a search go twice as fast (one request in flight, so the server's answer time still
    /// paces it): a visual match on a live visit comes ~1 in 5-15 attempts, so more distinct views early = a sooner lock.
    public static let searchingFast = 0.5
    public static let fastWindowS = 20.0
    public static let notInMap = 6.0            // after LocPill.notInMap: still retrying, slowly
    public static let refining = 8.0            // the first LocalizeCadence.refineCount refinements after a lock
    public static let refresh = 60.0            // then one refresh a minute
    public static let recordingFactor = 2.0     // recording owns the thermal budget
    public static let hotFactor = 3.0           // thermal serious

    public static func interval(locked: Bool, refinements: Int, thermalSerious: Bool, recording: Bool,
                                notInMap: Bool, searchSeconds: Double = .infinity) -> Double {
        var f = 1.0
        if thermalSerious { f *= hotFactor }
        if recording { f *= recordingFactor }
        if !locked {
            if notInMap { return Self.notInMap * f }
            return (searchSeconds < fastWindowS && f == 1 ? searchingFast : searching) * f
        }
        if refinements < LocalizeCadence.refineCount && !thermalSerious { return refining * (recording ? recordingFactor : 1) }
        return refresh * f
    }

    /// Depth (`.sceneDepth`) stays on while searching / refining; between refreshes it is switched off (unless
    /// mapping / recording / Live map want it) and back on a few seconds before the next refresh is due.
    public static let depthLeadS = 3.0
    public static func depthNeeded(locked: Bool, refinements: Int, sinceLastAttempt: Double, thermalSerious: Bool,
                                   recording: Bool) -> Bool {
        if !locked { return true }
        let every = interval(locked: true, refinements: refinements, thermalSerious: thermalSerious, recording: recording,
                             notInMap: false)
        if every <= refining * recordingFactor { return true }
        return sinceLastAttempt >= every - depthLeadS
    }
}


/// 10.6.x (owner 2026-10-16: one timeout and the app never placed him): the master-map localize loop never stops
/// while unplaced. After any error / timeout the next attempt waits 2, 4, 8, then 10 s (cap); foreground, a network
/// change, a new map version and an AR resume restart it at once. The first request gets 30 s (a cold server warms
/// a freshly built map version), later ones 15 s. Only a lock ends the search (the tracking cadence takes over).
public struct LocRetry: Equatable {
    public private(set) var failures = 0
    public private(set) var requests = 0
    public private(set) var nextAt = 0.0
    public private(set) var lastWhy: String?
    public static let firstTimeout = 30.0
    public static let timeout = 15.0
    public static let cap = 10.0
    public init() {}

    /// Timeout for the next request.
    public var requestTimeout: Double { requests == 0 ? Self.firstTimeout : Self.timeout }

    /// Backoff after `n` consecutive failures: 2, 4, 8, 10, 10 … s.
    public static func delay(failures n: Int) -> Double {
        n <= 0 ? 0 : min(cap, 2 * pow(2, Double(min(n, 8) - 1)))
    }

    /// Why it failed, for the pill / log: "server slow" (timeout), "server warming" (503/504), "offline", …
    public static func why(status: Int, error: String?) -> String {
        if status == 503 || status == 504 { return "server warming" }
        if status == 404 { return "map not found" }
        if status == 0 {
            let e = (error ?? "").lowercased()
            if e.contains("timed out") || e.contains("timeout") { return "server slow" }
            if e.contains("offline") || e.contains("not connected") || e.contains("network") || e.contains("connection") {
                return "offline"
            }
            return "no answer"
        }
        return "server error \(status)"
    }

    public mutating func sent() { requests += 1 }

    /// A failed request: when the next one may go, and why.
    @discardableResult
    public mutating func failed(status: Int, error: String?, now: Double) -> (delay: Double, why: String) {
        failures += 1
        let w = Self.why(status: status, error: error)
        lastWhy = w
        let d = Self.delay(failures: failures)
        nextAt = now + d
        return (d, w)
    }

    public mutating func succeeded() {
        failures = 0
        lastWhy = nil
        nextAt = 0
    }

    /// Foreground / network back / new map version / AR resumed: try again now (the backoff starts over).
    /// true = it was waiting (so the resume changed something).
    @discardableResult
    public mutating func resume(now: Double) -> Bool {
        let waiting = nextAt > now || failures > 0
        failures = 0
        nextAt = now
        return waiting
    }

    public func due(now: Double) -> Bool { now >= nextAt }

    /// The pill's suffix while it is retrying.
    public var note: String? { lastWhy.map { "retrying (\($0))" } }
}
