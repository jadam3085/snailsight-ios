// SnailSight 10 "Live map" (plan §8.9 L1; wire contract docs/SNAILSIGHT-API.md §6b "Live keyframe streaming").
//
// While the mode is on and ARKit tracks normally, a keyframe is taken at 1–2 Hz (skipped while the phone is still:
// < 2 cm and < 2° since the last one): RGB 1024×768 JPEG (q 0.5) + LiDAR depth 16-bit PNG (mm) + confidence 8-bit PNG,
// K for camera.imageResolution and T_arkit_cam, encoded off the main thread into the binary `SSKF` frame
// (SnailSightCore.LiveKeyframe) and written to a disk SPOOL (Caches/livespool/<stream_id>/<seq>.kf) BEFORE it is sent,
// so a Wi-Fi drop, a server restart or memory pressure loses nothing. The uplink (LiveUplink, one serial queue) keeps
// one WebSocket to ws://<server>/v1/agents/{agent_id}/live: hello → welcome {last_seq} → spooled seqs ≤ last_seq are
// deleted and the rest resent in seq order with ≤ 8 unacknowledged; every ack deletes its file. Socket errors reconnect
// after 1, 2, 4, 8, 10 s and resume from the next welcome; after 3 failed WS connects the HTTP endpoints carry the
// frames one by one and the WS is tried again a minute later. `correction` messages (L2) are stored and logged only:
// applying them to AR content is L3.
//
// stream_id = one ARKit odometry frame: a new one ("ar-" + 8 hex, seq from 0) whenever MapLocalizer.worldFrameChanged
// fires. Older streams keep their own spool dir and are drained first (each on its own socket: hello → frames → bye).
// Turning the mode off sends `bye` once the stream's spool is empty, draining for up to 60 s; whatever is left stays on
// disk for the next time (same stream if the AR session is unchanged). Spool cap 2400 files (oldest dropped and logged),
// files older than 24 h are dropped at launch.
import ARKit
import CoreImage
import Foundation
import SnailSightCore
import UIKit

/// What the uplink reports to the HUD (main thread), once a second.
struct LiveSnapshot: Equatable {
    var active = false          // on, or draining after off
    var online = false          // a server welcome on the current connection
    var http = false
    var sent = 0
    var acked = 0
    var dups = 0
    var queue = 0               // spooled keyframe files, every stream
    var lagMs: Double?
    var placed: Bool?
    var via: String?
}

// MARK: - capture side (main thread)

final class LiveStreamer {
    private unowned let model: AppModel
    private let uplink: LiveUplink
    private var gate: LiveGate
    private(set) var streamID = LiveStreamID.make()
    private var nextSeq = 0
    private var encoding = false
    private var closedStreams = Set<String>()       // bye acknowledged: the next "on" needs a new stream id
    private var baseKnown = false
    private var lastBase: String?
    private var snapshot = LiveSnapshot()
    private var pausedReason: String?
    private var skippedStill = 0
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let enc = DispatchQueue(label: "snailsight.live.encode", qos: .utility)

    static let jpegQuality = 0.5

    init(model: AppModel) {
        self.model = model
        gate = LiveGate(rateHz: model.liveRateHz)
        let short = model.version.split(separator: " ").first.map(String.init) ?? model.version
        uplink = LiveUplink(log: model.log, link: model.link, agentID: model.agentID, appVersion: short)
        uplink.onSnapshot = { [weak self] s in
            guard let self else { return }
            self.snapshot = s
            self.publish()
        }
        uplink.onStreamClosed = { [weak self] id in self?.closedStreams.insert(id) }
        // 10.1 L3: a placed correction of this phone's stream moves the AR 1:1 content (blended) while the localizer
        // has no lock of its own; only for the map the AR layer shows (the live map's frame = that map's frame).
        uplink.onCorrection = { [weak self] T, stream, placed in
            guard let self, self.model.liveMapID == self.model.mapLocalizer.mapID else { return }
            self.model.controller.mapLayer.liveCorrection(T_map_arkit: T, stream: stream, placed: placed)
        }
    }

    /// LiDAR depth frames are needed while the mode is on (ARSessionController adds `.sceneDepth`).
    var wantsDepth: Bool { model.liveOn }

    // MARK: mode

    func setEnabled(_ on: Bool) {
        pushBase()
        if on {
            if closedStreams.contains(streamID) { newStream() }
            gate = LiveGate(rateHz: model.liveRateHz)
            pausedReason = nil
            model.log.event("live_on", ["stream_id": .string(streamID), "rate_hz": .double(gate.rateHz),
                                        "map_id": .string(model.liveMapID), "next_seq": .int(nextSeq),
                                        "server": .string(model.serverBase ?? "none")])
            uplink.start(stream: streamID, mapID: model.liveMapID, rateHz: gate.rateHz)
        } else {
            model.log.event("live_off", ["stream_id": .string(streamID), "last_seq": .int(nextSeq - 1),
                                         "queue": .int(snapshot.queue), "still_frames": .int(skippedStill)])
            uplink.stop()
        }
        if !model.showScans { model.controller.rerunConfiguration() }     // .sceneDepth on / off
        publish()
    }

    func rateChanged() {
        gate.rateHz = LiveGate.clampRate(model.liveRateHz)
        uplink.setRate(gate.rateHz)
        model.log.event("live_rate", ["rate_hz": .double(gate.rateHz)])
        publish()
    }

    /// The ARKit world frame changed (MapLocalizer.worldFrameChanged): every pose from now on is in a new odometry
    /// frame, so a new stream starts at seq 0; the old one drains under its own id.
    func worldFrameChanged(_ reason: String) {
        let old = streamID, oldLast = nextSeq - 1
        newStream()
        uplink.endStream(old)
        guard model.liveOn else { return }
        model.log.event("live_stream", ["from": .string(old), "to": .string(streamID), "reason": .string(reason),
                                        "old_last_seq": .int(oldLast)])
        uplink.start(stream: streamID, mapID: model.liveMapID, rateHz: gate.rateHz)
    }

    private func newStream() {
        streamID = LiveStreamID.make()
        nextSeq = 0
        gate.reset()
    }

    private func pushBase() {
        guard !baseKnown || model.serverBase != lastBase else { return }
        baseKnown = true
        lastBase = model.serverBase
        uplink.setBase(lastBase)
    }

    // MARK: frames

    /// Every AR frame (main). Cheap unless a keyframe is due.
    func frame(_ f: ARFrame) {
        guard model.liveOn else { return }
        pushBase()
        var paused: String?
        if model.recording { paused = "recording" }
        else if model.showScans { paused = "Scans" }
        else if model.thermal == "CRITICAL" { paused = "too hot" }
        else if case .normal = f.camera.trackingState {} else { paused = "tracking" }
        if paused != pausedReason {
            pausedReason = paused
            model.log.event("live_pause", ["reason": .string(paused ?? "resumed")])
            publish()
        }
        guard paused == nil, !encoding, let depth = f.sceneDepth else { return }
        let M = f.camera.transform
        var T = [Double](repeating: 0, count: 16)          // row-major camera → world
        for c in 0..<4 { for r in 0..<4 { T[r * 4 + c] = Double(M[c][r]) } }
        switch gate.check(t: f.timestamp, T: T) {
        case .capture: break
        case .still: skippedStill += 1; return
        case .tooSoon: return
        }
        gate.commit(t: f.timestamp, T: T)
        encoding = true
        let K = f.camera.intrinsics
        let res = f.camera.imageResolution
        let Kv = [Double(K[0][0]), Double(K[1][1]), Double(K[2][0]), Double(K[2][1])]
        let size = [Int(res.width), Int(res.height)]
        let (d, dw, dh) = CaptureRecorder.copyDepth(depth.depthMap)
        let conf = depth.confidenceMap.map { CaptureRecorder.copyBytes($0) }
        let img = CIImage(cvPixelBuffer: f.capturedImage)
        let stream = streamID, stamp = f.timestamp, wall = Date().timeIntervalSince1970
        enc.async { [weak self] in
            guard let self else { return }
            let rgb = self.jpeg(img)
            let dp = CaptureRecorder.png(d, width: dw, height: dh, bits: 16)
            let cp = conf.flatMap { CaptureRecorder.png($0.0, width: $0.1, height: $0.2, bits: 8) }
            DispatchQueue.main.async {
                self.encoding = false
                guard let dp, let rgb else {
                    self.model.log.event("live_encode_error", ["rgb": .bool(rgb != nil), "depth": .bool(dp != nil)])
                    return
                }
                guard stream == self.streamID, self.model.liveOn else { return }   // world frame changed / mode off meanwhile
                let seq = self.nextSeq                              // seqs stay contiguous: assigned only on success
                self.nextSeq += 1
                let h = LiveKeyframeHeader(seq: seq, streamID: stream, t: stamp, wall: wall, T: T, K: Kv,
                                           imageSize: size, tracking: "normal")
                var blobs: [(name: String, data: Data)] = [(name: "depth_png", data: dp), (name: "rgb_jpg", data: rgb)]
                if let cp { blobs.append((name: "conf_png", data: cp)) }
                self.uplink.enqueue(h, blobs: blobs)
            }
        }
    }

    private func jpeg(_ img: CIImage) -> Data? {
        let w = CGFloat(CaptureFormat.rgbSize.width), h = CGFloat(CaptureFormat.rgbSize.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: w / img.extent.width, y: h / img.extent.height))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ci.jpegRepresentation(of: scaled, colorSpace: space, options: [key: Self.jpegQuality])
    }

    // MARK: HUD

    func publish() {
        let s = snapshot
        guard model.liveOn || s.active else {
            if model.liveText != nil { model.liveText = nil }
            return
        }
        let text = LiveText.line(online: s.online, rateHz: gate.rateHz, sent: s.sent, acked: s.acked, queue: s.queue,
                                 lagMs: s.lagMs, placed: s.placed, via: s.via, http: s.http,
                                 paused: model.liveOn ? pausedReason : nil, draining: !model.liveOn)
        if model.liveText != text { model.liveText = text }
        let good = s.online && (model.liveOn ? pausedReason == nil : true)
        if model.liveGood != good { model.liveGood = good }
    }
}

// MARK: - uplink (spool + transport, one serial queue)

final class LiveUplink {
    private let q = DispatchQueue(label: "snailsight.live.uplink", qos: .utility)
    private let log: DebugLog
    private let link: ServerLink
    private let agentID: String
    private let appVersion: String
    private let session: URLSession
    private let root: URL?
    /// Both called on the main thread.
    var onSnapshot: ((LiveSnapshot) -> Void)?
    var onStreamClosed: ((String) -> Void)?
    /// 10.1: (T_map_arkit, stream_id, placed) of a `correction` (main thread).
    var onCorrection: ((Mat4, String, Bool) -> Void)?

    static let window = 8
    static let ackTimeoutS = 15.0
    static let maxResends = 6
    static let pingEveryS = 10.0
    static let silentDropS = 25.0
    static let connectTimeoutS = 8.0
    static let byeAckTimeoutS = 5.0
    static let drainS = 60.0
    static let statsEveryS = 10.0

    private struct StreamInfo: Codable {
        var streamID: String
        var mapID: String
        var created: Double
    }

    // streams + spool (q)
    private var streams: [String: StreamInfo] = [:]
    private var spool: [String: Set<Int>] = [:]
    private var lastSeq: [String: Int] = [:]          // highest seq spooled per stream (bye last_seq)
    private var ended = Set<String>()
    private var current: String?
    private var mapID = "site"
    private var rateHz = 2.0
    private var enabled = false
    private var drainUntil: Double?
    private var base: String?

    // connection (q)
    private enum Phase { case idle, connecting, open }
    private enum Mode { case ws, http }
    private var phase = Phase.idle
    private var mode = Mode.ws
    private var gen = 0
    private var task: URLSessionWebSocketTask?
    private var target: String?
    private var win = LiveWindow(limit: LiveUplink.window)
    private var transport = LiveTransportChoice()
    private var attempt = 0
    private var reconnectAt = 0.0
    private var connectStarted = 0.0
    private var lastInbound = 0.0
    private var lastPing = 0.0
    private var byeSentAt: Double?
    private var httpBusy = false
    private var lastProbe = 0.0
    private var everWelcomed = Set<String>()

    // stats (q)
    private var sent = 0, acked = 0, dups = 0, bytes = 0, reconnects = 0, dropped = 0, resent = 0
    private var recentLags: [Double] = []
    private var windowLags: [Double] = []
    private var lastStats = 0.0
    private var placed: Bool?
    private var via: String?
    private var correctionT: [Double]?
    private var timer: DispatchSourceTimer?

    private static var now: Double { Date().timeIntervalSince1970 }

    init(log: DebugLog, link: ServerLink, agentID: String, appVersion: String) {
        self.log = log
        self.link = link
        self.agentID = agentID
        self.appVersion = appVersion
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("livespool", isDirectory: true)
        q.async { self.loadSpool() }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: public (any thread → q)

    func setBase(_ b: String?) {
        q.async {
            let changed = b != self.base
            self.base = b
            if changed && b != nil && self.phase == .idle { self.reconnectAt = 0; self.pump() }
        }
    }

    func setRate(_ hz: Double) { q.async { self.rateHz = hz } }

    func start(stream: String, mapID: String, rateHz: Double) {
        q.async {
            self.enabled = true
            self.drainUntil = nil
            self.mapID = mapID
            self.rateHz = rateHz
            self.current = stream
            self.ended.remove(stream)
            self.ensureStream(stream)
            self.reconnectAt = 0
            self.pump()
            self.publish()
        }
    }

    /// Mode off: the current stream ends; bye once its spool is empty; drain for up to 60 s.
    func stop() {
        q.async {
            guard self.enabled else { return }
            if let c = self.current { self.ended.insert(c) }
            self.current = nil
            self.drainUntil = Self.now + Self.drainS
            self.pump()
            self.publish()
        }
    }

    /// The ARKit world frame changed: this stream gets no more keyframes.
    func endStream(_ id: String) {
        q.async {
            self.ended.insert(id)
            if self.current == id { self.current = nil }
            if self.streams[id] != nil && self.lastSeq[id] == nil && (self.spool[id] ?? []).isEmpty && self.target != id {
                self.removeStream(id)                       // never had a keyframe: nothing to tell the server
            }
            self.pump()
        }
    }

    /// Spool one keyframe (written to disk before anything is sent), then send it when the window allows.
    func enqueue(_ h: LiveKeyframeHeader, blobs: [(name: String, data: Data)]) {
        q.async {
            guard let data = LiveKeyframe.encode(h, blobs: blobs) else {
                self.log.event("live_encode_error", ["seq": .int(h.seq), "why": .string("header")])
                return
            }
            let s = h.streamID
            self.ensureStream(s)
            guard let url = self.fileURL(s, h.seq) else { return }
            do { try data.write(to: url, options: .atomic) } catch {
                self.log.event("live_drop", ["reason": .string("spool_write: \(error.localizedDescription)"),
                                             "seq": .int(h.seq), "queued": .int(self.queued)])
                self.dropped += 1
                return
            }
            self.spool[s, default: []].insert(h.seq)
            self.lastSeq[s] = max(self.lastSeq[s] ?? -1, h.seq)
            if s == self.target && self.phase == .open { self.win.add(h.seq) }
            self.enforceCap()
            self.pump()
        }
    }

    // MARK: spool files (q)

    private var queued: Int { spool.values.reduce(0) { $0 + $1.count } }

    private func dir(_ s: String) -> URL? { root?.appendingPathComponent(s, isDirectory: true) }
    private func fileURL(_ s: String, _ seq: Int) -> URL? { dir(s)?.appendingPathComponent(LiveSpool.fileName(seq)) }

    private func ensureStream(_ s: String) {
        guard streams[s] == nil, let d = dir(s) else { return }
        let info = StreamInfo(streamID: s, mapID: mapID, created: Self.now)
        streams[s] = info
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        if let j = try? JSONEncoder().encode(info) { try? j.write(to: d.appendingPathComponent("stream.json"), options: .atomic) }
    }

    private func deleteFile(_ s: String, _ seq: Int) {
        spool[s]?.remove(seq)
        if let u = fileURL(s, seq) { try? FileManager.default.removeItem(at: u) }
    }

    private func removeStream(_ s: String) {
        if let d = dir(s) { try? FileManager.default.removeItem(at: d) }
        streams[s] = nil
        spool[s] = nil
        lastSeq[s] = nil
        ended.remove(s)
    }

    /// Launch: every spool dir left from earlier runs is an ended stream (a new app run = a new ARKit session); files
    /// older than 24 h go.
    private func loadSpool() {
        guard let r = root else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: r, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: r, includingPropertiesForKeys: nil)) ?? []
        let now = Self.now
        var expired = 0, kept = 0
        for d in dirs {
            let s = d.lastPathComponent
            let names = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
            var seqs = Set<Int>()
            for n in names {
                guard let seq = LiveSpool.seq(fromFile: n) else { continue }
                let p = d.appendingPathComponent(n).path
                let m = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? now
                if now - m > LiveSpool.maxAgeS { try? fm.removeItem(atPath: p); expired += 1 } else { seqs.insert(seq) }
            }
            guard !seqs.isEmpty else { try? fm.removeItem(at: d); continue }
            var info = StreamInfo(streamID: s, mapID: "site", created: now)
            if let j = try? Data(contentsOf: d.appendingPathComponent("stream.json")),
               let i = try? JSONDecoder().decode(StreamInfo.self, from: j) { info = i }
            streams[s] = info
            spool[s] = seqs
            lastSeq[s] = seqs.max()
            ended.insert(s)
            kept += seqs.count
        }
        if expired > 0 || kept > 0 {
            log.event("live_spool_load", ["streams": .int(streams.count), "queued": .int(kept), "expired": .int(expired)])
        }
        if expired > 0 {
            dropped += expired
            log.event("live_drop", ["reason": .string("expired_24h"), "dropped": .int(expired), "queued": .int(kept)])
        }
        enforceCap()
    }

    private func enforceCap() {
        let total = queued
        guard total > LiveSpool.cap else { return }
        var keys: [LiveSpoolKey] = []
        keys.reserveCapacity(total)
        for (s, seqs) in spool {
            let order = streams[s]?.created ?? 0
            for n in seqs { keys.append(LiveSpoolKey(stream: s, order: order, seq: n)) }
        }
        let out = LiveSpool.evictions(keys)
        for k in out {
            deleteFile(k.stream, k.seq)
            if k.stream == target { win.remove(k.seq) }
        }
        dropped += out.count
        log.event("live_drop", ["reason": .string("spool_cap"), "dropped": .int(out.count), "queued": .int(queued),
                                "first": .string("\(out.first?.stream ?? "")/\(out.first?.seq ?? -1)")])
    }

    // MARK: driving (q)

    /// The stream to send next: the oldest ended stream with files (or still owing its bye), else the live stream.
    private func chooseTarget() -> String? {
        let owing = streams.values.filter { info in
            ended.contains(info.streamID) && (!(spool[info.streamID] ?? []).isEmpty || lastSeq[info.streamID] != nil)
        }
        if let o = owing.min(by: { $0.created < $1.created }) { return o.streamID }
        if enabled && drainUntil == nil { return current }
        return nil
    }

    private func pump() {
        guard enabled else { return }
        let now = Self.now
        if target == nil {
            guard let t = chooseTarget() else {
                if drainUntil != nil { finishDrain("drained") }
                return
            }
            target = t
        }
        switch phase {
        case .connecting:
            return
        case .idle:
            guard now >= reconnectAt else { return }
            guard base != nil else { probe(); return }
            if transport.useHTTP { httpHello() } else { connectWS() }
        case .open:
            if mode == .ws { wsPump() } else { httpPump() }
        }
    }

    private func targetDone() -> Bool {
        guard let t = target else { return false }
        return ended.contains(t) && win.isEmpty && (spool[t] ?? []).isEmpty
    }

    private func probe() {
        let now = Self.now
        guard now - lastProbe > 15 else { return }
        lastProbe = now
        let lk = link
        Task { await lk.probe(force: true) }
    }

    private func helloObject(_ s: String) -> [String: Any] {
        ["type": "hello", "agent_type": Identity.agentType, "stream_id": s,
         "map_id": streams[s]?.mapID ?? mapID, "app_version": appVersion, "rate_hz": Int(rateHz.rounded())]
    }

    // MARK: WebSocket

    private func connectWS() {
        guard let b = base, let t = target else { return }
        var ws = b
        if ws.hasPrefix("https://") { ws = "wss://" + String(ws.dropFirst(8)) }
        else if ws.hasPrefix("http://") { ws = "ws://" + String(ws.dropFirst(7)) }
        guard let url = URL(string: ws + "/v1/agents/\(agentID)/live") else { return }
        gen += 1
        let g = gen
        phase = .connecting
        mode = .ws
        connectStarted = Self.now
        lastInbound = connectStarted
        lastPing = connectStarted
        byeSentAt = nil
        let tk = session.webSocketTask(with: url)
        tk.maximumMessageSize = 4 << 20
        task = tk
        tk.resume()
        let hello = helloObject(t)
        log.event("live_hello", ["stream_id": .string(t), "url": .string(url.absoluteString), "mode": .string("ws"),
                                 "queued": .int((spool[t] ?? []).count), "attempt": .int(attempt)])
        sendText(hello, g: g)
        receive(g)
    }

    private func sendText(_ o: [String: Any], g: Int) {
        guard let tk = task, let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        tk.send(.string(String(decoding: d, as: UTF8.self))) { [weak self] err in
            guard let self, let err else { return }
            self.q.async {
                guard g == self.gen else { return }
                self.connectionFailed("send: \(err.localizedDescription)")
            }
        }
    }

    private func receive(_ g: Int) {
        guard let tk = task else { return }
        tk.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard g == self.gen else { return }
                switch result {
                case .success(let m):
                    self.lastInbound = Self.now
                    switch m {
                    case .string(let s): self.handle(JSON.object(Data(s.utf8)))
                    case .data(let d): self.handle(JSON.object(d))
                    @unknown default: break
                    }
                    if g == self.gen { self.receive(g) }
                case .failure(let e):
                    self.connectionFailed("receive: \(e.localizedDescription)")
                }
            }
        }
    }

    private func wsPump() {
        guard let t = target, let tk = task else { return }
        let g = gen
        while let s = win.next(now: Self.now) {
            guard let u = fileURL(t, s), let d = try? Data(contentsOf: u) else {
                win.remove(s)                              // evicted meanwhile
                spool[t]?.remove(s)
                continue
            }
            sent += 1
            bytes += d.count
            tk.send(.data(d)) { [weak self] err in
                guard let self, let err else { return }
                self.q.async {
                    guard g == self.gen else { return }
                    self.connectionFailed("send kf: \(err.localizedDescription)")
                }
            }
        }
        if targetDone() && byeSentAt == nil { sendBye() }
    }

    private func sendBye() {
        guard let t = target else { return }
        let last = lastSeq[t] ?? -1
        byeSentAt = Self.now
        log.event("live_bye", ["stream_id": .string(t), "last_seq": .int(last), "mode": .string(mode == .ws ? "ws" : "http")])
        if mode == .ws {
            sendText(["type": "bye", "last_seq": last], g: gen)
        } else {
            let g = gen, lk = link, path = "/v1/agents/\(agentID)/live/bye"
            let body = JSON.body(["stream_id": t, "last_seq": last])
            httpBusy = true
            Task { [weak self] in
                let r = try? await lk.request("POST", path, body: body, timeout: 10)
                self?.q.async {
                    guard let self, g == self.gen else { return }
                    self.httpBusy = false
                    self.byeAcked(r.map { JSON.object($0.0) } ?? [:])
                }
            }
        }
    }

    // MARK: HTTP fallback (API §6b: same semantics, one keyframe per request)

    private func httpHello() {
        guard let t = target else { return }
        gen += 1
        let g = gen
        phase = .connecting
        mode = .http
        connectStarted = Self.now
        byeSentAt = nil
        httpBusy = true
        var o = helloObject(t)
        o["type"] = nil
        let body = JSON.body(o), lk = link, path = "/v1/agents/\(agentID)/live/hello"
        log.event("live_hello", ["stream_id": .string(t), "mode": .string("http"), "queued": .int((spool[t] ?? []).count)])
        Task { [weak self] in
            var res: (Data, Int)?
            var err = ""
            do { res = try await lk.request("POST", path, body: body, timeout: 10) } catch { err = error.localizedDescription }
            self?.q.async {
                guard let self, g == self.gen else { return }
                self.httpBusy = false
                if let r = res, r.1 == 200 { self.welcomed(JSON.object(r.0)) }
                else { self.connectionFailed("http hello: \(res.map { "HTTP \($0.1)" } ?? err)") }
            }
        }
    }

    private func httpPump() {
        guard !httpBusy, let t = target else { return }
        if targetDone() {
            if byeSentAt == nil { sendBye() }
            return
        }
        guard let s = win.next(now: Self.now) else { return }
        guard let u = fileURL(t, s), let d = try? Data(contentsOf: u) else {
            win.remove(s)
            spool[t]?.remove(s)
            pump()
            return
        }
        sent += 1
        bytes += d.count
        httpBusy = true
        let g = gen, lk = link, path = "/v1/agents/\(agentID)/live/keyframes"
        Task { [weak self] in
            var res: (Data, Int)?
            var err = ""
            do {
                res = try await lk.request("POST", path, body: d, contentType: "application/octet-stream", timeout: 20)
            } catch { err = error.localizedDescription }
            self?.q.async {
                guard let self, g == self.gen else { return }
                self.httpBusy = false
                guard let r = res, r.1 == 200 else {
                    self.connectionFailed("http keyframe: \(res.map { "HTTP \($0.1)" } ?? err)")
                    return
                }
                self.lastInbound = Self.now
                let o = JSON.object(r.0)
                for c in (o["corrections"] as? [[String: Any]]) ?? [] { self.correction(c) }
                if let a = o["ack"] as? [String: Any] { self.ackReceived(a) } else { self.pump() }
            }
        }
    }

    // MARK: messages (q)

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String ?? "" {
        case "welcome": welcomed(o)
        case "ack": ackReceived(o)
        case "correction": correction(o)
        case "bye_ack": byeAcked(o)
        case "pong": break
        case "error":
            let detail = JSON.string(o, "detail") ?? "?"
            let status = JSON.int(o, "status") ?? 0
            if phase == .connecting || status >= 500 {           // hello refused / live unit down: back off, retry
                log.event("live_error", ["detail": .string(detail), "status": .int(status)])
                connectionFailed("server: \(status) \(detail.prefix(80))", transportFault: false)
                return
            }
            let s = win.requeueOldest()                          // a bad frame: the contract says resend that seq
            log.event("live_error", ["detail": .string(detail), "status": .int(status), "requeued": .int(s ?? -1)])
            if let s, (win.resends[s] ?? 0) > Self.maxResends, let t = target {
                deleteFile(t, s)
                win.remove(s)
                dropped += 1
                log.event("live_drop", ["reason": .string("rejected"), "seq": .int(s), "queued": .int(queued)])
            }
            pump()
        default:
            log.event("live_unknown", ["type": .string(o["type"] as? String ?? "?")])
        }
    }

    private func welcomed(_ o: [String: Any]) {
        guard let t = target else { return }
        let last = JSON.int(o, "last_seq") ?? -1
        if let echo = JSON.string(o, "stream_id"), echo != t {
            log.event("live_error", ["detail": .string("welcome for \(echo), expected \(t)")])
        }
        phase = .open
        if mode == .ws { transport.wsConnected() }
        attempt = 0
        lastInbound = Self.now
        let plan = LiveSpool.afterWelcome(spooled: Array(spool[t] ?? []), lastSeq: last)
        for s in plan.drop { deleteFile(t, s) }
        win.reset(plan.resend)
        var ev: [String: LogValue] = ["stream_id": .string(t), "last_seq": .int(last), "have": .int(JSON.int(o, "have") ?? 0),
                                      "mode": .string(mode == .ws ? "ws" : "http"), "already_stored": .int(plan.drop.count)]
        if let a = o["anchored"] as? Bool { ev["anchored"] = .bool(a) }
        if let v = JSON.int(o, "base_version") { ev["base_version"] = .int(v) }
        log.event("live_welcome", ev)
        if !plan.resend.isEmpty && (everWelcomed.contains(t) || last >= 0 || plan.resend.first != 0) {
            resent += plan.resend.count
            log.event("live_resume", ["stream_id": .string(t), "resent": .int(plan.resend.count),
                                      "from": .int(plan.resend.first ?? -1)])
        }
        everWelcomed.insert(t)
        pump()
        publish()
    }

    private func ackReceived(_ o: [String: Any]) {
        guard let t = target, let seq = JSON.int(o, "seq") else { pump(); return }
        let contiguous = JSON.int(o, "last_seq") ?? -1
        for s in win.acked(seq, contiguous: contiguous) { deleteFile(t, s) }
        for s in (spool[t] ?? []) where s <= contiguous { deleteFile(t, s) }
        acked += 1
        if (o["dup"] as? Bool) == true { dups += 1 }
        if let lag = (o["lag_ms"] as? NSNumber)?.doubleValue {
            recentLags.append(lag)
            if recentLags.count > 20 { recentLags.removeFirst(recentLags.count - 20) }
            windowLags.append(lag)
        }
        pump()
    }

    private func correction(_ o: [String: Any]) {
        let p = o["placed"] as? Bool
        let v = JSON.string(o, "via")
        let T = (o["T_map_odom"] as? [NSNumber])?.map { $0.doubleValue }
        var ev: [String: LogValue] = ["placed": .bool(p ?? false), "via": .string(v ?? ""),
                                      "seq": .int(JSON.int(o, "seq") ?? -1),
                                      "stream_id": .string(JSON.string(o, "stream_id") ?? "")]
        if let T, T.count == 16 {
            ev["dx"] = .double(T[3]); ev["dy"] = .double(T[7]); ev["dz"] = .double(T[11])
            ev["yaw_deg"] = .double(atan2(T[4], T[0]) * 180 / .pi)
            if let old = correctionT, old.count == 16 {
                let dx = T[3] - old[3], dy = T[7] - old[7], dz = T[11] - old[11]
                ev["moved_cm"] = .double((dx * dx + dy * dy + dz * dz).squareRoot() * 100)
            }
            correctionT = T
        }
        if let b = JSON.int(o, "base_version") { ev["base_version"] = .int(b) }
        placed = p
        via = v
        log.event("live_correction", ev)         // 10.1 L3: applied to the AR 1:1 content (MapARLayer, blended)
        if let A = (o["T_map_arkit"] as? [NSNumber])?.map({ $0.doubleValue }), A.count == 16,
           let sid = JSON.string(o, "stream_id") {
            let placedNow = p ?? false
            DispatchQueue.main.async { [weak self] in self?.onCorrection?(Mat4(A), sid, placedNow) }
        }
        publish()
    }

    private func byeAcked(_ o: [String: Any]) {
        guard let t = target else { return }
        let missing = (o["missing"] as? [Any])?.count ?? 0
        log.event("live_bye_ack", ["stream_id": .string(t), "stored": .int(JSON.int(o, "stored") ?? -1),
                                   "missing": .int(missing), "dups": .int(JSON.int(o, "dups") ?? 0)])
        finishTarget()
    }

    /// The target stream is complete on the server: close this connection, forget the stream, go to the next one.
    private func finishTarget() {
        guard let t = target else { return }
        closeConnection()
        removeStream(t)
        everWelcomed.remove(t)
        target = nil
        reconnectAt = 0
        DispatchQueue.main.async { [weak self] in self?.onStreamClosed?(t) }
        pump()
        publish()
    }

    private func closeConnection() {
        gen += 1
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        phase = .idle
        httpBusy = false
        byeSentAt = nil
        win.clear()
    }

    /// `transportFault` false = the server answered but refused (e.g. its live unit is down): back off without
    /// counting it towards the WS → HTTP fallback.
    private func connectionFailed(_ reason: String, transportFault: Bool = true) {
        guard phase != .idle else { return }
        let wasOpen = phase == .open
        let wasWS = mode == .ws
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        phase = .idle
        httpBusy = false
        byeSentAt = nil
        win.requeueAll()
        let now = Self.now
        if wasWS && !wasOpen && transportFault && transport.wsFailed(now: now) {
            log.event("live_transport", ["mode": .string("http"), "ws_failures": .int(transport.wsFailures)])
        }
        reconnects += 1
        let d = LiveBackoff.delay(attempt: attempt)
        attempt += 1
        reconnectAt = now + d
        log.event("live_drop", ["reason": .string(reason), "queued": .int(queued), "was_open": .bool(wasOpen),
                                "retry_s": .double(d), "mode": .string(wasWS ? "ws" : "http")])
        probe()
        publish()
    }

    private func finishDrain(_ reason: String) {
        log.event("live_drain_end", ["reason": .string(reason), "queued": .int(queued), "sent": .int(sent),
                                     "acked": .int(acked)])
        if phase != .idle { closeConnection() }
        target = nil
        enabled = false
        drainUntil = nil
        publish()
    }

    // MARK: timer (q, 1 Hz)

    private func tick() {
        let now = Self.now
        guard enabled else { return }
        if phase == .connecting && mode == .ws && now - connectStarted > Self.connectTimeoutS {
            connectionFailed("connect timeout")
        }
        if phase == .open && mode == .ws {
            let late = win.expire(now: now, timeout: Self.ackTimeoutS)
            if !late.isEmpty {
                for s in late where (win.resends[s] ?? 0) > Self.maxResends {
                    if let t = target { deleteFile(t, s) }
                    win.remove(s)
                    dropped += 1
                    log.event("live_drop", ["reason": .string("unacked"), "seq": .int(s), "queued": .int(queued)])
                }
                log.event("live_ack_timeout", ["seqs": .int(late.count), "first": .int(late.first ?? -1)])
                pump()
            }
            if now - lastPing >= Self.pingEveryS {
                lastPing = now
                sendText(["type": "ping"], g: gen)
            }
            if now - lastInbound > Self.silentDropS { connectionFailed("no reply for \(Int(Self.silentDropS)) s") }
        }
        if let b = byeSentAt, now - b > Self.byeAckTimeoutS, phase == .open {
            log.event("live_bye_ack", ["stream_id": .string(target ?? ""), "timeout": .bool(true)])
            finishTarget()
        }
        if !httpBusy && phase != .connecting && transport.shouldRetryWS(now: now) {
            log.event("live_transport", ["mode": .string("ws"), "why": .string("retry")])
            if phase == .open { closeConnection() }
            reconnectAt = 0
        }
        if let d = drainUntil, now > d, enabled { finishDrain("timeout") }
        if phase == .idle { pump() }
        if now - lastStats >= Self.statsEveryS {
            lastStats = now
            log.event("live_stats", ["sent": .int(sent), "acked": .int(acked), "dups": .int(dups), "queue": .int(queued),
                                     "lag_ms_p50": .double(LiveText.median(windowLags) ?? -1),
                                     "reconnects": .int(reconnects), "bytes": .int(bytes), "dropped": .int(dropped),
                                     "resent": .int(resent), "online": .bool(phase == .open),
                                     "mode": .string(mode == .ws ? "ws" : "http"), "stream_id": .string(target ?? "")])
            windowLags = []
        }
        publish()
    }

    private func publish() {
        var s = LiveSnapshot()
        s.active = enabled
        s.online = phase == .open
        s.http = mode == .http
        s.sent = sent
        s.acked = acked
        s.dups = dups
        s.queue = queued
        s.lagMs = LiveText.median(recentLags)
        s.placed = placed
        s.via = via
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(s) }
    }
}
