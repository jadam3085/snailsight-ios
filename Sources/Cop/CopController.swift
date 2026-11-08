// SnailSight 12.25 snailCOP mode (owner 2026-11-07: "make this the actual snailcop output so that we don't need two apps
// ... I can just go to snailcop without localizing"). The cop.snail portal (snailCOP/portal, already phone-optimised) runs in
// a WKWebView as a first-class mode; this controller finds it (override → last good → the map server's host on :8945 →
// cop.snail), explains when it can't (offline / Tailscale off / stack switched off → Turn on), and is the native side of the
// bridge (SnailSightCore CopMode.swift, protocol v1): insets, "you are here", memory level, gamepad, goto (deep links),
// pause; from the page: view, Open AR here, share, drive / fly, a few log events.
// No camera, no ARSession, no localizer, no Live map here: AppModel.setMode starts AR only when the owner switches to it.
import Foundation
import Network
import SwiftUI
import UIKit
import WebKit
import SnailSightCore

final class CopController: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, probing, loading, ready, problem }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var reach: CopReach?
    @Published private(set) var base: String?
    @Published private(set) var turningOn = false
    @Published private(set) var lastView: CopView?
    @Published private(set) var driving = false
    @Published private(set) var flying = false
    @Published var shareItems: [Any]?

    private unowned let model: AppModel
    private(set) var webView: WKWebView?
    private var bridgeReady = false
    private var outbox: [String: [String: Any]] = [:]          // latest message per type until the page says ready
    private var visible = false
    private var hiddenSince: Date?
    private var pendingView: CopView?
    private var lite = false
    private var terminations = 0
    private var probeTask: Task<Void, Never>?
    private var retryWork: DispatchWorkItem?
    private var tick: Timer?
    private var governor = MemoryGovernor()
    private var sentLevel: MemLevel?
    private var lastMemLog: TimeInterval = 0
    private var lastPose: [String: Any]?
    private var lastPoseSent: TimeInterval = 0
    private var lastPadSent: TimeInterval = 0
    private var openedAt: Date?
    private let monitor = NWPathMonitor()
    private var path: (network: Bool, vpn: Bool, wifi: Bool) = (true, false, false)

    init(model: AppModel) {
        self.model = model
        super.init()
        monitor.pathUpdateHandler = { [weak self] p in
            let v = (p.status == .satisfied, p.usesInterfaceType(.other), p.usesInterfaceType(.wifi))
            Task { @MainActor in
                guard let self else { return }
                let wasDown = !self.path.network
                self.path = v
                if wasDown && v.0 && self.visible && self.phase == .problem { self.probe(why: "network") }
            }
        }
        monitor.start(queue: DispatchQueue(label: "snailsight.cop.path"))
        memObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                             object: nil, queue: .main) { [weak self] _ in self?.memoryWarning() }
    }
    private var memObserver: NSObjectProtocol?

    /// Back from the background while snailCOP is up: retry a failed load, else refresh the pose.
    func foreground() {
        guard visible else { return }
        if phase == .problem || phase == .idle { probe(why: "foreground") } else { pushPose(force: true) }
    }

    // MARK: show / hide (AppModel.setMode)

    func show(view: CopView? = nil, why: String) {
        if let view { pendingView = view }
        visible = true
        let away = hiddenSince.map { Date().timeIntervalSince($0) } ?? 0
        hiddenSince = nil
        openedAt = Date()
        _ = model.drive                                         // the shared gamepad reader (routes to us in this mode)
        startTick()
        model.log.event("cop_open", ["why": .string(why), "phase": .string("\(phase)"), "away_s": .int(Int(away)),
                                     "web_kept": .bool(webView != nil)])
        if phase == .ready, webView != nil {
            send(CopBridgeOut.paused(false))
            if let v = pendingView { pendingView = nil; send(CopBridgeOut.goto(v)) }
            pushPose(force: true)
        } else if phase != .probing && phase != .loading {
            probe(why: why)
        }
    }

    func hide(why: String) {
        guard visible else { return }
        visible = false
        hiddenSince = Date()
        stopTick()
        retryWork?.cancel()
        send(CopBridgeOut.paused(true))
        if driving { model.log.event("cop_hide_while_driving") }
        model.log.event("cop_close", ["why": .string(why), "open_s": .int(Int(openedAt.map { Date().timeIntervalSince($0) } ?? 0))])
    }

    /// While AR runs: drop the hidden web view (its WebContent process holds the WebGL scene) when memory gets tight or it
    /// has not been used for 10 min. Called from the AR memory governor's level changes and a slow tick.
    func arMemory(level: MemLevel) {
        guard !visible, webView != nil, let h = hiddenSince else { return }
        if !ModeRules.keepWebInAR(level: level, awayS: Date().timeIntervalSince(h)) { dropWeb(why: level >= .shed ? level.label : "idle") }
    }

    private func dropWeb(why: String) {
        guard let w = webView else { return }
        w.configuration.userContentController.removeScriptMessageHandler(forName: "snailsight")
        w.stopLoading()
        w.removeFromSuperview()
        webView = nil
        bridgeReady = false
        phase = .idle
        model.log.event("cop_web_dropped", ["why": .string(why)])
    }

    // MARK: finding the portal

    func retry() { probe(why: "retry") }

    func probe(why: String) {
        probeTask?.cancel()
        retryWork?.cancel()
        phase = .probing
        let d = UserDefaults.standard
        let cands = CopPortal.candidates(override: d.string(forKey: CopPortal.overrideKey), lastGood: d.string(forKey: CopPortal.lastGoodKey),
                                         serverBase: model.serverBase)
        let t0 = Date()
        probeTask = Task { @MainActor [weak self] in
            let results = await Self.probeAll(cands)
            guard let self, !Task.isCancelled else { return }
            let probes = results.map(\.1)
            let p = self.path
            let verdict = CopReach.diagnose(network: p.network, vpn: p.vpn, onHomeWiFi: p.wifi && !ServerConfig.lan.isEmpty, probes: probes)
            var ev: [String: LogValue] = ["why": .string(why), "result": .string(verdict.kind.rawValue),
                                          "ms": .int(Int(Date().timeIntervalSince(t0) * 1000)), "candidates": .int(cands.count),
                                          "vpn": .bool(p.vpn), "network": .bool(p.network)]
            ev["answers"] = .string(zip(cands, probes).map { "\($0.label)=\(Self.short($1))" }.joined(separator: ","))
            self.model.log.event("cop_probe", ev)
            self.reach = verdict
            if verdict.kind == .ready, let hit = zip(cands, probes).first(where: { $0.1 == .portal })?.0 {
                UserDefaults.standard.set(hit.base, forKey: CopPortal.lastGoodKey)
                self.base = hit.base
                self.load()
            } else {
                self.phase = .problem
                self.turningOn = self.turningOn && verdict.kind == .waking
                self.gateBase = results.first(where: { if case .gate = $0.1 { return true }; return false })?.2
                if self.visible { self.scheduleRetry(verdict.retryS) }
            }
        }
    }

    /// The gate that answered (for Turn on).
    private var gateBase: String?

    private func scheduleRetry(_ s: Double) {
        let w = DispatchWorkItem { [weak self] in self?.probe(why: "auto_retry") }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, s), execute: w)
    }

    private static func short(_ p: CopProbe) -> String {
        switch p {
        case .portal: return "portal"
        case .gate(let s): return "gate:\(s)"
        case .refused: return "refused"
        case .timeout: return "timeout"
        case .dns: return "dns"
        case .other(let s): return s
        }
    }

    /// Every candidate at once (4 s each): (candidate, answer, gate base that answered).
    private static func probeAll(_ cands: [ServerCandidate]) async -> [(ServerCandidate, CopProbe, String?)] {
        await withTaskGroup(of: (Int, CopProbe, String?).self) { g in
            for (i, c) in cands.enumerated() {
                g.addTask {
                    let p = await probeOne(c.base)
                    if p == .refused, let gb = CopPortal.gateBase(forPortal: c.base) {
                        let gp = await probeGate(gb)
                        if case .gate = gp { return (i, gp, gb) }
                    }
                    if case .gate = p { return (i, p, c.base) }       // the name fell through to the gate
                    return (i, p, nil)
                }
            }
            var out = [(Int, CopProbe, String?)]()
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { (cands[$0.0], $0.1, $0.2) }
        }
    }

    private static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    /// The portal answers its levels API (200); the power gate answers 503 {"cop": state} for /api/ while the stack is off.
    private static func probeOne(_ base: String) async -> CopProbe {
        guard let u = URL(string: base + "/api/world/levels?map=site") else { return .other("url") }
        do {
            let (d, r) = try await session().data(from: u)
            let st = (r as? HTTPURLResponse)?.statusCode ?? 0
            if st == 200 { return .portal }
            if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = o["cop"] as? String { return .gate(s) }
            return .other("http\(st)")
        } catch { return classify(error) }
    }

    private static func probeGate(_ gate: String) async -> CopProbe {
        guard let u = URL(string: gate + "/power") else { return .other("url") }
        do {
            let (d, r) = try await session().data(from: u)
            guard (r as? HTTPURLResponse)?.statusCode == 200,
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = o["state"] as? String else { return .other("gate?") }
            return .gate(s)
        } catch { return classify(error) }
    }

    private static func classify(_ e: Error) -> CopProbe {
        guard let u = e as? URLError else { return .other("error") }
        switch u.code {
        case .cannotConnectToHost, .networkConnectionLost: return .refused
        case .timedOut: return .timeout
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .notConnectedToInternet: return .other("offline")
        default: return .other("url\(u.code.rawValue)")
        }
    }

    /// The gate's Turn on (any tailnet / LAN client may; audited by the gate).
    func turnOn() {
        guard let g = gateBase ?? base.flatMap(CopPortal.gateBase(forPortal:)), let u = URL(string: g + "/power/on") else { return }
        turningOn = true
        model.log.event("cop_turn_on", ["gate": .string(g)])
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(#"{"why": "SnailSight app: open snailCOP"}"#.utf8)
        Task { @MainActor [weak self] in
            let st = (try? await Self.session().data(for: r)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
            guard let self else { return }
            self.model.log.event("cop_turn_on_result", ["status": .int(st)])
            self.reach = CopReach(kind: .waking, title: "snailCOP is starting",
                                  detail: "Turning the COP and map server stack on. This takes about a minute.", retryS: 3, canTurnOn: false)
            self.scheduleRetry(3)
        }
    }

    // MARK: the web view

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(self), name: "snailsight")
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()                     // the portal's own choices (preset, fly speed) persist
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1)
        w.scrollView.isScrollEnabled = false
        w.scrollView.bounces = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { w.isInspectable = true }
        w.customUserAgent = nil
        return w
    }

    var hostView: WKWebView {
        if let w = webView { return w }
        let w = makeWebView()
        webView = w
        return w
    }

    private func load() {
        guard let b = base else { return }
        phase = .loading
        bridgeReady = false
        let v = pendingView ?? lastView
        pendingView = nil
        let s = CopPortal.pageURL(base: b, appVersion: model.version, view: v, lite: lite)
        guard let u = URL(string: s) else { return }
        model.log.event("cop_load", ["base_label": .string(baseLabel(b)), "lite": .bool(lite), "at": .bool(v != nil)])
        hostView.load(URLRequest(url: u, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15))
    }

    private func baseLabel(_ b: String) -> String {
        let d = UserDefaults.standard
        return CopPortal.candidates(override: d.string(forKey: CopPortal.overrideKey), lastGood: nil, serverBase: model.serverBase)
            .first(where: { $0.base == b })?.label ?? "last"
    }

    func reload() {
        model.log.event("cop_reload")
        if phase == .ready || phase == .loading { load() } else { probe(why: "reload") }
    }

    // MARK: bridge out

    func send(_ msg: [String: Any]) {
        guard let t = msg["type"] as? String else { return }
        guard bridgeReady, let w = webView, let js = CopBridgeOut.js(msg) else { outbox[t] = msg; return }
        w.evaluateJavaScript(js, completionHandler: nil)
    }

    func setInsets(_ e: EdgeInsets) {
        send(CopBridgeOut.insets(top: Double(e.top), right: Double(e.trailing), bottom: Double(e.bottom), left: Double(e.leading)))
    }

    func goTo(_ v: CopView) {
        if bridgeReady { send(CopBridgeOut.goto(v)) } else { pendingView = v }
    }

    /// The phone's last pose in the map frame (only while localized; "last" with its age otherwise).
    private func pushPose(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard force || now - lastPoseSent >= 1 else { return }
        let msg = CopBridgeOut.pose(model.copPose(now: now))
        if !force, let lp = lastPose, NSDictionary(dictionary: lp).isEqual(to: msg), now - lastPoseSent < 15 { return }
        lastPose = msg
        lastPoseSent = now
        send(msg)
    }

    /// The shared gamepad (DriveController's reader) routes frames here while snailCOP is up.
    func padFrame(_ f: GamepadFrame?) {
        guard visible else { return }
        let t = CACurrentMediaTime()
        if f != nil, t - lastPadSent < 1.0 / 30 { return }
        lastPadSent = t
        send(CopBridgeOut.pad(f))
    }

    // MARK: 1 Hz: memory governor + pose (the AR governor is idle in this mode: no AR frames)

    private func startTick() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickNow()
        }
    }

    private func stopTick() { tick?.invalidate(); tick = nil }

    func memoryWarning() {
        guard visible else { return }
        let l = governor.warning(now: CACurrentMediaTime())
        var ev = MemoryProbe.fields()
        ev["level"] = .string(l.label)
        ev["mode"] = .string("cop")
        model.log.event("mem_warning", ev)
        pushMem(force: true)
    }

    private func tickNow() {
        let f = MemoryProbe.footprintMB(), a = MemoryProbe.availableMB()
        governor.update(footprintMB: f, limitMB: f.flatMap { fv in a.map { fv + $0 } }, now: CACurrentMediaTime())
        pushMem(force: false)
        pushPose()
        let t = CACurrentMediaTime()
        if t - lastMemLog >= 30 {
            lastMemLog = t
            var ev = MemoryProbe.fields()
            ev["mode"] = .string("cop")
            ev["level"] = .string(governor.level.label)
            ev["thermal"] = .string(model.thermal)
            ev["web"] = .bool(webView != nil)
            ev["terminations"] = .int(terminations)
            model.log.event("mem", ev)
        }
    }

    private func pushMem(force: Bool) {
        let l = governor.level
        guard force || l != sentLevel else { return }
        if l != sentLevel { model.log.event("mem_level", ["mode": .string("cop"), "level": .string(l.label), "from": .string(sentLevel?.label ?? "-")]) }
        sentLevel = l
        send(CopBridgeOut.mem(level: l, footprintMB: MemoryProbe.footprintMB(), thermal: model.thermal))
    }

    // MARK: bridge in

    fileprivate func received(_ body: Any) {
        guard let m = CopBridgeIn.parse(body) else { return }
        switch m {
        case .ready(let proto, let map, let rev):
            bridgeReady = true
            phase = .ready
            model.log.event("cop_ready", ["proto": .int(proto), "map": .string(map ?? ""), "rev": .int(rev ?? -1),
                                          "ms": .int(Int((openedAt.map { Date().timeIntervalSince($0) } ?? 0) * 1000))])
            for (_, msg) in outbox.sorted(by: { $0.key < $1.key }) { send(msg) }
            outbox.removeAll()
            send(CopBridgeOut.mem(level: governor.level, footprintMB: MemoryProbe.footprintMB(), thermal: model.thermal))
            sentLevel = governor.level
            if let v = pendingView { pendingView = nil; send(CopBridgeOut.goto(v)) }
            if !visible { send(CopBridgeOut.paused(true)) }
            pushPose(force: true)
        case .view(let v, _, _):
            lastView = v
        case .openAR(let target, let label, let source, let id):
            model.log.event("cop_open_ar", ["source": .string(source), "has_id": .bool(id != nil)])
            model.openARHere(target: target, label: label.isEmpty ? (source == "view" ? "Viewed spot" : "Target") : label)
        case .share(let url, let title):
            var items: [Any] = [title]
            if let u = URL(string: url) { items.append(u) }
            if let v = lastView, let app = URL(string: AppDeepLink.copURL(v)) { items.append(app) }
            model.log.event("cop_share", ["at": .bool(lastView != nil)])
            shareItems = items
        case .drive(let active, _):
            driving = active
            model.log.event("cop_drive", ["active": .bool(active)])
        case .fly(let active):
            flying = active
        case .log(let ev, let data):
            model.log.event("cop_web_\(ev)", data.mapValues { LogValue.double($0) })
            if ev == "gl_lost" { webLost(why: "gl_lost") }
        case .unknown:
            break
        }
    }

    /// The WebContent process died or WebGL lost its context (memory): reload lighter, at most 3 times a session.
    private func webLost(why: String) {
        terminations += 1
        lite = true
        model.log.event("cop_web_terminated", ["why": .string(why), "count": .int(terminations)])
        guard terminations <= 3 else {
            phase = .problem
            reach = CopReach(kind: .unreachable, title: "snailCOP ran out of memory",
                             detail: "The 3D view was stopped by iOS several times. Tap Retry to load it again at low quality.", retryS: 0, canTurnOn: false)
            return
        }
        model.flash("snailCOP reloading at low quality (memory)", seconds: 3)
        load()
    }
}

// MARK: - WKWebView delegates

extension CopController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // the page posts `ready` itself after boot; an old portal without the bridge still shows (no native glue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.phase == .loading, !self.bridgeReady else { return }
            self.phase = .ready
            self.model.log.event("cop_no_bridge")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        model.log.event("cop_load_failed", ["error": .string(String(error.localizedDescription.prefix(120)))])
        probe(why: "load_failed")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        model.log.event("cop_load_failed", ["error": .string(String(error.localizedDescription.prefix(120))), "late": .bool(true)])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webLost(why: "process") }

    /// Same host stays in the view; other hosts (docs, camera pages) open in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel) }
        let mine = base.flatMap { URLComponents(string: $0)?.host } ?? ""
        if action.navigationType == .linkActivated, u.host != mine {
            UIApplication.shared.open(u)
            return decisionHandler(.cancel)
        }
        if let s = u.scheme, s != "http", s != "https", s != "about", s != "blob", s != "data" {
            UIApplication.shared.open(u)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { UIApplication.shared.open(u) }
        return nil
    }

    /// The portal's touch fly gyro asks for motion: allowed (it is the owner's own page). The camera / mic never.
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        model.log.event("cop_media_denied")
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        present(message: message, cancel: false) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        present(message: message, cancel: true, done: completionHandler)
    }

    private func present(message: String, cancel: Bool, done: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: "snailCOP", message: message, preferredStyle: .alert)
        if cancel { a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) }) }
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in done(true) })
        guard let top = Self.topController() else { return done(false) }
        top.present(a, animated: true)
    }

    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var c = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let p = c?.presentedViewController { c = p }
        return c
    }
}

/// WKUserContentController retains its handlers: a weak hop avoids a cycle with the controller.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: CopController?
    init(_ t: CopController) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        target?.received(body)
    }
}
