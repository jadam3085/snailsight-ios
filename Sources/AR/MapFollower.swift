// SnailSight 10.7 "follow LATEST" (live shared-map plan M1, API §5.11; owner 2026-10-16: "I selected the newest map,
// it wasn't loaded until I loaded it"). The main AR view always shows the house map's newest READY version:
//  - launch: the last head this phone saw (UserDefaults) is shown at once; its collision mesh is in Caches/armap, so the
//    map is drawn the moment the lock arrives (MapARLayer preloads it before the lock);
//  - background: GET /v1/maps/site/head at launch, every 60 s and on foreground / Scans closed, plus the `rev` push on
//    a light WS (`/v1/maps/site/live`, layers ["rev"]; also read off the Live map downlink when that is open);
//  - a newer head: its collision mesh (AR) and its usdz (Scans) download in the background; the swap waits for a still
//    moment (≤ MapFollow.maxWaitS), then "Map updated · rev N". No AR session restart, ever.
// The server never names a version whose phone mesh is not built (head = newest BUILT version), so neither does this.
import Foundation
import simd
import SnailSightCore

final class MapFollower {
    private unowned let model: AppModel
    let mapID = "site"
    private(set) var state: MapFollow
    private var still = StillDetector()
    private var stillNow = false
    private var lastTick: TimeInterval = 0
    private var lastHeadCheck: TimeInterval = 0
    private var checking = false
    private var prefetching: String?                     // etag being downloaded
    private var launchT = ProcessInfo.processInfo.systemUptime
    private var firstShownLogged = false
    // rev WebSocket
    private var task: URLSessionWebSocketTask?
    private var gen = 0
    private var wsOpen = false
    private var reconnectAt: TimeInterval = 0
    private var attempt = 0
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static let headKey = "mapfollow.head.site"
    static let pollS = 60.0

    init(model: AppModel) {
        self.model = model
        var cached: MapHead?
        if let d = UserDefaults.standard.data(forKey: Self.headKey) { cached = MapHead.decode(d) }
        state = MapFollow(cached: cached)
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    /// The version the AR content should use for a lock in `lock` (nil = no lock yet).
    func contentVersion(lock: Int?) -> Int? { ARContentPick.version(lock: lock, follow: state.followVersion) }

    var followVersion: Int? { state.followVersion }
    var isStill: Bool { stillNow }

    /// "Map rev 14 · newest" for the status card (nil before the first head).
    var statusLine: String? {
        guard let r = state.followVersion else { return nil }
        var s = "House map rev \(r) · follows the newest automatically"
        if let st = state.staged?.rev { s += " · rev \(st) ready, swaps when you pause" }
        else if let p = state.known?.pending?.version, p > r { s += " · v\(p) being built" }
        return s
    }

    // MARK: lifecycle

    /// After networking starts (AppModel.startNetworking).
    func start() {
        model.log.event("mapfollow_start", ["cached_rev": state.followVersion.map { LogValue.int($0) } ?? LogValue.string("none"),
                                            "etag": .string(state.shown?.etag ?? "")])
        checkHead(why: "launch")
    }

    func resume(why: String) {
        attempt = 0
        reconnectAt = 0
        checkHead(why: why)
    }

    /// Every AR frame (main): still detection, swap at a still moment, the poll, the WS.
    func frame(t: TimeInterval, camera: simd_float4x4) {
        let c = camera.columns.3
        let f = camera.columns.2                           // camera looks along -z
        let yaw = atan2(Double(-f.x), Double(-f.z)) * 180 / .pi
        still.add(t: t, position: [Double(c.x), Double(c.y), Double(c.z)], yawDeg: yaw)
        guard t - lastTick >= 0.5 else { return }
        lastTick = t
        stillNow = still.isStill(now: t)
        let n = now
        if let h = state.swapDue(now: n, still: stillNow) { applySwap(h, still: stillNow) }
        if n - lastHeadCheck >= Self.pollS { checkHead(why: "poll") }
        wsTick()
    }

    // MARK: head

    func checkHead(why: String) {
        guard !checking, let link = model.link else { return }
        checking = true
        lastHeadCheck = now
        Task { [weak self] in
            let r = try? await link.request("GET", "/v1/maps/site/head", timeout: 15)
            await MainActor.run {
                guard let self else { return }
                self.checking = false
                guard let rr = r else { return }
                let (d, s) = rr
                if s == 200, let h = MapHead.decode(d) { self.offer(h, via: "http:\(why)") }
                else if s != 404 { self.model.log.event("mapfollow_head_failed", ["status": .int(s), "why": .string(why)]) }
            }
        }
    }

    /// A head from HTTP, the rev WS or the Live map downlink (main thread).
    func offer(_ h: MapHead, via: String) {
        let wanted = state.offer(h)
        model.log.event("mapfollow_head", ["via": .string(via), "rev": h.rev.map { LogValue.int($0) } ?? LogValue.string("none"),
                                           "etag": .string(h.etag ?? ""), "latest": .int(h.latestVersion ?? -1),
                                           "pending": .int(h.pending?.version ?? -1),
                                           "shown": .int(state.followVersion ?? -1), "fetch": .bool(wanted)])
        if wanted { prefetch(h) }
    }

    /// The Live map downlink saw a message: pick `rev` out of it cheaply (the server sends `{"type":"rev",…` first).
    func liveMessage(_ d: Data) {
        guard d.count < 16_384, d.starts(with: Array(#"{"type":"rev""#.utf8)), let h = MapHead.decode(d) else { return }
        offer(h, via: "live_downlink")
    }

    private func prefetch(_ h: MapHead) {
        guard let etag = h.etag, prefetching != etag, let scene = h.sceneID, let link = model.link else { return }
        prefetching = etag
        let t0 = now
        Task { [weak self] in
            // 1. the AR collision mesh (what the main view draws), into the same cache MapARLayer reads
            var arOK = true
            if let c = h.collision {
                arOK = await MapARLayer.cacheCollision(scene: scene, url: c.url, link: link)
            }
            // 2. the usdz for Scans (the newest map opens there without a download); best effort
            var usdzNote = "skipped"
            if h.phone != nil {
                usdzNote = await MapFollower.prefetchUsdz(scene: scene, model: self?.model)
            }
            await MainActor.run {
                guard let self else { return }
                if self.prefetching == etag { self.prefetching = nil }
                self.model.log.event("mapfollow_prefetch", ["rev": .int(h.rev ?? -1), "etag": .string(etag),
                                                             "ar": .bool(arOK), "usdz": .string(usdzNote),
                                                             "s": .double(self.now - t0)])
                guard arOK else { return }                   // retried by the next poll / rev
                self.state.didPrefetch(h, now: self.now)
                if let s = self.state.swapDue(now: self.now, still: self.stillNow) { self.applySwap(s, still: self.stillNow) }
            }
        }
    }

    @MainActor
    private static func prefetchUsdz(scene: String, model: AppModel?) async -> String {
        guard let model else { return "no model" }
        if model.recording { return "skipped (recording: the capture upload owns the bandwidth)" }
        let store = model.sharedScanStore()
        do {
            let it = try await store.fetch(scene)
            guard it.mesh?.isReady == true else { return "not ready" }
            _ = try await store.file(it, .mesh) { _ in }
            return "cached"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    private func applySwap(_ h: MapHead, still: Bool) {
        let staged = state.stagedAt
        let toast = state.didSwap(h)
        if let d = try? JSONEncoder().encode(h) { UserDefaults.standard.set(d, forKey: Self.headKey) }
        var ev: [String: LogValue] = ["rev": .int(h.rev ?? -1), "etag": .string(h.etag ?? ""), "still": .bool(still),
                                      "waited_s": .double(staged.map { now - $0 } ?? 0)]
        if let built = h.phone?.built { ev["since_ready_s"] = .double(now - built) }   // server clock: approximate
        if !firstShownLogged {
            firstShownLogged = true
            ev["since_launch_s"] = .double(ProcessInfo.processInfo.systemUptime - launchT)
        }
        model.log.event("mapfollow_swap", ev)
        if let t = toast { model.flash(t, seconds: 4) }
    }

    // MARK: rev WebSocket (layers ["rev"]: no tiles, no events)

    private var wsWanted: Bool { model.serverBase != nil && model.serverFeatures.list.contains("map_head") }

    private func wsTick() {
        if !wsWanted {
            if task != nil { close() }
            return
        }
        if task == nil && now >= reconnectAt { connect() }
    }

    private func connect() {
        guard let b = model.serverBase else { return }
        var ws = b
        if ws.hasPrefix("https://") { ws = "wss://" + String(ws.dropFirst(8)) }
        else if ws.hasPrefix("http://") { ws = "ws://" + String(ws.dropFirst(7)) }
        guard let url = URL(string: ws + "/v1/maps/\(mapID)/live") else { return }
        gen += 1
        let g = gen
        let tk = session.webSocketTask(with: url)
        task = tk
        tk.resume()
        let sub = #"{"type":"subscribe","map_id":"site","layers":["rev"]}"#
        tk.send(.string(sub)) { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async { if self?.gen == g { self?.fail("send: \(err.localizedDescription)") } }
        }
        receive(g)
    }

    private func receive(_ g: Int) {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, g == self.gen else { return }
                switch result {
                case .success(let m):
                    if !self.wsOpen { self.wsOpen = true; self.attempt = 0 }
                    var d: Data?
                    switch m {
                    case .string(let s): d = Data(s.utf8)
                    case .data(let x): d = x
                    @unknown default: d = nil
                    }
                    if let d, let h = MapHead.decode(d) { self.offer(h, via: "rev_ws") }
                    self.receive(g)
                case .failure(let e):
                    self.fail("receive: \(e.localizedDescription)")
                }
            }
        }
    }

    private func fail(_ why: String) {
        let was = wsOpen
        close()
        let d = min(60.0, 5.0 * pow(2.0, Double(attempt)))
        attempt += 1
        reconnectAt = now + d
        if was || attempt <= 2 { model.log.event("mapfollow_ws_drop", ["why": .string(why), "retry_s": .double(d)]) }
    }

    private func close() {
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        wsOpen = false
    }

    /// Background: drop the socket (resume() reconnects).
    func enteredBackground() { close() }
}
