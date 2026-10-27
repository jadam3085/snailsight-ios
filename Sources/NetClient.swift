// Client for the `snailsight` map server (versioned `/v1` API, docs/SNAILSIGHT-API.md).
// Plain HTTP to IP addresses (ATS relaxed in Info.plist); Tailscale first, home LAN fallback (SnailSightCore.ServerConfig).
import Foundation
import Network
import SnailSightCore

/// Stable per-device agent identity (UserDefaults survives in-place app updates).
enum Identity {
    static let agentType = "phone"
    static let client = "snailsight-ios"
    private static let key = "snailsight.agent_id"

    static var agentID: String {
        let d = UserDefaults.standard
        if let s = d.string(forKey: key), AgentID.isValid(s) { return s }
        let s = AgentID.make()
        d.set(s, forKey: key)
        return s
    }
}

enum NetKeys {
    static let override = "snailsight.server_override"
    static let lastGood = "snailsight.server_last_good"
}

enum NetError: LocalizedError {
    case offline
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .offline: return "Map server not reachable (Tailscale or home Wi-Fi needed)"
        case .http(let s, let d): return "server said \(s): \(d)"
        }
    }
}

/// JSON helpers tolerant of FastAPI's `{"detail": {...}}` wrapping.
enum JSON {
    static func object(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }
    static func int(_ o: [String: Any], _ key: String) -> Int? {
        if let v = o[key] as? Int { return v }
        if let v = o[key] as? Double { return Int(v) }
        if let inner = o["detail"] as? [String: Any] { return int(inner, key) }
        return nil
    }
    static func string(_ o: [String: Any], _ key: String) -> String? {
        if let v = o[key] as? String { return v }
        if let inner = o["detail"] as? [String: Any] { return string(inner, key) }
        return nil
    }
    static func detail(_ d: Data) -> String {
        let o = object(d)
        if let s = o["detail"] as? String { return s }
        if let s = string(o, "detail") { return s }
        return String(decoding: d.prefix(200), as: UTF8.self)
    }
    static func body(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8) }
}

struct AgentInfo {
    var name: String
    var device: String
    var appVersion: String
}

/// Which server answers, and the one place requests are made. An actor so probes/requests from the log uploader,
/// the capture queue and the UI never race.
actor ServerLink {
    private let session: URLSession
    private let info: AgentInfo
    private let report: (String?, String) -> Void          // (base, label) → UI (called off-main; it hops to main)
    private var onOnline: [() -> Void] = []
    private(set) var base: String?
    private(set) var label = "offline"
    /// 10.9: the COP power gate's last answer while the server stack is OFF / waking (nil when the server answers).
    private(set) var cop: CopState?
    private var wakeClass = "phone-live"
    private var rewakeScheduled = false
    private var probing = false
    private var lastProbe: Date = .distantPast
    private var lastFailProbe: Double?                      // 12.17: rate limit of the re-probes after a timeout
    private let monitor = NWPathMonitor()

    init(info: AgentInfo, report: @escaping (String?, String) -> Void) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
        self.info = info
        self.report = report
    }

    func whenOnline(_ f: @escaping () -> Void) { onOnline.append(f) }

    /// Why this phone knocks while the COP is off: `phone-capture` (captures waiting) may wake it, `phone-live` only asks.
    func setWakeClass(_ c: String) { wakeClass = c }

    /// A power-gate answer: show "COP off" / "COP waking…", stay offline (queues keep their work), re-probe after
    /// `retry_s` when it is waking.
    private func copAnswer(_ c: CopState) {
        cop = c
        base = nil
        label = c.label
        report(nil, label)
        guard c.kind == .waking, !rewakeScheduled else { return }
        rewakeScheduled = true
        let delay = c.retryS
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.rewake()
        }
    }

    private func rewake() async {
        rewakeScheduled = false
        _ = await probe(force: true)
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.pathChanged(satisfied: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "snailsight.netpath"))
    }

    private func pathChanged(satisfied: Bool) async {
        if satisfied { _ = await probe(force: true) }
        else { setOffline() }
    }

    private func setOffline() {
        base = nil
        label = "offline"
        report(nil, label)
    }

    /// Find a server: override → last working → tailnet → LAN. `GET /v1` with a 4 s timeout each.
    @discardableResult
    func probe(force: Bool = false) async -> String? {
        if probing { return base }
        if !force, base != nil { return base }
        if !force, Date().timeIntervalSince(lastProbe) < 5 { return base }
        probing = true
        defer { probing = false; lastProbe = Date() }
        let d = UserDefaults.standard
        for c in ServerConfig.candidates(override: d.string(forKey: NetKeys.override), lastGood: d.string(forKey: NetKeys.lastGood)) {
            guard let url = URL(string: c.base + "/" + ServerConfig.apiVersion) else { continue }
            var r = URLRequest(url: url)
            r.timeoutInterval = 4
            r.setValue(wakeClass, forHTTPHeaderField: CopWake.header)
            r.setValue(Identity.agentID, forHTTPHeaderField: CopWake.agentHeader)
            guard let (data, resp) = try? await session.data(for: r) else { continue }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let gate = CopState.parse(status: status, body: data) {
                copAnswer(gate)
                return nil
            }
            if status == 200 {
                cop = nil
                base = c.base
                label = c.label
                d.set(c.base, forKey: NetKeys.lastGood)
                report(base, label)
                await registerAgent()
                for f in onOnline { f() }
                return base
            }
        }
        setOffline()
        return nil
    }

    /// 12.17: after a non-connection failure (timeout), at most once per 10 s, re-check the current server's `GET /v1`
    /// in the background. It answering 200 keeps everything as is (no re-register / onOnline storm while one backend
    /// is hung); anything else runs the full `probe(force: true)`, which marks offline only if no candidate answers.
    private func failProbe() {
        let t = Date().timeIntervalSince1970
        guard NetFailure.probeDue(now: t, last: lastFailProbe) else { return }
        lastFailProbe = t
        Task { [weak self] in await self?.recheck() }
    }

    private func recheck() async {
        guard !probing else { return }
        if let b = base, let url = URL(string: b + "/" + ServerConfig.apiVersion) {
            var r = URLRequest(url: url)
            r.timeoutInterval = 4
            r.setValue(wakeClass, forHTTPHeaderField: CopWake.header)
            r.setValue(Identity.agentID, forHTTPHeaderField: CopWake.agentHeader)
            if let (data, resp) = try? await session.data(for: r) {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let gate = CopState.parse(status: status, body: data) { copAnswer(gate); return }
                if status == 200 { return }
            }
        }
        _ = await probe(force: true)
    }

    private func registerAgent() async {
        let body: [String: Any] = ["agent_type": Identity.agentType, "name": info.name, "device": info.device,
                                   "app_version": info.appVersion, "client": Identity.client]
        _ = try? await rawRequest("PUT", "/v1/agents/\(Identity.agentID)", body: JSON.body(body), contentType: "application/json")
    }

    /// One request against the current server (probing first if needed). Returns (body, HTTP status).
    /// Connection failures mark the server offline so the next call re-probes; timeouts only re-probe (12.17).
    /// HTTP errors are returned, not thrown.
    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                 contentType: String = "application/json", timeout: TimeInterval = 30,
                 headers: [String: String] = [:]) async throws -> (Data, Int) {
        if base == nil { await probe() }
        guard base != nil else { throw NetError.offline }
        return try await rawRequest(method, path, query: query, body: body, contentType: contentType, timeout: timeout,
                                    headers: headers)
    }

    private func rawRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                            contentType: String = "application/json", timeout: TimeInterval = 30,
                            headers: [String: String] = [:]) async throws -> (Data, Int) {
        guard let b = base, var comps = URLComponents(string: b + path) else { throw NetError.offline }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw NetError.offline }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp): (Data, URLResponse)
            if let body {
                r.setValue(contentType, forHTTPHeaderField: "Content-Type")
                (data, resp) = try await session.upload(for: r, from: body)
            } else {
                (data, resp) = try await session.data(for: r)
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 10.9: the server stack was switched off under us (the power gate answers on its address): go offline
            // so every caller treats it like "no server" and keeps its work queued.
            if let gate = CopState.parse(status: status, body: data) {
                copAnswer(gate)
                throw NetError.offline
            }
            return (data, status)
        } catch {
            // 12.17: only connection failures mean "server gone". A timeout (a hung backend behind the map server, e.g.
            // the live service) re-probes GET /v1 in the background; only that probe failing marks it offline.
            if let u = error as? URLError {
                let code = u.code.rawValue
                if NetFailure.marksOffline(code: code) { setOffline() }
                else if NetFailure.wantsProbe(code: code) { failProbe() }
            }
            throw error
        }
    }
}
