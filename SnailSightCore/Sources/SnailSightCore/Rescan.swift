import Foundation

// SnailSight 12.27 Rescan area (owner 2026-11-14: one careful continuous scan becomes that AREA's map; indoors a room,
// outdoors the region the scan covered well, so no room model is required). Client side of the server's rescan API
// (snailCOP docs/SNAILSIGHT-API.md §5.17, server 2026-11-14):
//
//   POST /v1/maps/{map}/rescan             {kind: "area", agent_id, client_rescan_id, name?, level?, by}
//                                          -> 201 {rescan_id, state: "open", guide}; 409 {rescan_id} = one already open
//   (stream the walk as usual: the hello carries `rescan_id`; 12.27 also puts it in every keyframe header)
//   POST /v1/maps/{map}/rescan/{id}/finish {stream_ids, recorded}  -> 202 {state: "waiting"}
//   POST /v1/maps/{map}/rescan/{id}/cancel {why}
//   GET  /v1/maps/{map}/rescan/{id}        -> {state, stage, coverage{live, good_m2, area_m2, cells[]}, quality{checks[]},
//                                              before_after{cells}, preview{portal}, result{decision, rev, why, rescan_advice}}
// Extra fields this client sends (setting, geo, app_version, keyframes, coverage) are ignored by the server; the
// parser also accepts the pre-§5.17 draft names (coverage_pct, published_rev, held_reason, preview before / after urls).
//
// A server without the API (404 / 405 / 501) or an unreachable one does not block the scan: it streams as a normal walk
// and the card says so (a queue outage costs the rescan, never the walk). Everything here is pure / injectable
// (RescanTests drive it against a mock server); the app side is Sources/Live/RescanController.

public enum RescanSetting: String, CaseIterable, Equatable {
    case indoor, outdoor
    public var title: String { self == .indoor ? "Room (indoors)" : "Area (outdoors)" }

    /// The short guidance before the scan.
    public var guidance: [String] {
        var g = [
            "Go slowly, no quick turns.",
            "Stay 1-2.5 m from surfaces and face them square-on.",
        ]
        switch self {
        case .indoor:
            g.append("Cover every wall, the floor and the ceiling, and the furniture and objects.")
            g.append("Start and end at the doorway, looking through it, so the room ties to the rest of the house.")
        case .outdoor:
            g.append("Cover the ground, walls, fences and the objects in the area.")
            g.append("Have the house wall or a fence in view at the start and at the end, so the area ties to the map.")
        }
        g.append("Points appear as you scan: grey gaps and faint points need another, closer look.")
        return g
    }
}

/// What a rescan is doing (the app's card + the log).
public enum RescanPhase: String, Equatable {
    case idle, creating, scanning, finishing, building, published, held, failed, local, cancelled

    public var terminal: Bool { [.published, .held, .failed, .local, .cancelled].contains(self) }
}

/// The server's rescan document (tolerant: the server lane may name fields slightly differently).
public struct RescanStatus: Equatable {
    public var id: String?
    public var state: String = ""
    public var phase: RescanPhase = .building
    public var coveragePct: Double?
    public var quality: String?
    public var qualityScore: Double?
    public var beforeURL: String?
    public var afterURL: String?
    public var viewAt: String?               // a CopView "x,y,z,d,yaw,pitch" for snailCOP
    public var portalURL: String?
    public var publishedRev: Int?
    public var reason: String?
    public var message: String?
    public var keyframes: Int?
    public var areaM2: Double?
    public var areaName: String?
    // §5.17
    public var stage: String?
    public var coverageLive = false
    public var goodM2: Double?
    public var portalPath: String?             // preview.portal "/?preview=<sha>"
    public var decision: String?
    public var islandID: String?
    public var advice: [String] = []
    public var failedChecks: [String] = []
    public var checks = 0
    public var beforeAfter: String?            // "duplicate 2.6 → 0.3 m² · ghost 9.1 → 1.2 % · …"
    public init() {}

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, !(v is Bool) { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber, !(v is Bool) { return n.stringValue }
        return nil
    }

    public static func phase(of state: String) -> RescanPhase? {
        switch state.lowercased() {
        case "open", "created", "scanning", "streaming", "active", "recording": return .scanning
        case "finishing", "queued", "pending", "building", "processing", "running", "waiting", "integrating", "candidate",
             "comparing", "checking", "publishing":
            return .building
        case "published", "done", "ready", "complete", "completed", "applied", "live", "island": return .published
        case "held", "rejected", "not_published", "blocked", "kept", "rolled-back", "rolled_back": return .held
        case "failed", "error", "expired", "aborted": return .failed
        case "cancelled", "canceled": return .cancelled
        default: return nil
        }
    }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    /// §5.17 before_after: the area cells summed (m²) / averaged (%, cm) into one line.
    static func beforeAfterLine(_ ba: [String: Any]?) -> String? {
        guard let cells = ba?["cells"] as? [String: Any], !cells.isEmpty else { return nil }
        let keys = ["dup_m2", "ghost_pct", "res_p90_cm", "holes_pct"]
        let labels = ["duplicate", "ghost", "residual p90", "holes"]
        let units = [" m²", " %", " cm", " %"]
        var bs = [Double](repeating: 0, count: 4), afs = [Double](repeating: 0, count: 4), ns = [Int](repeating: 0, count: 4)
        for (_, v) in cells {
            guard let c = v as? [String: Any], let b = c["before"] as? [String: Any], let a = c["after"] as? [String: Any] else { continue }
            for i in 0..<4 {
                guard let x = num(b[keys[i]]), let y = num(a[keys[i]]) else { continue }
                bs[i] += x; afs[i] += y; ns[i] += 1
            }
        }
        var parts: [String] = []
        for i in 0..<4 where ns[i] > 0 {
            let d = i == 0 ? 1.0 : Double(ns[i])                // m² sum; % / cm mean
            parts.append(labels[i] + " " + String(format: "%.1f", bs[i] / d) + " → " + String(format: "%.1f", afs[i] / d) + units[i])
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func parse(_ data: Data?) -> RescanStatus? {
        guard let d = data, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return parse(o)
    }

    public static func parse(_ top: [String: Any]) -> RescanStatus {
        let o = (top["rescan"] as? [String: Any]) ?? top
        var s = RescanStatus()
        s.id = str(o["rescan_id"]) ?? str(o["id"])
        s.state = str(o["state"]) ?? str(o["status"]) ?? ""
        if let p = phase(of: s.state) { s.phase = p }
        if let c = num(o["coverage_pct"]) ?? num(o["coverage"]) ?? num((o["coverage"] as? [String: Any])?["pct"]) {
            s.coveragePct = c <= 1.0 && num(o["coverage_pct"]) == nil ? c * 100 : c
        }
        if let cv = o["coverage"] as? [String: Any] {                     // §5.17
            s.coverageLive = cv["live"] as? Bool ?? false
            s.goodM2 = num(cv["good_m2"])
            s.areaM2 = num(cv["area_m2"])
            if s.coveragePct == nil, let cells = cv["cells"] as? [[String: Any]] {
                var sum = 0.0, n = 0
                for c in cells where (c["in_area"] as? Bool) ?? true {
                    if let v = num(c["cover"]) { sum += v; n += 1 }
                }
                if n > 0 { s.coveragePct = sum / Double(n) * 100 }
            }
        }
        s.stage = str(o["stage"])
        if let q = o["quality"] as? [String: Any] {
            s.quality = str(q["label"]) ?? str(q["verdict"]) ?? str(q["summary"])
            s.qualityScore = num(q["score"]) ?? num(q["value"])
            if let checks = q["checks"] as? [[String: Any]], !checks.isEmpty {    // §5.17 acceptance rows
                s.checks = checks.count
                for c in checks where (c["pass"] as? Bool) == false {
                    let n = str(c["name"]) ?? "?"
                    if let v = num(c["value"]), let l = num(c["limit"]) {
                        let unit = str(c["unit"]).map { " " + $0 } ?? ""
                        s.failedChecks.append(n + " " + fmt(v) + " (limit " + fmt(l) + unit + ")")
                    } else { s.failedChecks.append(n) }
                }
                if s.quality == nil { s.quality = "\(checks.count - s.failedChecks.count) of \(checks.count) checks pass" }
            }
        } else if let q = num(o["quality"]) {
            s.qualityScore = q
        } else {
            s.quality = str(o["quality"])
        }
        if s.quality == nil { s.quality = str(o["quality_label"]) }
        let pv = (o["preview"] as? [String: Any]) ?? (o["candidate"] as? [String: Any]) ?? [:]
        s.beforeURL = str(pv["before_url"]) ?? str(pv["before"]) ?? str(o["before_url"])
        s.afterURL = str(pv["after_url"]) ?? str(pv["after"]) ?? str(o["after_url"])
        s.viewAt = str(pv["at"]) ?? str(o["at"]) ?? str(o["view_at"])
        s.portalURL = str(pv["portal_url"]) ?? str(o["portal_url"])
        s.portalPath = str(pv["portal"])
        s.publishedRev = (num(o["published_rev"]) ?? num(o["rev"]) ?? num(pv["rev"])).map { Int($0) }
        s.reason = str(o["held_reason"]) ?? str(o["reason"]) ?? str(o["why"]) ?? str(o["error"])
        s.message = str(o["message"]) ?? str(o["note"])
        s.keyframes = (num(o["keyframes"]) ?? num(o["kf"])).map { Int($0) }
        if let a = o["area"] as? [String: Any] {
            s.areaM2 = num(a["m2"]) ?? num(a["area_m2"])
            s.areaName = str(a["name"])
        }
        if s.areaM2 == nil { s.areaM2 = num(o["area_m2"]) }
        if let r = o["result"] as? [String: Any] {                         // §5.17 result
            s.decision = str(r["decision"])
            if let rv = num(r["rev"]) { s.publishedRev = Int(rv) }
            if let w = str(r["why"]) { s.reason = w }
            s.islandID = str(r["island"])
            for a in (r["rescan_advice"] as? [[String: Any]]) ?? [] {
                guard let d = str(a["do"]) else { continue }
                s.advice.append((str(a["cell"]).map { $0 + ": " } ?? "") + d)
            }
            if let d = s.decision, let p = phase(of: d) { s.phase = p }
        }
        s.beforeAfter = beforeAfterLine(o["before_after"] as? [String: Any])
        if s.areaName == nil { s.areaName = str(o["name"]) }
        // a published rev is publication even if the state word is new to us
        if s.publishedRev != nil, phase(of: s.state) == nil { s.phase = .published }
        return s
    }
}

/// The create request body.
public struct RescanRequest: Equatable {
    public var setting: RescanSetting
    public var name: String?
    public var level: Int?
    public var lat: Double?
    public var lon: Double?
    public var hAccM: Double?
    public var appVersion: String
    public var streamID: String?
    /// §5.17: required; the same agent id the live stream uses.
    public var agentID: String
    /// §5.17: idempotency key (a retried create returns the same rescan).
    public var clientRescanID: String

    public init(setting: RescanSetting, name: String? = nil, level: Int? = nil, appVersion: String = "",
                lat: Double? = nil, lon: Double? = nil, hAccM: Double? = nil, streamID: String? = nil,
                agentID: String = "", clientRescanID: String = UUID().uuidString.lowercased()) {
        self.setting = setting; self.name = name; self.level = level; self.appVersion = appVersion
        self.lat = lat; self.lon = lon; self.hAccM = hAccM; self.streamID = streamID
        self.agentID = agentID; self.clientRescanID = clientRescanID
    }

    public var json: [String: Any] {
        var o: [String: Any] = ["kind": "area", "setting": setting.rawValue, "agent_type": "phone", "agent_id": agentID,
                                "client_rescan_id": clientRescanID, "by": "snailsight-app"]
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { o["name"] = String(n.prefix(60)) }
        if let l = level { o["level"] = l }
        if !appVersion.isEmpty { o["app_version"] = appVersion }
        if let s = streamID { o["stream_id"] = s }
        if let la = lat, let lo = lon, la.isFinite, lo.isFinite {
            var g: [String: Any] = ["lat": la, "lon": lo]
            if let a = hAccM, a.isFinite { g["h_acc_m"] = a }
            o["geo"] = g
        }
        return o
    }
}

/// What the scan sends at Finish.
public struct RescanFinish: Equatable {
    public var streamIDs: [String]
    public var keyframes: Int
    public var durationS: Double
    public var coverage: ScanCoverage.Summary
    public var points: Int
    public var locked: Bool
    public var queueLeft: Int

    public init(streamIDs: [String], keyframes: Int, durationS: Double, coverage: ScanCoverage.Summary, points: Int,
                locked: Bool, queueLeft: Int) {
        self.streamIDs = streamIDs; self.keyframes = keyframes; self.durationS = durationS; self.coverage = coverage
        self.points = points; self.locked = locked; self.queueLeft = queueLeft
    }

    public var recorded = false

    public var json: [String: Any] {
        ["stream_ids": streamIDs, "recorded": recorded, "keyframes": keyframes, "duration_s": (durationS * 10).rounded() / 10,
         "coverage": coverage.json, "points": points, "locked": locked, "queue_left": queueLeft]
    }
}

/// One rescan's client state (pure transitions; RescanTests).
public struct RescanSession: Equatable {
    public let setting: RescanSetting
    public let name: String?
    public let map: String
    public let startedAt: Double
    public private(set) var id: String?
    public private(set) var phase: RescanPhase = .idle
    public private(set) var status: RescanStatus?
    /// Why the scan runs without the server's rescan (404 = server without the API, or unreachable).
    public private(set) var localReason: String?
    public private(set) var finishedAt: Double?
    public private(set) var polls = 0
    public private(set) var lastPollAt: Double?
    public private(set) var stale = false
    public var finish: RescanFinish?

    /// Polling gives up (card: "still building, check snailCOP") after this long. API §5.17: the session runs the
    /// ordinary place -> tile path first and the rescan job after it, so the full result takes HOURS, not minutes.
    public static let pollGiveUpS = 24.0 * 3600
    /// A build that was running when the app went away is watched again on launch / foreground within this window.
    public static let resumeWindowS = 24.0 * 3600

    public init(setting: RescanSetting, name: String?, map: String, now: Double) {
        self.setting = setting; self.name = name; self.map = map; startedAt = now
    }

    public static func path(_ map: String, _ id: String? = nil, finish: Bool = false) -> String {
        var p = "/v1/maps/\(map)/rescan"
        if let id { p += "/\(id)" }
        if finish { p += "/finish" }
        return p
    }

    public mutating func creating() { if phase == .idle { phase = .creating } }

    /// The create reply. Returns the rescan id to stream with (nil = scan as a normal walk).
    @discardableResult
    public mutating func created(http: Int, body: Data?, error: String? = nil) -> String? {
        guard phase == .creating else { return id }
        phase = .scanning
        if let error { localReason = "server unreachable (\(error))"; return nil }
        if (200..<300).contains(http), let s = RescanStatus.parse(body), let i = s.id, !i.isEmpty,
           i.range(of: #"^[A-Za-z0-9_.:-]{1,80}$"#, options: .regularExpression) != nil {
            id = i
            status = s
            return i
        }
        if http == 409 { localReason = "another rescan is still open on the server" }
        else if [404, 405, 501].contains(http) { localReason = "this map server has no Rescan yet" }
        else { localReason = "the server refused the rescan (HTTP \(http))" }
        return nil
    }

    /// Finish tapped: the walk stops; the app waits for the spool to drain, then sends finish.
    public mutating func finishing(_ f: RescanFinish, now: Double) {
        guard phase == .scanning || phase == .creating else { return }
        finish = f
        finishedAt = now
        phase = id == nil ? .local : .finishing
    }

    public mutating func cancel() {
        guard !phase.terminal else { return }
        phase = .cancelled
    }

    /// The finish reply.
    public mutating func finished(http: Int, body: Data?, error: String? = nil) {
        guard phase == .finishing else { return }
        if let error {                                       // keep building: the poll learns what happened
            phase = .building
            status = status ?? RescanStatus()
            status?.message = "finish not confirmed (\(error)); checking"
            return
        }
        if (200..<300).contains(http) {
            phase = .building
            if let s = RescanStatus.parse(body) { apply(s) }
        } else if http == 404 {
            phase = .failed
            status = status ?? RescanStatus()
            status?.reason = "the server no longer knows this rescan"
        } else if http == 409, let s = RescanStatus.parse(body) {     // already finished / building
            phase = .building
            apply(s)
        } else {
            phase = .failed
            status = status ?? RescanStatus()
            status?.reason = RescanStatus.parse(body)?.reason ?? "finish refused (HTTP \(http))"
        }
    }

    private mutating func apply(_ s: RescanStatus) {
        var n = s
        if n.id == nil { n.id = id }
        // never go backwards to "scanning" after finish
        if n.phase == .scanning { n.phase = .building }
        status = n
        if n.phase.terminal || n.phase == .building { phase = n.phase }
    }

    /// A status poll. Returns seconds to the next poll (nil = stop).
    public mutating func polled(http: Int, body: Data?, now: Double, error: String? = nil) -> Double? {
        guard phase == .building else { return nil }
        polls += 1
        lastPollAt = now
        if error == nil {
            if (200..<300).contains(http), let s = RescanStatus.parse(body) { apply(s) }
            else if http == 404 {
                phase = .failed
                status = status ?? RescanStatus()
                status?.reason = "the server no longer knows this rescan"
                return nil
            }
        }
        if phase.terminal { return nil }
        let since = now - (finishedAt ?? startedAt)
        if since > Self.pollGiveUpS { stale = true; return nil }
        // §5.17: every 15 s after finish; slower once it is clearly a long build (hours), so a phone left open on the
        // card does not poll all evening
        return since < 60 ? 5 : (since < 1800 ? 15 : (since < 4 * 3600 ? 60 : 300))
    }

    /// While scanning: the server's live coverage (§5.17 `coverage.live`, poll every 5 s). Never changes the phase.
    public private(set) var live: RescanStatus?
    public mutating func liveStatus(http: Int, body: Data?) {
        guard phase == .scanning, id != nil, (200..<300).contains(http), let s = RescanStatus.parse(body) else { return }
        live = s
    }

    // MARK: card

    public var title: String {
        switch phase {
        case .idle, .creating: return "Starting the rescan…"
        case .scanning: return "Rescanning " + (setting == .indoor ? "the room" : "the area")
        case .finishing: return "Sending the last keyframes…"
        case .building: return stale ? "Still building: check snailCOP later" : "The server is building this area"
        case .published: return "Rescan published"
        case .held: return "Rescan held: the map was not changed"
        case .failed: return "Rescan failed"
        case .local: return "Scan done (as a normal walk)"
        case .cancelled: return "Rescan cancelled"
        }
    }

    public var lines: [String] {
        var out: [String] = []
        if let f = finish {
            out.append("\(WalkSummary.duration(f.durationS)) · \(f.keyframes) keyframes · \(f.points / 1000)k points")
            out.append("Good depth on \(f.coverage.coveragePct) % of what you scanned (\(Int(f.coverage.coveredM2.rounded())) m²)")
            out.append(f.coverage.line(outdoor: setting == .outdoor))
        }
        if let s = status {
            if let c = s.coveragePct { out.append(String(format: "Server coverage %.0f %%", c)) }
            if let q = s.quality ?? s.qualityScore.map({ String(format: "%.2f", $0) }) { out.append("Quality: \(q)") }
            if phase == .published, let r = s.publishedRev { out.append("Published as map rev \(r)") }
            if phase == .held || phase == .failed, let r = s.reason { out.append("Why: \(r)") }
            if phase == .published, s.decision == "island" {
                out.append("No overlap with the mapped house: it became its own area" + (s.islandID.map { " (\($0))" } ?? ""))
            }
            if let g = s.goodM2 { out.append(String(format: "Server: %.0f m² of good surface", g) + (s.areaM2.map { String(format: " · area %.0f m²", $0) } ?? "")) }
            if let ba = s.beforeAfter { out.append("Before → after: " + ba) }
            if phase == .building, let st = s.stage { out.append("Stage: " + st) }
            if phase == .held { for f in s.failedChecks.prefix(3) { out.append("Failed: " + f) } }
            for a in s.advice.prefix(3) { out.append("Re-scan " + a) }
            if let m = s.message { out.append(m) }
        }
        if phase == .local, let r = localReason { out.append("Not a rescan: \(r). The walk still improves the map as usual.") }
        return out
    }

    public var next: String? {
        switch phase {
        case .finishing, .building:
            return stale ? nil : "The server builds this area after the normal map update: often an hour or more. You can close "
                + "the app; the result shows here when you open it again (before / after, or why it was held)."
        case .published: return "Before / after below; snailCOP shows the new area."
        case .held: return "The old map stays (the scan still improves it as an ordinary walk). Follow the advice above and "
                + "rescan the whole area in one go."
        default: return nil
        }
    }

    /// Persisted so a restart can resume watching the build (UserDefaults dictionary).
    public var persisted: [String: Any]? {
        guard let id, !phase.terminal || phase == .building else { return nil }
        return ["id": id, "map": map, "setting": setting.rawValue, "name": name ?? "", "started": startedAt,
                "finished": finishedAt ?? 0, "phase": phase.rawValue]
    }

    /// Resume a building rescan after a restart (only if finished < 2 h ago).
    public static func resume(_ o: [String: Any], now: Double) -> RescanSession? {
        guard let id = o["id"] as? String, let map = o["map"] as? String,
              let st = (o["setting"] as? String).flatMap(RescanSetting.init(rawValue:)),
              let started = (o["started"] as? NSNumber)?.doubleValue,
              let fin = (o["finished"] as? NSNumber)?.doubleValue, fin > 0, now - fin < resumeWindowS,
              o["phase"] as? String == RescanPhase.building.rawValue || o["phase"] as? String == RescanPhase.finishing.rawValue
        else { return nil }
        var s = RescanSession(setting: st, name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }, map: map, now: started)
        s.id = id
        s.finishedAt = fin
        s.phase = .building
        return s
    }
}

/// The REST side, with an injectable transport (the app passes ServerLink.request; tests a mock server).
public struct RescanClient {
    public typealias Transport = (_ method: String, _ path: String, _ body: Data?) async throws -> (Data, Int)
    public let transport: Transport
    public init(transport: @escaping Transport) { self.transport = transport }

    static func body(_ o: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }

    public func create(_ s: inout RescanSession, _ r: RescanRequest) async -> String? {
        s.creating()
        do {
            var (d, st) = try await transport("POST", RescanSession.path(s.map), Self.body(r.json))
            // §5.17: one open rescan per agent and map. An earlier one this phone left open (app killed mid-scan) is
            // cancelled (it stays an ordinary walk on the server) and the create retried once.
            if st == 409, let old = RescanStatus.parse(d)?.id {
                _ = try? await transport("POST", RescanSession.path(s.map, old) + "/cancel", Self.body(["why": "superseded by a new rescan"]))
                (d, st) = try await transport("POST", RescanSession.path(s.map), Self.body(r.json))
            }
            return s.created(http: st, body: d)
        } catch {
            return s.created(http: 0, body: nil, error: "\(error)".prefix(80).description)
        }
    }

    public func finish(_ s: inout RescanSession) async {
        guard s.phase == .finishing, let id = s.id, let f = s.finish else { return }
        do {
            let (d, st) = try await transport("POST", RescanSession.path(s.map, id, finish: true), Self.body(f.json))
            s.finished(http: st, body: d)
        } catch {
            s.finished(http: 0, body: nil, error: "\(error)".prefix(80).description)
        }
    }

    /// §5.17 cancel (best effort; the session stays an ordinary walk on the server).
    public func cancel(map: String, id: String, why: String) async -> Int? {
        try? await transport("POST", RescanSession.path(map, id) + "/cancel", Self.body(["why": why])).1
    }

    /// While scanning: the server's live coverage.
    public func pollLive(_ s: inout RescanSession) async {
        guard s.phase == .scanning, let id = s.id else { return }
        if let (d, st) = try? await transport("GET", RescanSession.path(s.map, id), nil) { s.liveStatus(http: st, body: d) }
    }

    /// One poll; returns the delay to the next (nil = stop).
    public func poll(_ s: inout RescanSession, now: Double) async -> Double? {
        guard s.phase == .building, let id = s.id else { return nil }
        do {
            let (d, st) = try await transport("GET", RescanSession.path(s.map, id), nil)
            return s.polled(http: st, body: d, now: now)
        } catch {
            return s.polled(http: 0, body: nil, now: now, error: "\(error)")
        }
    }
}
