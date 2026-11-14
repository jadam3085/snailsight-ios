// SnailSight 12.27 Rescan area (owner 2026-11-14): one careful continuous scan becomes that AREA's map (indoors a room,
// outdoors whatever the scan covered well; no room model needed). Client of the server's rescan API (snailCOP
// docs/SNAILSIGHT-API.md "Rescan"; SnailSightCore Rescan.swift holds the contract + the state machine):
//   entry (launch chooser, snailCOP pill, Mapping ▸ Rescan, the walk summary, snailsight://rescan)
//   -> short guidance (Room / Area, optional name) -> POST rescan -> the walk streams with `rescan_id` (fresh stream),
//      Scan view forced on (the live point cloud) + coverage strip + the walk's quality hints
//   -> Finish -> the spool drains -> POST finish -> poll GET status -> the card: building / published (before / after,
//      rev, Open in snailCOP) / held (why).
// A server without the API (or unreachable) never blocks the scan: it streams as a normal walk and the card says so.
// Logs: rescan_open, rescan_start, rescan_created, rescan_finish, rescan_finish_sent, rescan_status, rescan_result,
// rescan_cancel, rescan_resume (contract with walk_validate --rescan).
import CoreLocation
import Foundation
import SnailSightCore

final class RescanController: ObservableObject {
    private unowned let model: AppModel
    @Published var showGuide = false
    @Published var setting: RescanSetting =
        RescanSetting(rawValue: UserDefaults.standard.string(forKey: "rescan.setting") ?? "") ?? .indoor {
        didSet { UserDefaults.standard.set(setting.rawValue, forKey: "rescan.setting") }
    }
    @Published var name = ""
    @Published private(set) var session: RescanSession?
    @Published private(set) var starting = false
    private var pollTask: Task<Void, Never>?
    private var lastLogged: String?

    static let persistKey = "rescan.last"

    init(model: AppModel) { self.model = model }

    var scanning: Bool { session?.phase == .scanning }
    /// The card (finishing / building / result) is up.
    var cardVisible: Bool { guard let p = session?.phase else { return false }; return p != .scanning && p != .creating && p != .idle }
    private var now: Double { Date().timeIntervalSince1970 }

    private var client: RescanClient {
        let link = model.link
        return RescanClient { method, path, body in
            guard let link else { throw NetError.offline }
            return try await link.request(method, path, body: body, timeout: method == "GET" ? 10 : 8)
        }
    }

    // MARK: entry

    func open(cause: String) {
        if scanning { model.flash("A rescan is already running", seconds: 2); return }
        if model.appMode != .ar { model.setMode(.ar, cause: "rescan") }
        guard model.appMode == .ar else { return }
        model.showMap = false
        model.showMap3D = false
        model.showScans = false
        model.showSettings = false
        model.sheetDetent = .collapsed
        showGuide = true
        model.log.event("rescan_open", ["cause": .string(cause), "walk_active": .bool(model.walker.active),
                                        "setting": .string(setting.rawValue)])
    }

    /// The guidance sheet's Start.
    @MainActor
    func start() async {
        guard !starting, !scanning else { return }
        showGuide = false
        starting = true
        defer { starting = false }
        if model.walker.active { model.walker.stop(cause: "rescan_start") }
        model.walker.dismissSummary()
        pollTask?.cancel()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = RescanSession(setting: setting, name: trimmed.isEmpty ? nil : trimmed, map: model.liveMapID, now: now)
        session = s
        model.flash("Starting the rescan…", seconds: 2)
        let fix = model.geo.latestFix
        let req = RescanRequest(setting: setting, name: s.name, appVersion: Self.appVersion,
                                lat: fix?.coordinate.latitude, lon: fix?.coordinate.longitude,
                                hAccM: fix.map { $0.horizontalAccuracy })
        model.log.event("rescan_start", ["setting": .string(setting.rawValue), "name_len": .int(trimmed.count),
                                         "map_id": .string(s.map), "server": .bool(model.serverBase != nil),
                                         "geo": .bool(fix != nil)])
        let t0 = now
        let id = await client.create(&s, req)
        session = s
        model.log.event("rescan_created", ["ok": .bool(id != nil), "rescan_id": .string(id ?? ""),
                                           "local_reason": .string(s.localReason ?? ""),
                                           "ms": .int(Int((now - t0) * 1000))])
        persist()
        if id == nil { model.flash("Rescan not available on this server: scanning as a normal walk", seconds: 3.5) }
        model.liveStreamer.beginRescan(id)
        model.scanCloud.reset(why: "rescan_start")
        model.scanCloud.setForced(true, cause: "rescan")
        model.walker.start(cause: "rescan")
    }

    /// The walk bar's Finish while rescanning.
    func finish(cause: String) {
        guard var s = session, s.phase == .scanning else { return }
        let walk = model.walker.session
        model.walker.stop(cause: "rescan_finish")
        let snap = model.scanCloud.snapshot()
        let q = model.liveStreamer.current.queue
        let f = RescanFinish(streamIDs: walk?.streams ?? [model.liveStreamer.streamID], keyframes: walk?.sent ?? 0,
                             durationS: now - s.startedAt, coverage: snap.coverage, points: snap.points,
                             locked: walk?.lockedAt != nil, queueLeft: q)
        s.finishing(f, now: now)
        session = s
        model.liveStreamer.endRescan()
        model.scanCloud.setForced(false, cause: "rescan_finish")
        var ev: [String: LogValue] = ["cause": .string(cause), "rescan_id": .string(s.id ?? ""), "phase": .string(s.phase.rawValue),
                                      "duration_s": .double(f.durationS.rounded()), "keyframes": .int(f.keyframes),
                                      "streams": .string(f.streamIDs.joined(separator: ",")), "points": .int(f.points),
                                      "locked": .bool(f.locked), "queue": .int(q)]
        ev["coverage_pct"] = .int(f.coverage.coveragePct)
        ev["covered_m2"] = .double((f.coverage.coveredM2 * 10).rounded() / 10)
        ev["good_share"] = .double((f.coverage.goodShare * 1000).rounded() / 1000)
        ev["floor_pct"] = .int(f.coverage.pct(.floor) ?? -1)
        ev["wall_pct"] = .int(f.coverage.pct(.wall) ?? -1)
        ev["ceiling_pct"] = .int(f.coverage.pct(.ceiling) ?? -1)
        model.log.event("rescan_finish", ev)
        persist()
        guard s.phase == .finishing else { logResult(); return }        // local: done
        pollTask = Task { @MainActor [weak self] in await self?.sendFinishThenPoll() }
    }

    /// The walk ended by itself (Live map off, thermal, mode switch) during a rescan: that is its Finish.
    func walkStopped(cause: String) {
        guard scanning, cause != "rescan_finish", cause != "rescan_cancel" else { return }
        finish(cause: "walk_" + cause)
    }

    func cancel() {
        guard var s = session else { return }
        let wasScanning = s.phase == .scanning
        s.cancel()
        session = s
        pollTask?.cancel()
        if wasScanning { model.walker.stop(cause: "rescan_cancel") }
        model.liveStreamer.endRescan()
        model.scanCloud.setForced(false, cause: "rescan_cancel")
        model.log.event("rescan_cancel", ["rescan_id": .string(s.id ?? ""), "was_scanning": .bool(wasScanning)])
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
        session = nil
        model.walker.dismissSummary()
    }

    /// The card's Done (a build keeps being watched after a restart via persist; polling here stops).
    func dismiss() {
        pollTask?.cancel()
        pollTask = nil
        if let s = session, s.phase.terminal { UserDefaults.standard.removeObject(forKey: Self.persistKey) }
        session = nil
        model.walker.dismissSummary()
    }

    // MARK: finish + poll

    @MainActor
    private func sendFinishThenPoll() async {
        // the server needs every keyframe first: wait for the spool to drain (≤ 90 s, then send anyway)
        let t0 = now
        while model.liveStreamer.current.queue > 0, now - t0 < 90 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
        }
        guard var s = session, s.phase == .finishing else { return }
        let left = model.liveStreamer.current.queue
        await client.finish(&s)
        guard !Task.isCancelled else { return }
        session = s
        model.log.event("rescan_finish_sent", ["rescan_id": .string(s.id ?? ""), "phase": .string(s.phase.rawValue),
                                               "wait_s": .double((now - t0).rounded()), "queue_left": .int(left),
                                               "state": .string(s.status?.state ?? "")])
        persist()
        await pollLoop()
    }

    @MainActor
    private func pollLoop() async {
        while !Task.isCancelled {
            guard var s = session, s.phase == .building else { break }
            let d = await client.poll(&s, now: now)
            guard !Task.isCancelled else { return }
            session = s
            logStatusIfChanged(s)
            persist()
            guard let d else { break }
            try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
        }
        if let s = session, s.phase.terminal || s.stale { logResult() }
    }

    private func logStatusIfChanged(_ s: RescanSession) {
        let st = s.status
        let key = "\(s.phase.rawValue)|\(st?.state ?? "")|\(st?.coveragePct.map { Int($0) } ?? -1)|\(st?.publishedRev ?? -1)"
        guard key != lastLogged else { return }
        lastLogged = key
        model.log.event("rescan_status", ["rescan_id": .string(s.id ?? ""), "phase": .string(s.phase.rawValue),
                                          "state": .string(st?.state ?? ""), "coverage_pct": .double(st?.coveragePct ?? -1),
                                          "rev": .int(st?.publishedRev ?? -1), "reason": .string(st?.reason ?? ""),
                                          "polls": .int(s.polls)])
    }

    private func logResult() {
        guard let s = session else { return }
        let st = s.status
        var ev: [String: LogValue] = ["rescan_id": .string(s.id ?? ""), "phase": .string(s.phase.rawValue),
                                      "stale": .bool(s.stale), "polls": .int(s.polls)]
        ev["rev"] = .int(st?.publishedRev ?? -1)
        ev["reason"] = .string(st?.reason ?? s.localReason ?? "")
        ev["coverage_pct"] = .double(st?.coveragePct ?? -1)
        ev["quality"] = .string(st?.quality ?? st?.qualityScore.map { String($0) } ?? "")
        ev["before"] = .bool(st?.beforeURL != nil)
        ev["after"] = .bool(st?.afterURL != nil)
        if let f = s.finishedAt { ev["build_s"] = .double((now - f).rounded()) }
        model.log.event("rescan_result", ev)
        if s.phase.terminal { UserDefaults.standard.removeObject(forKey: Self.persistKey) }
    }

    private func persist() {
        if let p = session?.persisted { UserDefaults.standard.set(p, forKey: Self.persistKey) }
    }

    /// Launch: a rescan that was building when the app went away is watched again (≤ 2 h).
    func resumeOnLaunch() {
        guard session == nil, let o = UserDefaults.standard.dictionary(forKey: Self.persistKey) else { return }
        guard let s = RescanSession.resume(o, now: now) else {
            UserDefaults.standard.removeObject(forKey: Self.persistKey)
            return
        }
        session = s
        model.log.event("rescan_resume", ["rescan_id": .string(s.id ?? ""), "age_s": .double((now - s.startedAt).rounded())])
        pollTask = Task { @MainActor [weak self] in await self?.pollLoop() }
    }

    // MARK: result helpers

    /// A preview URL from the status (relative to the map server, or absolute).
    func url(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        guard let b = model.serverBase else { return nil }
        return URL(string: b + (s.hasPrefix("/") ? s : "/" + s))
    }

    /// Open the result in snailCOP (at the server's view if it gave one).
    func openInCop() {
        let at = session?.status?.viewAt
        model.log.event("rescan_open_cop", ["at": .bool(at != nil)])
        let v = at.flatMap(CopView.parse)
        dismiss()
        model.setMode(.cop, cause: "rescan_result")
        if let v { model.cop.goTo(v) }
    }

    static var appVersion: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?").\(i?["CFBundleVersion"] as? String ?? "0")"
    }
}
