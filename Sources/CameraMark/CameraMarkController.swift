// SnailSight 12.2 "Mark camera" + "Camera check" (owner 2026-10-20: confirm where cameras and other objects really
// are, including ones on the roofline beyond the iPhone LiDAR range, and track field of view while walking).
//
// Mark camera (point-at): pick a camera / sensor placement (map entities, API §5.7a `?include=placements`) or a new
// one → a crosshair. Aim at the physical camera and tap Mark: each mark records a ray (phone camera centre + crosshair
// direction) in the MAP frame with the CURRENT localized T_map_arkit (the lock itself, not the eased display
// alignment) and the lock quality (SnailSightCore.MarkLock). Two or more marks ≥ 10° apart (MarkGuide says "step 2 m
// sideways and mark again") → POST …/entities/{id}/triangulate (§5.7b) → the point + its 1σ ellipse as a sphere
// and a ring in AR → Accept → POST …/triangulate/accept (the entity moves, record.position.source "triangulated").
// Within LiDAR range one mark can use the raycast hit directly. Server down / no endpoint: the phone's own
// least-squares estimate (MarkMath.localTriangulate) and, on accept, a plain entity PUT — latency, not function.
//
// Camera check (walk FOV tracking): a walk-calibration window (§5.7c POST …/cameras/calibration/walk), the localized
// device pose posted in batches (2 Hz, every 5 s), and every 3 s "which cameras see me" (GET …/cameras/coverage at my
// position; the window's recent detections = "saw you"). Without those endpoints: a frustum test from the placements.
// Logs: camera_mark, camera_triangulate, camera_accept, camera_check, camera_view.
import ARKit
import RealityKit
import SwiftUI
import UIKit
import SnailSightCore

/// What is being marked: an existing placement, or a new one created on accept.
struct MarkTarget: Equatable {
    var id: String?                   // nil = new
    var kind: String                  // camera | sensor
    var name: String
    var source: String                // new only: frigate:<cam> | ring:<cam> | ha:<entity_id> | kinect
    var current: [Double]?            // the placement's map position now
    var level: Int?
    /// New only: the id it will be created under (the server triangulates an unknown id before its PUT).
    var newID: String?

    var title: String { name }
    var wireID: String? { id ?? newID }
}

final class CameraMarkController: ObservableObject {
    private unowned let model: AppModel

    @Published var showPicker = false
    @Published private(set) var target: MarkTarget?
    @Published private(set) var rays: [MarkRay] = []
    @Published private(set) var result: TriangulateResult?
    @Published private(set) var busy = false
    @Published private(set) var note: String?
    @Published private(set) var lock: MarkLock = .none

    private let node = Entity()
    private var sphere: ModelEntity?
    private var ring: ModelEntity?
    private var rayEntities: [Entity] = []

    init(model: AppModel) { self.model = model }

    var active: Bool { target != nil }
    private var layer: MapARLayer { model.controller.mapLayer }
    private var now: Double { Date().timeIntervalSince1970 }

    /// The localizer's lock (T_map_arkit), not the eased display alignment.
    private var T: Mat4? { model.mapLocalizer.alignment?.T }

    func currentLock() -> MarkLock {
        guard model.mapLocalizer.alignment != nil, model.tracking.code == "normal" else { return .none }
        return MarkLock.from(source: model.mapLocalizer.lockSource, method: model.mapLocalizer.alignment?.method,
                             errCm: model.mapLocalizer.errorEstimate)
    }

    /// The phone in the map frame (for the guidance).
    var meMap: [Double]? {
        guard let T else { return nil }
        let c = layer.camWorld
        return T.apply([Double(c.x), Double(c.y), Double(c.z)])
    }

    var guide: MarkGuide { MarkGuide.evaluate(rays, me: meMap) }

    // MARK: start / stop

    func start(_ t0: MarkTarget) {
        var t = t0
        if t.id == nil && t.newID == nil { t.newID = MarkWire.newID(name: t.name, t: Date().timeIntervalSince1970) }
        target = t
        rays = []
        result = nil
        note = nil
        attachNode()
        clearDrawing()
        model.sheetDetent = .collapsed
        showPicker = false
        model.log.event("camera_mark_start", ["id": .string(t.id ?? "new"), "kind": .string(t.kind),
                                              "new": .bool(t.id == nil)])
        if T == nil { model.flash("Mark camera: waiting for the house map lock (walk a little)", seconds: 3) }
    }

    func start(placement p: Placement) {
        start(MarkTarget(id: p.id, kind: p.kind, name: p.title, source: p.record?.source ?? "",
                         current: [p.pose.x, p.pose.y, p.pose.z], level: p.record?.level))
    }

    func close() {
        model.log.event("camera_mark_close", ["id": .string(target?.id ?? "new"), "rays": .int(rays.count),
                                              "accepted": .bool(false)])
        finish()
    }

    private func finish() {
        target = nil
        rays = []
        result = nil
        note = nil
        clearDrawing()
    }

    /// Drop the shown result (keep the marks) to add more marks.
    func undoResult() {
        result = nil
        note = nil
        sphere?.removeFromParent()
        ring?.removeFromParent()
        sphere = nil
        ring = nil
        redrawRays()
    }

    func undo() {
        guard !rays.isEmpty else { return }
        rays.removeLast()
        undoResult()
    }

    // MARK: Mark

    /// One mark: the crosshair (screen centre) ray in the map frame + the LiDAR hit when one is within range.
    func mark() {
        guard let tg = target else { return }
        let l = currentLock()
        lock = l
        guard let T, l != .none else {
            note = "No map lock right now: wait for the pill to say locked, then mark"
            model.log.event("camera_mark", ["id": .string(tg.id ?? "new"), "ok": .bool(false), "why": .string("no_lock")])
            return
        }
        let arView = model.controller.arView
        let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let r = arView.ray(through: centre) else { return }
        let o = [Double(r.origin.x), Double(r.origin.y), Double(r.origin.z)]
        let d = [Double(r.direction.x), Double(r.direction.y), Double(r.direction.z)]
        let m = MarkMath.mapRay(T_map_arkit: T, originArkit: o, dirArkit: d)
        var hit: [Double]?
        if let h = arView.raycast(from: centre, allowing: .estimatedPlane, alignment: .any).first {
            let p = Geo.position(h.worldTransform)
            let w = [Double(p.x), Double(p.y), Double(p.z)]
            if MarkMath.norm(MarkMath.sub(w, o)) <= MarkMath.lidarRangeM { hit = T.apply(w) }
        }
        let ray = MarkRay(origin: m.origin, dir: m.dir, t: now, lock: l, hit: hit)
        rays.append(ray)
        result = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let g = guide
        note = nil                                  // the banner shows the live guidance
        UIAccessibility.post(notification: .announcement, argument: "Marked \(rays.count). \(g.text)")
        var ev: [String: LogValue] = ["id": .string(tg.id ?? "new"), "ok": .bool(true), "n": .int(rays.count),
                                      "origin": .doubles(ray.origin), "dir": .doubles(ray.dir), "lock": .string(l.rawValue),
                                      "err_cm": .double(model.mapLocalizer.errorEstimate ?? -1),
                                      "spread_deg": .double(g.spreadDeg), "guide": .string(g.phase.rawValue),
                                      "version": .int(model.mapLocalizer.alignment?.version ?? -1)]
        if let hit { ev["hit"] = .doubles(hit); ev["hit_m"] = .double(MarkMath.norm(MarkMath.sub(hit, ray.origin))) }
        model.log.event("camera_mark", ev)
        redrawRays()
    }

    /// The last mark's LiDAR hit, when within range (single-tap placement).
    var lidarHit: [Double]? { rays.last?.hit }

    func useLidarHit() {
        guard let last = rays.last, let h = last.hit else { return }
        let range = MarkMath.norm(MarkMath.sub(h, last.origin))
        let errM = (model.mapLocalizer.errorEstimate ?? 5) / 100
        let sigma = 0.03 + 0.01 * range + errM
        let r = TriangulateResult(ok: true, point: h, sigmaM: sigma, axes: nil, residualDegP50: nil, maxAngleDeg: nil,
                                  used: 1, why: nil, deltaM: target?.current.map { MarkMath.norm(MarkMath.sub(h, $0)) },
                                  local: true)
        show(r, source: "lidar")
    }

    // MARK: Locate (server triangulation, local fallback)

    func locate() {
        guard let tg = target, rays.count >= 1, !busy else { return }
        let rs = rays
        busy = true
        note = "Locating…"
        let version = model.mapLocalizer.alignment?.version
        // a NEW placement has no entity id on the server yet: the phone's own estimate
        guard let id = tg.wireID, model.serverBase != nil else {
            busy = false
            fallback(rs, why: "offline")
            return
        }
        let link = model.link!, map = layer.mapID, agent = model.agentID
        let body = JSON.body(MarkWire.triangulate(rays: rs, agentID: agent, mapVersion: version))
        Task { [weak self] in
            let r = try? await link.request("POST", "/v1/maps/\(map)/entities/\(Self.enc(id))/triangulate", body: body,
                                            timeout: 20)
            let parsed = (r?.1 == 200) ? r.flatMap { TriangulateResult.parse($0.0) } : nil
            await MainActor.run {
                guard let self, self.target == tg else { return }
                self.busy = false
                if let p = parsed, p.ok, p.point != nil {
                    self.show(p, source: "server")
                } else if let p = parsed {
                    self.note = "Server: \(p.why ?? "could not triangulate")"
                    self.model.log.event("camera_triangulate", ["id": .string(id), "ok": .bool(false), "rays": .int(rs.count),
                                                                "source": .string("server"), "why": .string(p.why ?? "")])
                } else {
                    self.fallback(rs, why: "http_\(r?.1 ?? 0)")
                }
            }
        }
    }

    private func fallback(_ rs: [MarkRay], why: String) {
        if let r = MarkMath.localTriangulate(rs) {
            var r2 = r
            if let c = target?.current, let p = r.point { r2.deltaM = MarkMath.norm(MarkMath.sub(p, c)) }
            show(r2, source: "local:\(why)")
        } else {
            note = rays.count < 2 ? "Mark again from another spot" : MarkGuide.evaluate(rays, me: meMap).text
            model.log.event("camera_triangulate", ["id": .string(target?.id ?? "new"), "ok": .bool(false),
                                                   "rays": .int(rs.count), "source": .string("local"), "why": .string(why)])
        }
    }

    private func show(_ r: TriangulateResult, source: String) {
        result = r
        note = r.summary
        draw(r)
        UIAccessibility.post(notification: .announcement, argument: "Located: \(r.summary). Accept to move it.")
        var ev: [String: LogValue] = ["id": .string(target?.id ?? "new"), "ok": .bool(true), "rays": .int(rays.count),
                                      "used": .int(r.used), "source": .string(source),
                                      "sigma_m": .double(r.sigmaM ?? -1), "spread_deg": .double(r.maxAngleDeg ?? -1),
                                      "resid_deg_p50": .double(r.residualDegP50 ?? -1), "delta_m": .double(r.deltaM ?? -1)]
        if let p = r.point { ev["point"] = .doubles(p) }
        model.log.event("camera_triangulate", ev)
    }

    // MARK: Accept

    func accept() {
        guard let tg = target, let r = result, let p = r.point, !busy else { return }
        busy = true
        note = "Saving…"
        let link = model.link!, map = layer.mapID, agent = model.agentID, n = max(r.used, rays.count)
        let version = model.mapLocalizer.alignment?.version
        let t = now
        Task { [weak self] in
            var status = 0
            var via = ""
            if let id = tg.id {
                // the server's accept (its own result only: a local estimate goes through the plain PUT)
                if !r.local, let body = MarkWire.accept(r, rays: n, agentID: agent, mapVersion: version) {
                    let a = try? await link.request("POST", "/v1/maps/\(map)/entities/\(Self.enc(id))/triangulate/accept",
                                                    body: JSON.body(body), timeout: 20)
                    status = a?.1 ?? 0
                    via = "accept"
                }
                if status != 200 {
                    status = await Self.putMoved(link: link, map: map, id: id, point: p, result: r, rays: n, agent: agent,
                                                 version: version, t: t)
                    via = "put"
                }
            } else {
                let id = tg.newID ?? MarkWire.newID(name: tg.name, t: t)
                let body = MarkWire.newPlacement(kind: tg.kind, name: tg.name, source: tg.source, point: p,
                                                 sigmaM: r.sigmaM ?? 0.1, rays: n, agentID: agent, mapVersion: version,
                                                 level: tg.level, t: t)
                let a = try? await link.request("PUT", "/v1/maps/\(map)/entities/\(Self.enc(id))", body: JSON.body(body),
                                                timeout: 20)
                status = a?.1 ?? 0
                via = "create"
            }
            let st = status, how = via
            await MainActor.run {
                guard let self else { return }
                self.busy = false
                self.model.log.event("camera_accept", ["id": .string(tg.id ?? "new"), "ok": .bool(st == 200), "status": .int(st),
                                                       "via": .string(how), "point": .doubles(p), "sigma_m": .double(r.sigmaM ?? -1),
                                                       "rays": .int(n), "local": .bool(r.local),
                                                       "delta_m": .double(r.deltaM ?? -1)])
                if st == 200 {
                    self.model.flash("\(tg.name) placed (triangulated, \(r.summary))", seconds: 4)
                    self.model.planData.reloadCameras()
                    self.finish()
                } else {
                    self.note = st == 0 ? "Map server offline: try Accept again when it is back"
                                        : "The map server refused it (\(st))"
                }
            }
        }
    }

    /// Fallback: GET the placement, move its pose, mark it triangulated, PUT it back (§5.7a).
    private static func putMoved(link: ServerLink, map: String, id: String, point p: [Double], result r: TriangulateResult,
                                 rays: Int, agent: String, version: Int?, t: Double) async -> Int {
        guard let g = try? await link.request("GET", "/v1/maps/\(map)/entities",
                                              query: [URLQueryItem(name: "include", value: "placements")], timeout: 15),
              g.1 == 200, let o = (try? JSONSerialization.jsonObject(with: g.0)) as? [String: Any],
              var e = (o["entities"] as? [[String: Any]])?.first(where: { ($0["id"] as? String) == id })
        else { return 0 }
        var pose = (e["pose"] as? [String: Any]) ?? [:]
        pose["x"] = p[0]; pose["y"] = p[1]; pose["z"] = p[2]
        e["pose"] = pose
        var rec = (e["record"] as? [String: Any]) ?? [:]
        let s = r.sigmaM ?? 0.1
        rec["estimated"] = false
        rec["est_from"] = String(format: "triangulated (%d rays, σ %.2f m)", rays, s)
        rec["position"] = ["source": "triangulated", "sigma_m": s, "rays_n": rays, "t": t, "agent_id": agent] as [String: Any]
        e["record"] = rec
        e["agent_id"] = agent
        if let version { e["map_version"] = version }
        for k in ["id", "revision", "updated", "created", "deleted"] { e.removeValue(forKey: k) }
        let a = try? await link.request("PUT", "/v1/maps/\(map)/entities/\(enc(id))", body: JSON.body(e), timeout: 20)
        return a?.1 ?? 0
    }

    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }

    // MARK: AR drawing (map frame, under MapARLayer)

    private func attachNode() {
        if node.parent == nil { layer.markNode.addChild(node) }
    }

    private func clearDrawing() {
        for c in Array(node.children) { c.removeFromParent() }
        sphere = nil
        ring = nil
        rayEntities = []
    }

    /// Thin lines along each mark (8 m, or to the result) so the user sees the rays cross.
    private func redrawRays() {
        for e in rayEntities { e.removeFromParent() }
        rayEntities = []
        let mat = UnlitMaterial(color: UIColor.systemYellow.withAlphaComponent(0.85))
        for r in rays {
            let len = result?.point.map { Float(MarkMath.norm(MarkMath.sub($0, r.origin))) + 0.3 } ?? 8
            let e = ModelEntity(mesh: .generateBox(width: 0.008, height: 0.008, depth: len), materials: [mat])
            let o = SIMD3<Float>(Float(r.origin[0]), Float(r.origin[1]), Float(r.origin[2]))
            let d = simd_normalize(SIMD3<Float>(Float(r.dir[0]), Float(r.dir[1]), Float(r.dir[2])))
            e.position = o + d * (len / 2 + 0.25)       // start a little ahead of the phone
            e.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: d)
            node.addChild(e)
            rayEntities.append(e)
        }
    }

    private func draw(_ r: TriangulateResult) {
        guard let p = r.point else { return }
        sphere?.removeFromParent()
        ring?.removeFromParent()
        let pos = SIMD3<Float>(Float(p[0]), Float(p[1]), Float(p[2]))
        let s = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [UnlitMaterial(color: .systemGreen)])
        s.position = pos
        node.addChild(s)
        sphere = s
        let (a, b) = r.ringRadii
        if let mesh = Self.ellipseRing(a: Float(a), b: Float(b)) {
            var m = UnlitMaterial(color: UIColor.systemGreen)
            m.blending = .transparent(opacity: 0.8)
            let e = ModelEntity(mesh: mesh, materials: [m])
            e.position = pos
            node.addChild(e)
            ring = e
        }
        redrawRays()
        tick()
    }

    /// A flat elliptical annulus in the XY plane (faces +Z; billboarded to the camera).
    static func ellipseRing(a: Float, b: Float, segments: Int = 64) -> MeshResource? {
        let w = max(0.008, min(a, b) * 0.12)
        var pos: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        for i in 0..<segments {
            let t = Float(i) / Float(segments) * 2 * .pi
            let c = cos(t), s = sin(t)
            pos.append(SIMD3(c * (a + w / 2), s * (b + w / 2), 0))
            pos.append(SIMD3(c * max(0.001, a - w / 2), s * max(0.001, b - w / 2), 0))
        }
        for i in 0..<segments {
            let o0 = UInt32(2 * i), i0 = o0 + 1, o1 = UInt32(2 * ((i + 1) % segments)), i1 = o1 + 1
            idx += [o0, o1, i0, i0, o1, i1, o0, i0, o1, i0, i1, o1]       // both faces
        }
        var d = MeshDescriptor(name: "mark-ring")
        d.positions = MeshBuffers.Positions(pos)
        d.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [d])
    }

    /// Every HUD tick: the ring faces the camera.
    func tick() {
        guard active, let ring else { return }
        let p = ring.position(relativeTo: nil)
        ring.setOrientation(Geo.billboardRotation(position: p, camera: layer.camWorld), relativeTo: nil)
        lock = currentLock()
    }
}

// MARK: - Camera check (walk FOV tracking)

final class CameraCheck: ObservableObject {
    private unowned let model: AppModel

    struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var score: Double?
        var calibrated: Bool
        var sawMe: Bool
    }

    @Published var on = false { didSet { if on != oldValue { on ? begin() : end() } } }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var line = ""
    @Published private(set) var windowID: String?

    private var buffer = WalkPoseBuffer()
    private var sending = false
    private var lastPoll = 0.0
    private var polling = false
    private var serverCoverage = true          // false after a 404: use the placements' frustums
    private var sawMe = Set<String>()
    private var lastSet = Set<String>()
    private var startedAt = 0.0

    init(model: AppModel) { self.model = model }

    private var now: Double { Date().timeIntervalSince1970 }
    private var map: String { model.controller.mapLayer.mapID }

    private func begin() {
        startedAt = now
        rows = []
        sawMe = []
        lastSet = []
        windowID = nil
        serverCoverage = true
        buffer = WalkPoseBuffer()
        line = "Camera check: starting…"
        model.planData.ensureCameras()
        model.log.event("camera_check", ["on": .bool(true)])
        model.flash("Camera check: walk a zig-zag across each camera's view, near to far (about 2.5 to 13 m and back), "
                    + "about 4 minutes per camera. Ring cameras calibrate poorly from walks: mark them instead", seconds: 7)
        guard model.serverBase != nil else { line = "Camera check: offline, using the cameras' estimated views"; return }
        let link = model.link!, map = self.map
        let body = JSON.body(["agent_id": model.agentID, "duration_s": 1800] as [String: Any])
        Task { [weak self] in
            let r = try? await link.request("POST", "/v1/maps/\(map)/cameras/calibration/walk", body: body, timeout: 15)
            let o = (r?.1 == 200) ? r.flatMap { (try? JSONSerialization.jsonObject(with: $0.0)) as? [String: Any] } : nil
            let wid = (o?["window_id"] as? String) ?? (o?["window_id"] as? NSNumber)?.stringValue
            await MainActor.run {
                guard let self, self.on else { return }
                self.windowID = wid
                self.model.log.event("camera_check", ["window": .string(wid ?? ""), "status": .int(r?.1 ?? 0)])
            }
        }
    }

    private func end() {
        let wid = windowID
        model.log.event("camera_check", ["on": .bool(false), "window": .string(wid ?? ""),
                                         "seconds": .double(now - startedAt), "saw_me": .int(sawMe.count)])
        flush(force: true)
        if let wid, model.serverBase != nil {
            let link = model.link!, map = self.map
            let body = JSON.body(["agent_id": model.agentID])
            Task { _ = try? await link.request("POST", "/v1/maps/\(map)/cameras/calibration/walk/\(wid)/stop", body: body,
                                               timeout: 15) }
        }
        windowID = nil
        rows = []
        line = ""
    }

    /// Every AR frame (cheap): the localized device pose into the 2 Hz buffer.
    func frame(_ f: ARFrame) {
        guard on, let T = model.mapLocalizer.alignment?.T else { return }
        let l = model.cameraMark.currentLock()
        let c = f.camera.transform
        let p = T.apply([Double(c.columns.3.x), Double(c.columns.3.y), Double(c.columns.3.z)])
        let fw = MarkMath.rotate(T, [Double(-c.columns.2.x), Double(-c.columns.2.y), Double(-c.columns.2.z)])
        buffer.offer(t: now, p: p, yaw: atan2(fw[1], fw[0]), lock: l)
    }

    /// Every HUD tick (0.5 s).
    func tick() {
        guard on else { return }
        flush(force: false)
        if now - lastPoll >= 3 && !polling { poll() }
    }

    private func flush(force: Bool) {
        guard let wid = windowID, !sending, model.serverBase != nil, force ? !buffer.snapshot.isEmpty : buffer.due(now: now)
        else { return }
        let keep = buffer.snapshot
        let poses = buffer.take(now: now)
        sending = true
        let link = model.link!, map = self.map
        let body = JSON.body(["agent_id": model.agentID, "poses": poses] as [String: Any])
        Task { [weak self] in
            let r = try? await link.request("POST", "/v1/maps/\(map)/cameras/calibration/walk/\(wid)/poses", body: body,
                                            timeout: 15)
            await MainActor.run {
                guard let self else { return }
                self.sending = false
                if r?.1 != 200 { self.buffer.restore(keep) }
            }
        }
    }

    private func poll() {
        lastPoll = now
        guard let me = model.cameraMark.meMap else { line = "Camera check: waiting for the map lock"; return }
        guard model.serverBase != nil, serverCoverage else { local(me: me); return }
        polling = true
        let link = model.link!, map = self.map, wid = windowID
        let q = ["x", "y", "z"].enumerated().map { URLQueryItem(name: $0.element, value: String(format: "%.2f", me[$0.offset])) }
            + [URLQueryItem(name: "phone", value: "true"), URLQueryItem(name: "occlude", value: "true")]
        Task { [weak self] in
            let c = try? await link.request("GET", "/v1/maps/\(map)/cameras/coverage", query: q, timeout: 10)
            var w: (Data, Int)?
            if let wid { w = try? await link.request("GET", "/v1/maps/\(map)/cameras/calibration/walk/\(wid)", timeout: 10) }
            let cov = (c?.1 == 200) ? c.flatMap { CoverageAnswer.parse($0.0) } : nil
            let ws = (w?.1 == 200) ? w.flatMap { WalkStatus.parse($0.0) } : nil
            await MainActor.run {
                guard let self, self.on else { return }
                self.polling = false
                if c?.1 == 404 { self.serverCoverage = false }
                if let ws { self.sawMe = ws.sawMe(now: Date().timeIntervalSince1970) }
                if let cov {
                    self.update(cov.cameras.filter(\.sees).map {
                        Row(id: $0.id, title: $0.title, score: $0.score, calibrated: $0.calibrated, sawMe: self.sawMe.contains($0.id))
                    }, me: me, source: "server", poses: ws?.poses)
                } else { self.local(me: me) }
            }
        }
    }

    /// Fallback: the placements' frustums (pose, yaw, pitch, FOV, far) — "estimated view".
    private func local(me: [Double]) {
        let rows = model.planData.cameras.filter { $0.kind == "camera" }.compactMap { c -> Row? in
            guard let yaw = c.pose.yaw else { return nil }
            let r = c.record
            let sees = CameraFrustum.sees(camera: [c.pose.x, c.pose.y, c.pose.z], yaw: yaw, pitchDeg: r?.pitch ?? -20,
                                          hfovDeg: r?.hfov ?? 90, vfovDeg: r?.vfov ?? 55, far: r?.far ?? 15, point: me)
            return sees ? Row(id: c.id, title: c.title, score: nil, calibrated: false, sawMe: sawMe.contains(c.id)) : nil
        }
        update(rows, me: me, source: "frustum", poses: nil)
    }

    private func update(_ list: [Row], me: [Double], source: String, poses: Int?) {
        rows = list.sorted { ($0.sawMe ? 1 : 0, $0.score ?? 0) > ($1.sawMe ? 1 : 0, $1.score ?? 0) }
        let saw = list.filter(\.sawMe).count
        line = list.isEmpty ? "Camera check: no camera sees you here"
            : "Camera check: \(list.count) see you" + (saw > 0 ? " · \(saw) detected you" : "")
            + (source == "frustum" ? " (estimated views)" : "")
        let set = Set(list.map(\.id))
        if set != lastSet {
            model.log.event("camera_view", ["in": .string(set.subtracting(lastSet).sorted().joined(separator: ",")),
                                            "out": .string(lastSet.subtracting(set).sorted().joined(separator: ",")),
                                            "seeing": .string(set.sorted().joined(separator: ",")),
                                            "saw_me": .string(sawMe.sorted().joined(separator: ",")),
                                            "me": .doubles(me), "source": .string(source), "poses": .int(poses ?? -1)])
            lastSet = set
        }
    }
}
