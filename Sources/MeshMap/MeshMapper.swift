// SnailSight 10.2 "Map mesh" (owner: "I may open the app in any place, but don't necessarily want to record ...
// Otherwise do a non-splat data collection just for colored mesh?"). Wire contract: API §5.10 (`/v1/meshmap`);
// pure parts (gate, chunk format, ledger, wording): SnailSightCore/MeshMap.swift.
//
// While More ▸ Mapping ▸ "Map mesh" is on (off at launch), or "Auto when localized" is set and the phone is localized:
//   * LiDAR depth (256×192 mm + confidence) + a 256×192 colour image at ≤ 2 Hz, only after ≥ 10 cm / 8° of motion;
//   * a SHARP full-resolution colour keyframe (1920×1440 JPEG) every ~0.75 m or 20°, taken on a frame with ≤ 2 px
//     predicted motion blur (ARCamera speed × exposure), with its depth;
//   * ARKit scene-reconstruction mesh anchors (new / grown ≥ 15 %) every ~5 s;
//   * the map alignment (MapLocalizer's T_map_arkit) on every frame + an `align` chunk at each lock / refinement.
// No video stream, no audio. Each chunk is written to Documents/meshmap/<upload_id>/chunks/<seq>.ssmm BEFORE it is sent
// (crash / offline safe) and uploaded one at a time in seq order (PUT …/chunks/{seq}, idempotent); turning mapping off
// (or leaving the app) finishes the upload once everything is acknowledged (POST …/finish); the server then fuses the
// new depth into the house mesh for the covered 4 m tiles and re-bakes their texture as a CPU job → a new map version,
// which the app polls for and announces. Paused while recording (the capture has it all), with Scans open, when too hot,
// while tracking is limited, or when the spool passes 1.5 GB.
import ARKit
import CoreImage
import Foundation
import SnailSightCore
import UIKit

final class MeshMapper {
    private unowned let model: AppModel
    private var gate = MeshMapGate()
    private var anchors = MeshAnchorTracker()
    private var dirty: [UUID: ARMeshAnchor] = [:]
    private(set) var streamID = LiveStreamID.make()
    private var current: String?                         // upload id being captured into
    private var ledgers: [String: MeshMapLedger] = [:]   // every upload not yet finished on the server
    private var capturing = false
    private var pausedReason: String?
    private var encoding = false
    private var lastMeshFlush = 0.0
    private var motionPrev: (t: Double, pos: [Double], q: CaptureFormat.Quat)?
    private var lastPersist: [String: Double] = [:]
    private var pumping = false
    private var backoffUntil = 0.0
    private var backoff = 2.0
    private var lastPoll: [String: Double] = [:]
    private var recentText: (text: String, until: Double)?
    private var unlocalizedSince: Double?
    static let autoGraceS = 120.0
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let enc = DispatchQueue(label: "snailsight.meshmap.encode", qos: .utility)

    static let smallRGB = (width: 256, height: 192)
    static let smallQuality = 0.6
    static let keyframeQuality = 0.8
    static let meshFlushS = 5.0
    static let pollS = 20.0
    static let spoolCapBytes: Int64 = 1_500 * 1_048_576

    init(model: AppModel) {
        self.model = model
        loadLedgers()
    }

    private var now: Double { Date().timeIntervalSince1970 }

    /// `.sceneDepth` is needed while mapping is wanted (ARSessionController.makeConfiguration).
    var wantsDepth: Bool { capturing }

    static var root: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("meshmap")
    }

    private func dir(_ id: String) -> URL? { Self.root?.appendingPathComponent(id) }
    private func chunkURL(_ id: String, _ seq: Int) -> URL? {
        dir(id)?.appendingPathComponent("chunks").appendingPathComponent(String(format: "%08d.ssmm", seq))
    }

    // MARK: mode

    /// Toggle / auto / lock changed (main; also every HUD tick): start or stop capturing. In auto mode a lost lock
    /// keeps the upload open for `autoGraceS` (an ARKit reset re-locks in seconds; every finished upload is a server
    /// job and a new map version, so no churn).
    func update() {
        let localized = model.mapLocalizer.isLocked
        var want = MeshMapPolicy.wanted(toggle: model.meshMapOn, auto: model.meshMapAuto, localized: localized)
        if model.roomScanOn { want = false }                 // 11.3: RoomPlan owns the session's configuration meanwhile
        if capturing && !want && model.meshMapAuto && !model.meshMapOn {
            if unlocalizedSince == nil { unlocalizedSince = now }
            want = now - (unlocalizedSince ?? now) < Self.autoGraceS
        } else {
            unlocalizedSince = nil
        }
        guard want != capturing else { publish(); return }
        if want { start() } else { stop(reason: model.meshMapAuto && !model.meshMapOn && !localized ? "auto_unlocalized" : "off") }
    }

    private func start() {
        let id = MeshMapID.make(date: Date())
        var l = MeshMapLedger(uploadID: id, mapID: model.mapLocalizer.mapID, created: now)
        l.state = .capturing
        ledgers[id] = l
        current = id
        capturing = true
        gate.reset()
        anchors.reset()
        dirty.removeAll()
        motionPrev = nil
        persist(id, force: true)
        if !model.arSuspended { model.controller.rerunConfiguration() }        // .sceneDepth on
        model.log.event("meshmap_on", ["upload_id": .string(id), "stream_id": .string(streamID),
                                       "auto": .bool(!model.meshMapOn), "localized": .bool(model.mapLocalizer.isLocked)])
        if let al = model.mapLocalizer.alignment {                          // the stream's alignment up front
            alignmentChanged(al, spreadCm: al.spreadCm, errCm: model.mapLocalizer.errorEstimate)
        }
        model.flash("Mapping the mesh: walk slowly; no video or audio is recorded", seconds: 3)
        publish()
        pump()
    }

    /// Capture over (toggle off, auto lost the lock, app backgrounded): the upload finishes once all is sent.
    func stop(reason: String) {
        guard capturing, let id = current else { return }
        capturing = false
        current = nil
        dirty.removeAll()
        ledgers[id]?.stopCapture(now: now)
        persist(id, force: true)
        if !model.arSuspended { model.controller.rerunConfiguration() }        // .sceneDepth off (unless others want it)
        let l = ledgers[id]
        model.log.event("meshmap_off", ["upload_id": .string(id), "reason": .string(reason),
                                        "chunks": .int(l?.nextSeq ?? 0), "keyframes": .int(l?.keyframes ?? 0),
                                        "frames": .int(l?.frames ?? 0),
                                        "mb": .double(Double(l?.bytes ?? 0) / 1_048_576)])
        publish()
        pump()
    }

    func appBackground() { stop(reason: "background") }

    /// The ARKit world frame changed (MapLocalizer.worldFrameChanged): a new stream id; the upload continues.
    func worldFrameChanged(_ reason: String) {
        streamID = LiveStreamID.make()
        gate.reset()
        anchors.reset()
        dirty.removeAll()
        motionPrev = nil
        if capturing { model.log.event("meshmap_stream", ["stream_id": .string(streamID), "reason": .string(reason)]) }
    }

    // MARK: capture (main)

    private func currentAlign() -> MeshMapAlign? {
        guard let al = model.mapLocalizer.alignment else { return nil }
        return MeshMapAlign(T: al.T.m, version: al.version, method: al.method, errCm: model.mapLocalizer.errorEstimate)
    }

    private var spoolBytes: Int64 {
        ledgers.values.reduce(Int64(0)) { acc, l in
            acc + max(0, l.bytes - l.sentBytes)
        }
    }

    func frame(_ f: ARFrame) {
        guard capturing, let id = current else { return }
        var trackingNormal = false
        if case .normal = f.camera.trackingState { trackingNormal = true }
        let reason = MeshMapPolicy.pauseReason(
            recording: model.recording, scansOpen: model.arSuspended, thermalCritical: model.thermal == "CRITICAL",
            trackingNormal: trackingNormal, meshSupported: ARSessionController.supportsMesh,
            depthSupported: ARSessionController.supportsDepth, spoolFull: spoolBytes > Self.spoolCapBytes)
        if reason != pausedReason {
            pausedReason = reason
            model.log.event("meshmap_pause", ["reason": .string(reason ?? "resumed")])
            publish()
        }
        guard reason == nil, let depth = f.sceneDepth else { return }
        let m = f.camera.transform
        var T = [Double](repeating: 0, count: 16)
        for c in 0..<4 { for r in 0..<4 { T[r * 4 + c] = Double(m[c][r]) } }
        let t = f.timestamp
        let pos = [T[3], T[7], T[11]]
        let q = CaptureFormat.quaternion(rows: [[T[0], T[1], T[2]], [T[4], T[5], T[6]], [T[8], T[9], T[10]]])
        var blur: Double?
        if let p = motionPrev, t > p.t {
            let dt = t - p.t
            let dx = pos[0] - p.pos[0], dy = pos[1] - p.pos[1], dz = pos[2] - p.pos[2]
            blur = KeyframeQuality.predictedBlurPx(
                angularSpeedRadS: AdaptiveCapture.rotationDegrees(p.q, q) * .pi / 180 / dt,
                linearSpeedMS: (dx * dx + dy * dy + dz * dz).squareRoot() / dt, depthM: 1.5,
                exposureS: f.camera.exposureDuration, focalPx: Double(f.camera.intrinsics[0][0]))
        }
        motionPrev = (t, pos, q)
        guard !encoding else { return }
        let hot = model.thermal == "SERIOUS"
        let d = gate.decide(t: t, T: T, blurPx: blur, hot: hot)
        guard d != .skip else { return }
        gate.commit(d, t: t, T: T)
        encoding = true
        let K = f.camera.intrinsics
        let res = f.camera.imageResolution
        let Kv = [Double(K[0][0]), Double(K[1][1]), Double(K[2][0]), Double(K[2][1])]
        let size = [Int(res.width), Int(res.height)]
        let (dd, dw, dh) = CaptureRecorder.copyDepth(depth.depthMap)
        let conf = depth.confidenceMap.map { CaptureRecorder.copyBytes($0) }
        let pixels = f.capturedImage
        let keyframe = d == .keyframe
        let stream = streamID, wall = now, align = currentAlign()
        enc.async { [weak self] in
            guard let self else { return }
            let img = CIImage(cvPixelBuffer: pixels)
            let rgb = keyframe ? self.jpeg(img, size: nil, quality: Self.keyframeQuality)
                               : self.jpeg(img, size: Self.smallRGB, quality: Self.smallQuality)
            let sharp = keyframe ? Self.sharpness(pixels) : nil
            let dp = CaptureRecorder.png(dd, width: dw, height: dh, bits: 16)
            let cp = conf.flatMap { CaptureRecorder.png($0.0, width: $0.1, height: $0.2, bits: 8) }
            DispatchQueue.main.async {
                self.encoding = false
                guard let rgb, let dp else {
                    self.model.log.event("meshmap_encode_error", ["rgb": .bool(rgb != nil), "depth": .bool(dp != nil)])
                    return
                }
                guard self.current == id else { return }               // stopped meanwhile
                var blobs: [(name: String, data: Data)] = [(name: "depth_png", data: dp)]
                if let cp { blobs.append((name: "conf_png", data: cp)) }
                blobs.append((name: "rgb_jpg", data: rgb))
                self.spool(id, kind: keyframe ? .keyframe : .depth, blobs: blobs) { seq in
                    MeshMapChunk.frameHeader(kind: keyframe ? .keyframe : .depth, seq: seq, streamID: stream, t: t,
                                             wall: wall, T: T, K: Kv, imageSize: size, align: align,
                                             sharpness: sharp, blurPx: blur)
                }
            }
        }
    }

    /// ARMeshAnchors added / updated (ARSessionDelegate, main): remembered until the next mesh flush.
    func anchorsChanged(_ list: [ARMeshAnchor]) {
        guard capturing else { return }
        for a in list { dirty[a.identifier] = a }
    }

    func anchorRemoved(_ id: UUID) {
        dirty[id] = nil
        anchors.removed(id: id.uuidString)
    }

    /// MapLocalizer locked / refined: an `align` chunk for this stream (frames before the lock can use it).
    func alignmentChanged(_ al: MapAlignment, spreadCm: Double?, errCm: Double?) {
        guard capturing, let id = current else { return }
        let a = MeshMapAlign(T: al.T.m, version: al.version, method: al.method, errCm: errCm)
        let stream = streamID, t = model.controller.arView.session.currentFrame?.timestamp ?? 0, wall = now
        spool(id, kind: .align, blobs: []) { seq in
            MeshMapChunk.alignHeader(seq: seq, streamID: stream, t: t, wall: wall, align: a, spreadCm: spreadCm)
        }
    }

    /// Twice a second (HUD tick): mesh anchors every few seconds, ledger saves, upload pump, HUD line.
    func tick() {
        let t = now
        if capturing || model.meshMapOn || model.meshMapAuto { update() }   // also re-starts after the app was away
        if capturing, pausedReason == nil, !encoding, t - lastMeshFlush >= Self.meshFlushS, !dirty.isEmpty {
            lastMeshFlush = t
            flushMesh()
        }
        if ledgers.values.contains(where: { $0.state == .processing && t - (lastPoll[$0.uploadID] ?? 0) >= Self.pollS }) ||
            ledgers.values.contains(where: { !$0.terminal && $0.state != .processing && ($0.pending > 0 || !$0.registered || $0.readyToFinish) }) {
            pump()
        }
        if let r = recentText, t > r.until { recentText = nil; publish() }
    }

    private func flushMesh() {
        guard let id = current else { return }
        let t = now
        var entries: [MeshAnchorEntry] = []
        var blobs: [(name: String, data: Data)] = []
        var bytes = 0
        for (uid, a) in dirty {
            let g = a.geometry
            let key = uid.uuidString
            guard anchors.wants(id: key, vertices: g.vertices.count, now: t) else { continue }
            guard let geo = Self.copyGeometry(g) else { continue }
            let (v, f) = geo
            let blob = MeshAnchorPack.encode(vertices: v, faces: f)
            if bytes + blob.count > MeshAnchorTracker.maxBytesPerChunk && !entries.isEmpty { break }
            let m = a.transform
            var T = [Double](repeating: 0, count: 16)
            for c in 0..<4 { for r in 0..<4 { T[r * 4 + c] = Double(m[c][r]) } }
            entries.append(MeshAnchorEntry(id: key, T: T, vertices: v.count / 3, faces: f.count / 3))
            blobs.append((name: "a\(entries.count - 1)", data: blob))
            bytes += blob.count
            anchors.didSend(id: key, vertices: g.vertices.count, now: t)
        }
        for e in entries { if let u = UUID(uuidString: e.id) { dirty[u] = nil } }
        guard !entries.isEmpty else { return }
        let stream = streamID, ts = model.controller.arView.session.currentFrame?.timestamp ?? 0
        spool(id, kind: .mesh, blobs: blobs) { seq in
            MeshMapChunk.meshHeader(seq: seq, streamID: stream, t: ts, wall: t, anchors: entries)
        }
    }

    static func copyGeometry(_ g: ARMeshGeometry) -> ([Float], [UInt32])? {
        let vs = g.vertices, fs = g.faces
        guard vs.count > 0, fs.count > 0, vs.format == .float3, fs.bytesPerIndex == 4, fs.indexCountPerPrimitive == 3
        else { return nil }
        var v = [Float]()
        v.reserveCapacity(vs.count * 3)
        for i in 0..<vs.count {
            let p = g.vertex(at: UInt32(i))
            v.append(p.x); v.append(p.y); v.append(p.z)
        }
        let n = fs.count * 3
        let ip = fs.buffer.contents().bindMemory(to: UInt32.self, capacity: n)
        return (v, Array(UnsafeBufferPointer(start: ip, count: n)))
    }

    private func jpeg(_ img: CIImage, size: (width: Int, height: Int)?, quality: Double) -> Data? {
        var out = img
        if let s = size {
            out = img.transformed(by: CGAffineTransform(scaleX: CGFloat(s.width) / img.extent.width,
                                                        y: CGFloat(s.height) / img.extent.height))
                .cropped(to: CGRect(x: 0, y: 0, width: s.width, height: s.height))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ci.jpegRepresentation(of: out, colorSpace: space, options: [key: quality])
    }

    /// Variance of the Laplacian of the luma plane (KeyframeQuality), for the server's view weighting.
    static func sharpness(_ pb: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        return KeyframeQuality.laplacianVariance(luma: base.assumingMemoryBound(to: UInt8.self), width: w, height: h,
                                                 bytesPerRow: bpr)
    }

    // MARK: spool + ledgers (main)

    /// Encode + write the chunk with the next seq; only a chunk on disk takes a seq (contiguous by construction).
    private func spool(_ id: String, kind: MeshMapKind, blobs: [(name: String, data: Data)],
                       header: (Int) -> [String: Any]) {
        guard var l = ledgers[id], l.state == .capturing, let url = chunkURL(id, l.nextSeq) else { return }
        let seq = l.nextSeq
        guard let data = MeshMapChunk.encode(header: header(seq), blobs: blobs), data.count <= MeshMapChunk.maxBytes
        else { model.log.event("meshmap_chunk_error", ["kind": .string(kind.rawValue)]); return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            model.log.event("meshmap_write_error", ["error": .string(error.localizedDescription)])
            return
        }
        _ = l.add(kind, bytes: data.count, now: now)
        ledgers[id] = l
        persist(id)
        publish()
        pump()
    }

    private func persist(_ id: String, force: Bool = false) {
        guard let l = ledgers[id], let d = dir(id) else { return }
        let t = now
        guard force || t - (lastPersist[id] ?? 0) >= 2 else { return }
        lastPersist[id] = t
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(l) { try? data.write(to: d.appendingPathComponent("ledger.json"), options: .atomic) }
    }

    /// Launch: every upload left on disk. One still `capturing` was cut off by the app ending: finish it.
    private func loadLedgers() {
        guard let root = Self.root,
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for d in items {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("ledger.json")),
                  var l = try? JSONDecoder().decode(MeshMapLedger.self, from: data) else { continue }
            if l.terminal || now - l.created > 7 * 86400 { try? FileManager.default.removeItem(at: d); continue }
            if l.state == .capturing { l.stopCapture(now: now) }
            ledgers[l.uploadID] = l
            persist(l.uploadID, force: true)
        }
    }

    private func remove(_ id: String) {
        ledgers[id] = nil
        lastPoll[id] = nil
        lastPersist[id] = nil
        if let d = dir(id) { try? FileManager.default.removeItem(at: d) }
    }

    // MARK: upload pump (one request at a time, oldest upload first)

    private enum Work {
        case register(String, Data)
        case chunk(String, Int, URL)
        case finish(String, Int)
        case poll(String)
    }

    private func nextWork() -> Work? {
        guard model.serverBase != nil, now >= backoffUntil else { return nil }
        for l in ledgers.values.sorted(by: { $0.created < $1.created }) where !l.terminal {
            let id = l.uploadID
            if !l.registered {
                let body: [String: Any] = ["agent_id": model.agentID, "agent_type": Identity.agentType, "map_id": l.mapID,
                                           "app_version": model.version, "device": DebugLog.deviceModel, "started": l.created]
                return .register(id, JSON.body(body))
            }
            if l.state == .processing {
                if now - (lastPoll[id] ?? 0) >= Self.pollS { return .poll(id) }
                continue
            }
            if l.ackedThrough < l.nextSeq - 1 {
                let seq = l.ackedThrough + 1
                if let u = chunkURL(id, seq), FileManager.default.fileExists(atPath: u.path) { return .chunk(id, seq, u) }
                // the file is gone (only if the app died between the ack and the ledger save): skip it; a server gap
                // there makes finish answer 409 missing and the upload ends just before it
                model.log.event("meshmap_chunk_lost", ["upload_id": .string(id), "seq": .int(seq)])
                ledgers[id]?.ackedThrough = seq
                return nextWork()
            }
            if l.readyToFinish { return .finish(id, l.lastSeq ?? -1) }
        }
        return nil
    }

    func pump() {
        guard !pumping else { return }
        guard let first = nextWork() else { return }
        pumping = true
        let link = model.link!
        Task { [weak self] in
            var work: Work? = first
            while let w = work {
                guard let self else { return }
                let ok = await self.perform(w, link: link)
                work = await MainActor.run { () -> Work? in
                    if ok { self.backoff = 2 } else {
                        self.backoffUntil = self.now + self.backoff
                        self.backoff = min(self.backoff * 2, 30)
                    }
                    return ok ? self.nextWork() : nil
                }
            }
            await MainActor.run { self?.pumping = false }
        }
    }

    /// One request; false = network / server trouble (back off).
    private func perform(_ w: Work, link: ServerLink) async -> Bool {
        switch w {
        case .register(let id, let body):
            guard let resp = try? await link.request("PUT", "/v1/meshmap/\(id)", body: body, timeout: 15) else { return false }
            let (d, s) = resp
            await MainActor.run {
                if s == 200 {
                    self.ledgers[id]?.registered = true
                    if let hc = JSON.int(JSON.object(d), "have_contiguous") { self.ackFromServer(id, hc) }
                    self.persist(id, force: true)
                } else if (400..<500).contains(s) {
                    self.fail(id, "register HTTP \(s): \(JSON.string(JSON.object(d), "detail") ?? "")", terminal: true)
                }
            }
            return s == 200 || (400..<500).contains(s)
        case .chunk(let id, let seq, let url):
            guard let data = try? Data(contentsOf: url) else { return false }
            guard let resp = try? await link.request("PUT", "/v1/meshmap/\(id)/chunks/\(seq)", body: data,
                                                     contentType: "application/octet-stream", timeout: 30) else { return false }
            let (d, s) = resp
            await MainActor.run {
                switch s {
                case 200:
                    let hc = JSON.int(JSON.object(d), "have_contiguous") ?? seq
                    self.ledgers[id]?.acked(haveContiguous: hc, bytes: data.count, now: self.now)
                    try? FileManager.default.removeItem(at: url)
                    self.persist(id)
                case 404:
                    self.ledgers[id]?.registered = false                   // the server lost it: register again
                case 400, 413:
                    // a chunk the server refuses can never become contiguous: end the upload just before it
                    self.model.log.event("meshmap_chunk_refused", ["seq": .int(seq), "status": .int(s)])
                    if var l = self.ledgers[id] {
                        if l.state == .capturing, id == self.current { self.capturing = false; self.current = nil }
                        l.state = .finishing
                        l.lastSeq = seq - 1
                        self.ledgers[id] = l
                    }
                    self.persist(id, force: true)
                default:
                    if s == 409 {                                           // already processed / processing
                        if id == self.current { self.capturing = false; self.current = nil }
                        self.ledgers[id]?.state = .processing
                    }
                }
                self.publish()
            }
            return s == 200 || s == 404 || s == 400 || s == 413 || s == 409
        case .finish(let id, let last):
            let body = JSON.body(["last_seq": last, "reason": "stop"])
            guard let resp = try? await link.request("POST", "/v1/meshmap/\(id)/finish", body: body, timeout: 20) else { return false }
            let (d, s) = resp
            await MainActor.run {
                let o = JSON.object(d)
                if s == 200 {
                    let st = JSON.string(o, "state") ?? "finished"
                    if st == "empty" { self.ledgers[id]?.state = .empty; self.remove(id) }
                    else { self.ledgers[id]?.state = .processing; self.lastPoll[id] = self.now }
                    self.model.log.event("meshmap_finish", ["upload_id": .string(id), "state": .string(st),
                                                            "last_seq": .int(last)])
                    self.persist(id, force: true)
                } else if s == 409, let det = o["detail"] as? [String: Any], let missing = det["missing"] as? [Int],
                          let first = missing.min() {
                    // resend from the first missing chunk if we still have it, else finish with what the server holds
                    if let u = self.chunkURL(id, first), FileManager.default.fileExists(atPath: u.path) {
                        self.ledgers[id]?.ackedThrough = first - 1
                    } else {
                        self.ledgers[id]?.lastSeq = first - 1
                    }
                    self.persist(id, force: true)
                } else if s == 404 {
                    self.ledgers[id]?.registered = false
                } else {
                    self.fail(id, "finish HTTP \(s)", terminal: (400..<500).contains(s))
                }
                self.publish()
            }
            return s == 200 || s == 409
        case .poll(let id):
            await MainActor.run { self.lastPoll[id] = self.now }
            guard let resp = try? await link.request("GET", "/v1/meshmap/\(id)", timeout: 15) else { return false }
            let (d, s) = resp
            await MainActor.run {
                if s == 404 { self.fail(id, "the server no longer knows this upload", terminal: true); return }
                guard s == 200, let st = try? JSONDecoder().decode(MeshMapStatus.self, from: d) else { return }
                switch st.state {
                case "done", "failed", "empty":
                    let text = MeshMapText.done(st)
                    self.model.log.event("meshmap_result", ["upload_id": .string(id), "state": .string(st.state),
                                                            "version": .int(st.result?.version ?? -1),
                                                            "error": .string(st.error ?? "")])
                    self.model.flash(text, seconds: 6)
                    self.recentText = (st.state == "done" ? "map updated" + (st.result?.version.map { " v\($0)" } ?? "") + " ✓"
                                                           : text, self.now + 12)
                    if st.state == "done", let v = st.result?.version, v > (self.model.liveBaseVersion ?? 0) {
                        self.model.log.event("meshmap_new_version", ["version": .int(v)])
                    }
                    self.remove(id)
                default:
                    break
                }
                self.publish()
            }
            return true
        }
    }

    private func ackFromServer(_ id: String, _ hc: Int) {
        guard var l = ledgers[id] else { return }
        if hc > l.ackedThrough {
            for s in (l.ackedThrough + 1)...hc { if let u = chunkURL(id, s) { try? FileManager.default.removeItem(at: u) } }
            l.acked(haveContiguous: hc, bytes: 0, now: now)
        } else if hc < l.ackedThrough {
            l.ackedThrough = hc                                    // the server has less than we thought: resend
        }
        ledgers[id] = l
    }

    private func fail(_ id: String, _ why: String, terminal: Bool = false) {
        model.log.event("meshmap_error", ["upload_id": .string(id), "error": .string(why)])
        ledgers[id]?.error = why
        if terminal {
            if id == current { capturing = false; current = nil }
            ledgers[id]?.state = .failed
            persist(id, force: true)
        }
        recentText = ("map upload: \(why)", now + 10)
        publish()
    }

    // MARK: HUD

    func publish() {
        var text: String?
        if capturing, let id = current {
            text = MeshMapText.line(capturing: true, paused: pausedReason, ledger: ledgers[id], online: model.serverBase != nil)
        } else if let l = ledgers.values.filter({ !$0.terminal }).sorted(by: { $0.created < $1.created }).first {
            text = MeshMapText.line(capturing: false, paused: nil, ledger: l, online: model.serverBase != nil)
        } else if let r = recentText {
            text = r.text
        }
        if model.meshMapText != text { model.meshMapText = text }
        let live = capturing && pausedReason == nil
        if model.meshMapLive != live { model.meshMapLive = live }
    }
}
