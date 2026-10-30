// SnailSight 11.3 "Room scan" (structure layer S4, API §8.11b). Apple RoomPlan runs on the app's OWN ARSession
// (`RoomCaptureSession(arSession:)`, iOS 17+), so every wall / door / window / opening / floor / furniture box it reports
// is in the ARKit world frame the localizer already maps with T_map_arkit. Flow:
//   Sheet ▸ Mapping ▸ "Clean walls (Room scan)" (12.19: no longer a quick action; needs the map lock) → RoomPlan captures while the user walks the room (HUD line counts
//   walls / doors / windows) → "Room scan" again (or leaving the app) stops it → RoomBuilder → CapturedRoom →
//   the normalized room (SnailSightCore/RoomScan.swift) + Apple's CapturedRoom JSON + the USDZ export when ≤ 8 MB +
//   the CURRENT T_map_arkit → spooled to Documents/roomplan/<id>.json BEFORE sending → POST /v1/maps/site/roomplan.
//   Offline / 5xx → kept and resent when the server is back; 4xx → dropped (logged). The server lines the room up with
//   the scanned walls and lets it replace structure elements only where it scores better (monotonic rule).
// No video, no images and no audio are captured or sent: RoomPlan's parametric room only.
import ARKit
import Foundation
import RoomPlan
import SnailSightCore

final class RoomScanner: NSObject, RoomCaptureSessionDelegate {
    private unowned let model: AppModel
    private var session: RoomCaptureSession?
    private var started = 0.0
    private var lastRoom: RoomScanRoom?
    private var lastHUD = 0.0
    private var sending = false
    private var savedDelegate: ARSessionDelegate?
    private var meshBefore = 0
    private(set) var active = false

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    static var supported: Bool { RoomCaptureSession.isSupported }

    static var spool: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("roomplan")
    }

    // MARK: start / stop

    func toggle() { active ? stop(reason: "button") : start() }

    func start() {
        guard !active else { return }
        guard Self.supported else {
            model.flash("Room scan needs a LiDAR iPhone (RoomPlan is not supported here)", seconds: 3)
            return
        }
        guard model.mapLocalizer.alignment != nil else {
            model.flash(RoomScanText.needsLock(), seconds: 3)
            model.log.event("roomscan_refused", ["why": .string("not_locked")])
            return
        }
        if model.meshMapOn { model.meshMapOn = false }                  // one capture at a time
        let ar = model.controller.arView.session
        savedDelegate = ar.delegate
        let s = RoomCaptureSession(arSession: ar)
        s.delegate = self
        session = s
        active = true
        started = Date().timeIntervalSince1970
        lastRoom = nil
        s.run(configuration: RoomCaptureSession.Configuration())
        // RoomPlan may take the session's delegate while it captures; the app's own delegate comes back at the end
        model.log.event("roomscan_delegate", ["taken": .bool((ar.delegate as AnyObject?) !== (savedDelegate as AnyObject?))])
        model.roomScanOn = true
        model.roomScanText = RoomScanText.scanning(nil)
        meshBefore = model.controller.meshAnchorCount
        model.log.event("roomscan_start", ["locked": .bool(model.mapLocalizer.isLocked),
                                           "err_cm": .double(model.mapLocalizer.errorEstimate ?? -1),
                                           "live": .bool(model.liveOn), "mesh_anchors": .int(meshBefore)])
        model.flash("Clean walls: walk slowly around the room, point at every wall, then tap the Room scan line at the top to stop", seconds: 4)
    }

    func stop(reason: String) {
        guard active, let s = session else { return }
        active = false
        model.roomScanOn = false
        model.roomScanText = "Room scan · building the room…"
        s.stop(pauseARSession: false)                                   // the app's AR session keeps running
        model.log.event("roomscan_stop", ["reason": .string(reason), "s": .double(Date().timeIntervalSince1970 - started)])
    }

    func appBackground() { stop(reason: "background") }

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let now = Date().timeIntervalSince1970
        guard now - lastHUD > 0.5 else { return }
        lastHUD = now
        let r = Self.normalized(room)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.lastRoom = r
            self.model.roomScanText = RoomScanText.scanning(r)
        }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        let ar = model.controller.arView.session
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if (ar.delegate as AnyObject?) !== (self.savedDelegate as AnyObject?) { ar.delegate = self.savedDelegate }
            self.model.controller.rerunConfiguration()                 // back to the app's own configuration (no reset)
            // 12.19 evidence for "can RoomPlan run inside Live map?": RoomPlan re-runs the shared session with its own
            // configuration; 12.18 logs showed the LiDAR mesh drop 88 → 11 anchors after a 1.3 s scan.
            let before = self.meshBefore
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.model.log.event("roomscan_mesh_after", ["before": .int(before),
                                                             "after_5s": .int(self.model.controller.meshAnchorCount),
                                                             "live": .bool(self.model.liveOn)])
            }
        }
        if let error {
            DispatchQueue.main.async { [weak self] in self?.finished(nil, error: "\(error.localizedDescription)") }
            return
        }
        Task { [weak self] in
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                await MainActor.run { self?.finished(room, error: nil) }
            } catch {
                await MainActor.run { self?.finished(nil, error: "\(error.localizedDescription)") }
            }
        }
    }

    // MARK: result → spool → upload

    private func finished(_ room: CapturedRoom?, error: String?) {
        session = nil
        guard let room else {
            model.roomScanText = nil
            model.flash("Room scan failed: \(error ?? "no room")", seconds: 3)
            model.log.event("roomscan_failed", ["error": .string(error ?? "nil")])
            return
        }
        let norm = Self.normalized(room)
        let id = RoomScanID.make(date: Date())
        let apple = try? JSONEncoder().encode(room)
        var usdz: Data?
        if let dir = Self.spool {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent("\(id).usdz")
            if (try? room.export(to: u)) != nil { usdz = try? Data(contentsOf: u) }
            try? FileManager.default.removeItem(at: u)
        }
        let body = RoomScanUpload.body(id: id, room: norm, appleJSON: apple, align: model.mapLocalizer.alignment,
                                       errCm: model.mapLocalizer.errorEstimate, agentID: model.agentID,
                                       appVersion: model.version, capturedAt: Date().timeIntervalSince1970, usdz: usdz)
        model.log.event("roomscan_done", ["id": .string(id), "walls": .int(norm.count(.wall)), "doors": .int(norm.count(.door)),
                                          "windows": .int(norm.count(.window)), "openings": .int(norm.count(.opening)),
                                          "objects": .int(norm.objects.count), "apple_kb": .int((apple?.count ?? 0) / 1024),
                                          "usdz_kb": .int((usdz?.count ?? 0) / 1024),
                                          "locked": .bool(model.mapLocalizer.alignment != nil)])
        guard let body, let dir = Self.spool else {
            model.roomScanText = nil
            model.flash("Room scan done (\(norm.summary)) but the map lock was lost: not uploaded", seconds: 4)
            return
        }
        try? body.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        model.roomScanText = "Room scan · \(norm.summary) · sending"
        pump()
    }

    /// Send every spooled room, oldest first (also called when the server comes back and at launch).
    func pump() {
        guard !sending, let dir = Self.spool,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let f = files.first, let body = try? Data(contentsOf: f) else { return }
        sending = true
        let link = model.link
        Task { [weak self] in
            var status: Int?
            var answer: [String: Any] = [:]
            if let link {
                if let r = try? await link.request("POST", "/v1/maps/site/roomplan", body: body, timeout: 90) {
                    status = r.1
                    answer = (try? JSONSerialization.jsonObject(with: r.0) as? [String: Any]) ?? [:]
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.sending = false
                let id = f.deletingPathExtension().lastPathComponent
                let out = RoomScanUpload.outcome(status: status)
                self.model.log.event("roomscan_upload", ["id": .string(id), "status": .int(status ?? 0),
                                                         "outcome": .string("\(out)"),
                                                         "job": .int((answer["job_id"] as? Int) ?? 0)])
                switch out {
                case .sent, .drop:
                    try? FileManager.default.removeItem(at: f)
                    if out == .sent {
                        self.model.roomScanText = nil
                        self.model.flash("Room scan sent: the server is checking it against the map", seconds: 3)
                        self.poll(id: id, tries: 0)
                    } else {
                        self.model.roomScanText = nil
                        self.model.flash("Room scan refused by the server (\(status ?? 0))", seconds: 3)
                    }
                    self.pump()
                case .retry:
                    self.model.roomScanText = "Room scan · waiting for the server"
                    if let link = self.model.link {
                        Task { await link.whenOnline { [weak self] in DispatchQueue.main.async { self?.pump() } } }
                    }
                }
            }
        }
    }

    /// Ask for the job's decision a few times (the job is seconds; publishing the tiles a minute).
    private func poll(id: String, tries: Int) {
        guard tries < 12, let link = model.link else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task {
                guard let r = try? await link.request("GET", "/v1/maps/site/roomplan/\(id)"), r.1 == 200,
                      let o = try? JSONSerialization.jsonObject(with: r.0) as? [String: Any] else {
                    await MainActor.run { self?.poll(id: id, tries: tries + 1) }
                    return
                }
                await MainActor.run {
                    guard let self else { return }
                    if (o["state"] as? String) == "done" {
                        let r = o["result"] as? String
                        self.model.log.event("roomscan_result", ["id": .string(id), "result": .string(r ?? "nil"),
                                                                 "changed": .bool((o["changed"] as? Bool) ?? false),
                                                                 "rev": .int((o["rev"] as? Int) ?? 0)])
                        self.model.flash(RoomScanText.result(r, changed: o["changed"] as? Bool), seconds: 4)
                    } else {
                        self.poll(id: id, tries: tries + 1)
                    }
                }
            }
        }
    }

    // MARK: CapturedRoom → normalized room (ARKit frame, row-major transforms)

    private static func rows(_ m: simd_float4x4) -> [Double] {
        let c = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        var cm: [Double] = []
        for col in c { cm += [Double(col.x), Double(col.y), Double(col.z), Double(col.w)] }
        return RoomScanMath.rowMajor(columnMajor: cm)
    }

    private static func conf(_ c: CapturedRoom.Confidence) -> RoomConfidence {
        switch c {
        case .high: return .high
        case .medium: return .medium
        default: return .low
        }
    }

    private static func surface(_ s: CapturedRoom.Surface) -> RoomSurface? {
        var kind: RoomSurfaceKind
        var open: Bool?
        switch s.category {
        case .wall: kind = .wall
        case .door(let isOpen): kind = .door; open = isOpen
        case .window: kind = .window
        case .opening: kind = .opening
        case .floor: kind = .floor
        @unknown default: return nil
        }
        return RoomSurface(id: s.identifier.uuidString, kind: kind, confidence: conf(s.confidence),
                           dimensions: [Double(s.dimensions.x), Double(s.dimensions.y), Double(s.dimensions.z)],
                           T: rows(s.transform), parent: s.parentIdentifier?.uuidString, open: open,
                           polygon: s.polygonCorners.map { [Double($0.x), Double($0.y), Double($0.z)] })
    }

    static func normalized(_ room: CapturedRoom) -> RoomScanRoom {
        let surfaces = (room.walls + room.doors + room.windows + room.openings + room.floors).compactMap(surface)
        let objects = room.objects.map { o in
            RoomObject(id: o.identifier.uuidString, category: String(describing: o.category), confidence: conf(o.confidence),
                       dimensions: [Double(o.dimensions.x), Double(o.dimensions.y), Double(o.dimensions.z)],
                       T: rows(o.transform))
        }
        return RoomScanRoom(surfaces: surfaces, objects: objects, story: room.story)
    }
}
