// SnailSight 10.1 S2/S3 (plan §7 S2 "shared, server-authoritative sim", S3 "sim agents are mock robots").
// Feature-flagged: runs only when GET /v1 advertises the sim (`sim` / `sim_server` …) or Settings ▸ Sim ▸ Force shared
// sim is on, More ▸ Sim ▸ Shared sim is on, and the Sim is on. Then, once ONLINE and LOCALIZED in the house map, it
// connects WS /v1/maps/{map}/sim, and after 1 s of healthy snapshots takes over from the local S1 sim
// (SimController.remoteAuthority: local bodies hidden + frozen, kept for later). It falls back to the local sim after
// 3 s of silence, offline or unlocalized (SnailSightCore.SimAuthority).
// 10.5: it takes over ONLY when the server world holds every local body (same ids: the server sim is seeded from the
// map entities); missing ones are uploaded first (POST …/sim/import). An empty server world sends it back to local
// (SimHandoff). The status line always names the mode: "Server sim · N bodies" / "Local sim (server: why)".
// - Entities are drawn in the map frame under MapARLayer.simNode, dead-reckoned between snapshots (RemoteTrack).
// - Tap a body to select it; the bar offers Drive (joystick: {v, w, ttl 0.5} at 10 Hz, zero on release), Go to (tap
//   the floor), Go to… (an object label: the server resolves it, S3; if it can't, the phone picks the nearest match
//   from the objects API and sends a spot beside it), Patrol (tap points, Start), Deter deer, Drone assist (tap where
//   the drone should fly ahead: the S3 target demo, POST …/task drone_assist), Stop. Spawn rover / drone at the +.
// Stream shapes as built by the sim lane (sim_api.py): hello {entities: docs}, snapshot {full, entities} (partial
// snapshots leave sleeping objects out: only a full one removes absent bodies), entity {entity: doc}, event {kind}.
// 10.5 (owner on 10.4.212 + "ONE master sim world", API §5.9.10 protocol snailsight-sim/2): bodies are drawn with the
// local sim's bundled USDZ models (ServerSimBody) at the server's scale, playing the server's clip at the server's
// phase (clip_t0 on the estimated server clock) — no local behaviour runs for them; boxes only for unknown kinds.
// Every command goes to the server and the phone draws what the server then publishes: drag = place, flick = kick,
// Go to / Stop / Roam, delete. A delete is authoritative (§5.9.9): the server tombstones the id and this phone drops
// its hidden local copy, so neither the bulk save nor the hand-off import brings it back.
// 10.8 (API §5.9.11, server 0.4.7): the server plans over every storey (stairs from the mesh): the selected body's
// planned route draws as a cyan ribbon; a refused command flashes the server's reason ("no path: …", "target on an
// unmapped level"); the selection line shows the storey + planner status. More ▸ Sim ▸ X-ray: bodies behind walls /
// on another storey draw as a see-through ghost (their own animated model, unlit, no depth test) with a badge.
import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit
import SnailSightCore

struct ServerSimSelection: Equatable {
    var id: String
    var title: String
    var detail: String
    var rover: Bool
    var drone: Bool
    var animal = false
    var role: SimKind.Role = .animal
    // 12.5 drivable bodies (robot, rc_car): the joystick drives them; rc_car sends `drive`, the robot v / w teleop
    var drivable = false
    var driveKind: DriveKind = .diff
    var rcCar = false
    var symbol: String { drone ? "airplane" : rcCar ? "car.side.fill" : rover ? "car.side" : role == .object ? "cube" : "pawprint" }
}

/// The shared sim's HUD state (its own ObservableObject: no AppModel churn at 10 Hz).
final class ServerSimUI: ObservableObject {
    @Published var active = false              // server authoritative right now
    @Published var status = ""                 // "Server sim · 3 bodies" / "Local sim (server: …)"
    @Published var selection: ServerSimSelection?
    @Published var pending: SimCommand?        // goTo / patrol / move: waiting for a floor tap
    @Published var droneAssistPending = false
    @Published var patrolPoints = 0
    @Published var showGoToLabel = false
    /// 12.0 O2: what the obstacle sensor / planner just said about the selected drone or rover.
    @Published var opsBanner: ObstacleBanner?
}

final class ServerSimClient {
    private unowned let model: AppModel
    let ui = ServerSimUI()
    private var authority = SimAuthority()
    private var tracks: [String: RemoteTrack] = [:]
    private var bodies: [String: ServerSimBody] = [:]
    private var statics: [String: SimEntitySnap] = [:]      // entity docs: name, cat, dims, scale
    private var clock = SimServerClock()
    private var drag: (id: String, start: TimeInterval, point: [Double]?)?
    private var dragHot = false
    private var held: [String: [Double]] = [:]              // dropped by a drag: drawn there until the server agrees
    private var lastMessageAt: Double?
    private var teleop = TeleopSender()
    private var driveSender = DriveSender()
    private var stick = V2.zero
    private let shaper = StickShaper()
    private var drivingID: String?                           // the body the stick last drove (zero on reselect)
    private var selectionSink: AnyCancellable?
    private var cmdInFlight = 0
    private var acks = SimAcks()                             // WS commands waiting for the server's ack
    private var follow = FollowPoseTracker()                 // 12.5: bodies following this phone (Follow me)
    private var labelGoals: [String: String] = [:]           // "Go to…" labels waiting for the server's ack
    private var patrol: [[Double]] = []
    private var markers: [Entity] = []
    // socket
    private var task: URLSessionWebSocketTask?
    private var gen = 0
    private var connected = false
    private var connecting = false
    private var reconnectAt: TimeInterval = 0
    private var attempt = 0
    private var lastStatus: TimeInterval = 0
    private var events = 0
    // 10.5 hand-off: local bodies must be on the server before the local ones are hidden
    private var uploading = false
    private var nextUploadAt: TimeInterval = 0
    private var uploadTries = 0
    private var deletedHere: Set<String> = []            // despawned from this phone in server mode: not re-uploaded
    private var lastBlocker: String?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(model: AppModel) {
        self.model = model
        // 12.5: a different selection (or none) clears every overlay of the previous one (SelectionOverlays)
        selectionSink = ui.$selection.map { $0?.id }.removeDuplicates().dropFirst()
            .sink { [weak self] id in
                guard let self else { return }
                self.stopDriving()
                self.model.selectionChanged(id.map { "server.\($0)" })
            }
    }

    /// The overlays the previous selection left (goal markers, route ribbon).
    func clearSelectionOverlays() {
        clearMarkers()
        clearPath()
    }

    /// Selection changed / joystick closed: a body still moving under the stick gets its one zero command.
    func stopDriving() {
        stick = .zero
        guard let id = drivingID, tracks[id] != nil else { drivingID = nil; return }
        drivingID = nil
        if tracks[id]?.snap.driveKind == .ackermann {
            send(.drive(throttle: 0, steer: 0, tank: model.driveTank, ttl: DriveSender.ttl), to: id, quiet: true)
        } else {
            send(.teleop(v: 0, w: 0, ttl: TeleopSender.ttl), to: id, quiet: true)
        }
        teleop = TeleopSender()
        driveSender = DriveSender()
    }

    private var layer: MapARLayer { model.controller.mapLayer }
    private var now: TimeInterval { Date().timeIntervalSince1970 }
    private var mapID: String { layer.mapID }

    var enabled: Bool {
        model.simOn && model.sharedSim && model.serverFeatures.serverSim(forced: model.forceServerSim) && !model.recording
    }
    var isActive: Bool { authority.mode == .server }
    var tagEntities: [Entity] {
        guard isActive else { return [] }
        var out = bodies.values.compactMap(\.badge)                 // X-ray badges face the camera too
        if let id = ui.selection?.id, let b = bodies[id] { out.append(b.tag) }
        return out
    }
    // 10.8 X-ray + path preview (API §5.9.11)
    private var lastXRay: TimeInterval = 0
    private var occluded: [String: Bool] = [:]
    private var pathEntity: ModelEntity?
    private var pathKey: String?
    private var lastPathDraw: TimeInterval = 0
    private var navFlashed: [String: String] = [:]               // body -> the problem status already flashed
    // 12.0 agent ops (O2): launch point per body (Return without mission orders), last sim event per body
    var homes: [String: [Double]] = [:]
    var lastEvents: [String: (kind: String, text: String?, t: Double)] = [:]

    /// The selected rover's position in the map (Robot path starts there).
    var selectedRoverMap: [Double]? {
        guard isActive, let s = ui.selection, s.rover, let t = tracks[s.id] else { return nil }
        let p = t.pose(now: now)
        return [p.x, p.y, p.z]
    }

    // MARK: ticks

    /// 10.6.x: foreground / network back: reconnect now (no leftover backoff, no 30 s slow retry).
    func resume(why: String) {
        guard reconnectAt > now || attempt > 0 else { return }
        reconnectAt = 0
        attempt = 0
        model.log.event("sim_server_resume", ["why": .string(why)])
    }

    /// HUD tick (2 Hz): connection + authority.
    func tick() {
        let t = now
        let want = enabled && model.serverBase != nil
        if want {
            if !connected && !connecting && t >= reconnectAt { connect() }
        } else if connected || connecting {
            close()
        }
        let blocker = handoffBlocker(now: t)
        let changed = authority.update(enabled: enabled, online: model.serverBase != nil, localized: layer.isAligned,
                                       connected: connected, lastMessageAt: lastMessageAt, now: t, blocked: blocker)
        if changed { authorityChanged() }
        if blocker != lastBlocker {
            lastBlocker = blocker
            if let b = blocker, enabled {
                model.log.event("sim_handoff_blocked", ["why": .string(b), "server_bodies": .int(tracks.count),
                                                        "mode": .string(authority.mode.rawValue)])
            }
        }
        layer.simNode.isEnabled = isActive
        for (ref, p) in acks.expired(now: t) {
            model.log.event("sim_cmd", ["cmd": .string(p.cmd), "id": .string(p.id), "ack": .string("timeout"),
                                        "ref": .string(ref), "via": .string("ws")])
        }
        // Follow me: my pose ~2 Hz while anything follows this phone and it is LOCALIZED (12.5: kept through stale
        // snapshots and reselects, FollowPoseTracker)
        if isActive, connected, let tk = task, let cam = layer.cameraMap,
           follow.shouldSend(now: t, alive: Set(tracks.keys), localized: layer.isAligned) {
            let d = SimServerAPI.wsAgentPose(agentID: model.agentID, x: cam[0], y: cam[1], z: cam.count > 2 ? cam[2] : 0)
            tk.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
        }
        if t - lastStatus >= 1 {
            lastStatus = t
            let s: String
            if !enabled { s = "" }
            else if isActive { s = "Server sim · \(tracks.count) bod\(tracks.count == 1 ? "y" : "ies")" }
            else { s = "Local sim (server: \(authority.reason))" }
            if ui.status != s { ui.status = s }
        }
    }

    /// Ids of the local (S1) bodies: robot + animals (their SimEntityRecord ids = the map entity ids).
    private var localIDs: Set<String> {
        Set(model.controller.sim.snapshot().map(\.id)).subtracting(deletedHere).subtracting(MapDeletedIDs.get())
    }

    /// nil = the server may be (stay) in charge. Before the switch it must hold every local body: the missing ones
    /// are uploaded (import), retried every 5 s, at most 5 times (then the phone simply stays on its local sim).
    private func handoffBlocker(now t: TimeInterval) -> String? {
        guard enabled, connected, lastMessageAt != nil else { return nil }
        let local = localIDs
        let server = Set(tracks.keys)
        let b = SimHandoff.blocker(local: local, server: server, serverMode: isActive, uploading: uploading)
        if b != nil, !isActive, !uploading, t >= nextUploadAt, uploadTries < 5, layer.isAligned {
            upload(local.subtracting(server))
        }
        return b
    }

    private func upload(_ ids: Set<String>) {
        guard !ids.isEmpty, let link = model.link, let loc = model.mapLocalizer.localEntities(ids: ids),
              !loc.list.isEmpty, loc.mapID == mapID,
              let body = try? SimServerAPI.importBody(loc.list, agentID: model.agentID) else { return }
        let map = loc.mapID, list = loc.list
        uploading = true
        uploadTries += 1
        nextUploadAt = now + 5
        let path = SimServerAPI.importPath(map: map)
        Task { [weak self] in
            let r = try? await link.request("POST", path, body: body, timeout: 15)
            await MainActor.run {
                guard let self else { return }
                self.uploading = false
                let o = r.map { JSON.object($0.0) } ?? [:]
                self.model.log.event("sim_import", ["entities": .int(list.count), "status": .int(r?.1 ?? 0),
                                                    "spawned": .int((o["spawned"] as? [Any])?.count ?? -1),
                                                    "skipped": .int((o["skipped"] as? [Any])?.count ?? -1),
                                                    "bodies": .int(JSON.int(o, "bodies") ?? -1)])
            }
        }
    }

    /// Every AR frame: dead-reckoned poses + teleop.
    func frame() {
        guard isActive else { return }
        let t = now
        let serverNow = clock.serverNow(local: t)
        for (id, tr) in tracks {
            guard let b = bodies[id] else { continue }
            var p = tr.pose(now: t)
            if let d = drag, d.id == id, let q = d.point { p.x = q[0]; p.y = q[1]; p.z = q[2] }
            else if let q = held[id] {
                if hypot(tr.snap.pose.x - q[0], tr.snap.pose.y - q[1]) < 0.3 { held[id] = nil }
                else { p.x = q[0]; p.y = q[1]; p.z = q[2] }
            }
            b.render(pose: p, snap: tr.snap, serverNow: serverNow, now: t)
        }
        if t - lastXRay >= 0.2 {                                 // 5 Hz: who is hidden, ghosts, badges
            lastXRay = t
            updateXRay(now: t)
        }
        if t - lastPathDraw >= 0.25 {
            lastPathDraw = t
            drawSelectedPath(now: t)
        }
        if let s = ui.selection, s.drivable, !model.driveHidden {
            switch DriveRoute.make(stick: stick, kind: s.driveKind, tank: model.driveTank, robotShaper: shaper) {
            case .teleop(let v, let w):
                if let cmd = teleop.next(v: v, w: w, now: t) {
                    send(.teleop(v: cmd.v, w: cmd.w, ttl: cmd.ttl), to: s.id, quiet: true)
                    noteDriving(s.id, moving: abs(cmd.v) > 0 || abs(cmd.w) > 0)
                }
            case .drive(let d):
                if let cmd = driveSender.next(d, now: t) {
                    send(.drive(throttle: cmd.throttle, steer: cmd.steer, tank: cmd.tank, ttl: DriveSender.ttl), to: s.id,
                         quiet: true)
                    noteDriving(s.id, moving: !cmd.isZero)
                }
            }
        }
    }

    func setStick(_ v: SIMD2<Double>) { stick = v }

    private var driveLoggedAt: TimeInterval = 0
    private func noteDriving(_ id: String, moving: Bool) {
        if moving {
            if drivingID != id { model.log.event("drive_start", ["id": .string(id), "kind": .string(tracks[id]?.snap.kind ?? ""),
                                                                 "tank": .bool(model.driveTank)]) }
            drivingID = id
            follow.drop(id)                                   // driving it by hand ends Follow me
        } else if drivingID == id {
            drivingID = nil
            model.log.event("drive_release", ["id": .string(id)])
        }
    }

    private func authorityChanged() {
        let server = authority.mode == .server
        ui.active = server
        model.controller.sim.remoteAuthority = server
        if !server {
            ui.selection = nil
            ui.pending = nil
            ui.droneAssistPending = false
            follow.dropAll()
            clearMarkers()
            clearPath()
        }
        model.log.event("sim_authority", ["mode": .string(authority.mode.rawValue), "reason": .string(authority.reason),
                                          "bodies": .int(tracks.count)])
        if model.simOn {
            model.flash(server ? "Shared sim on the map server (everyone sees the same bodies)"
                               : "Sim: local on this phone (\(authority.reason))", seconds: 2.5)
        }
    }

    // MARK: socket

    private func connect() {
        guard let b = model.serverBase else { return }
        var ws = b
        if ws.hasPrefix("https://") { ws = "wss://" + String(ws.dropFirst(8)) }
        else if ws.hasPrefix("http://") { ws = "ws://" + String(ws.dropFirst(7)) }
        guard let url = URL(string: ws + SimServerAPI.streamPath(map: mapID)) else { return }
        gen += 1
        let g = gen
        connecting = true
        let tk = session.webSocketTask(with: url)
        tk.maximumMessageSize = 4 << 20
        task = tk
        tk.resume()
        let hello: [String: Any] = ["type": "hello", "agent_id": model.agentID, "agent_type": Identity.agentType,
                                    "app_version": model.version]
        if let d = try? JSONSerialization.data(withJSONObject: hello) {
            tk.send(.string(String(decoding: d, as: UTF8.self))) { [weak self] err in
                guard let err else { return }
                DispatchQueue.main.async { if self?.gen == g { self?.fail("send: \(err.localizedDescription)") } }
            }
        }
        model.log.event("sim_server_connect", ["url": .string(url.absoluteString), "attempt": .int(attempt)])
        receive(g)
    }

    private func receive(_ g: Int) {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, g == self.gen else { return }
                switch result {
                case .success(let m):
                    if self.connecting { self.connecting = false; self.connected = true; self.attempt = 0 }
                    switch m {
                    case .string(let s): self.handle(Data(s.utf8))
                    case .data(let d): self.handle(d)
                    @unknown default: break
                    }
                    self.receive(g)
                case .failure(let e):
                    self.fail("receive: \(e.localizedDescription)")
                }
            }
        }
    }

    private func fail(_ why: String) {
        close()
        let d = LiveBackoff.delay(attempt: attempt)
        attempt += 1
        reconnectAt = now + max(d, attempt > 4 ? 30 : 0)        // an API that is not there yet: retry slowly
        if attempt <= 3 { model.log.event("sim_server_drop", ["why": .string(why), "retry_s": .double(reconnectAt - now)]) }
    }

    private func close() {
        uploadTries = 0
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        connecting = false
    }

    private func handle(_ d: Data) {
        guard let m = SimStreamMessage.parse(d) else { return }
        lastMessageAt = now
        switch m {
        case .snapshot(_, let list, let full):
            for e in list where e.dims != nil || e.cat != nil { statics[e.id] = e }      // hello = full docs
            apply(list, full: full)
        case .entity(let doc):
            statics[doc.id] = doc
            if let b = bodies[doc.id], let tr = tracks[doc.id] {                     // re-draw if it now looks different
                let s = tr.snap.merged(withStatic: doc)
                if visual(s) != b.visual { redraw(s) }
            }
        case .event(let kind, let text, let id):
            events += 1
            if kind == "delete", let id, !id.isEmpty { forgetLocally(id) }       // any client's delete: for good
            if let id, !id.isEmpty {
                lastEvents[id] = (kind, text, now)
                if ui.selection?.id == id, let b = ObstacleBanner.make(nav: tracks[id]?.snap.nav, event: kind, eventDetail: text,
                                                                         now: now) { ui.opsBanner = b }
            }
            model.log.event("sim_server_event", ["kind": .string(kind), "id": .string(id ?? ""), "text": .string(text ?? "")])
            if isActive, let text, !text.isEmpty { model.flash(text, seconds: 2) }
            else if isActive, kind == "arrive" || kind == "arrived" { model.flash("\(title(id ?? "")) arrived", seconds: 1.5) }
            else if isActive, kind == "goal_failed" { model.flash("\(title(id ?? "")) can't get there", seconds: 2) }
        case .lease(let id, let owner, let granted):
            if granted == false, owner != model.agentID, ui.selection?.id == id {
                model.flash("\(title(id)) is driven by \(owner ?? "another device")", seconds: 2)
            }
        case .ack(let ref, let ok, let status, let detail):
            guard let p = acks.resolve(ref) else { break }
            var ev: [String: LogValue] = ["cmd": .string(p.cmd), "id": .string(p.id), "ack": .string(ok ? "ok" : "refused"),
                                          "ms": .int(Int((now - p.sentAt) * 1000)), "via": .string("ws")]
            if let status { ev["status"] = .int(status) }
            if let detail { ev["detail"] = .string(String(detail.prefix(80))) }
            model.log.event("sim_cmd", ev)
            if p.cmd == "goto_label", let l = labelGoals.removeValue(forKey: p.id) {
                if ok { model.flash("\(title(p.id)) → \(l)", seconds: 2) } else { goToLocally(label: l, id: p.id) }
            } else if !ok {
                // 10.8: the server says WHY (no path / unmapped level / no free floor …): show it
                let why = status == 409 ? "Another device is driving it"
                    : detail.map { "\(title(p.id)): \($0)" } ?? "The map server refused \(p.cmd) (\(status ?? 0))"
                model.flash(why, seconds: detail == nil ? 2 : 4)
                if p.cmd == "follow" { follow.drop(p.id); refreshSelection() }
                if p.cmd == "place" { held[p.id] = nil }
            }
        case .error(let s):
            model.log.event("sim_server_error", ["detail": .string(s)])
        case .other:
            break
        }
    }

    private func apply(_ raw: [SimEntitySnap], full: Bool) {
        let t = now
        for r in raw { follow.observe(r.id, behaviour: r.behaviour, now: t) }    // the server's own word, not the doc's
        let list = raw.map { $0.merged(withStatic: statics[$0.id]) }
        if let st = list.lazy.compactMap(\.t).first { clock.observe(serverTime: st, receivedAt: t) }
        let ids = Set(list.map(\.id))
        for id in Array(tracks.keys) where full && !ids.contains(id) { drop(id) }
        for s in list {
            if var tr = tracks[s.id] { tr.update(s, now: t); tracks[s.id] = tr } else { tracks[s.id] = RemoteTrack(s, now: t) }
            if homes[s.id] == nil { homes[s.id] = [s.pose.x, s.pose.y, s.pose.z] }
            if bodies[s.id]?.visual != visual(s) { redraw(s) }
            noteNav(s)
        }
        if let sel = ui.selection, let tr = tracks[sel.id] {
            let d = selection(tr.snap)
            if d != sel { ui.selection = d }
        }
    }

    /// A planner problem (no path, stuck, lost) on a body following me or selected: say it once.
    private func noteNav(_ s: SimEntitySnap) {
        guard let n = s.nav else { navFlashed[s.id] = nil; return }
        guard n.isProblem else { navFlashed[s.id] = nil; return }
        guard isActive, navFlashed[s.id] != n.status, ui.selection?.id == s.id || follow.followers.contains(s.id),
              n.reason != nil else { return }
        navFlashed[s.id] = n.status
        model.flash("\(title(s.id)): \(n.text)", seconds: 4)
        model.log.event("sim_nav", ["id": .string(s.id), "status": .string(n.status), "reason": .string(n.reason ?? "")])
    }

    private func refreshSelection() {
        if let sel = ui.selection, let tr = tracks[sel.id] { ui.selection = selection(tr.snap) }
    }

    private func drop(_ id: String) {
        occluded[id] = nil
        navFlashed[id] = nil
        tracks[id] = nil
        bodies[id]?.remove()
        bodies[id] = nil
        statics[id] = nil
        held[id] = nil
        if ui.selection?.id == id { ui.selection = nil }
    }

    /// A body deleted on the server (by anyone): gone here too, and from the hidden local sim + saved place, and never
    /// uploaded again (MapDeletedIDs; the server tombstones it as well).
    private func forgetLocally(_ id: String) {
        deletedHere.insert(id)
        MapDeletedIDs.add([id])
        model.controller.sim.removeBody(uid: id)
        drop(id)
    }

    private func visual(_ s: SimEntitySnap) -> SimServerVisual {
        let cat = model.controller.sim.catalog
        return SimServerVisual.of(s, animalKeys: Set(cat.items.filter(\.isAnimal).map(\.key)),
                                  objectKeys: Set(cat.items.filter { !$0.isAnimal }.map(\.key)))
    }

    private func redraw(_ s: SimEntitySnap) {
        bodies[s.id]?.remove()
        let v = visual(s)
        let b = ServerSimBody(id: s.id, visual: v, snap: s, library: model.controller.sim.library,
                              catalog: model.controller.sim.catalog, label: layer.makeLabel(title(s.id), size: 0.03),
                              log: { [weak self] e, d in self?.model.log.event(e, d) })
        let drawn: String
        switch v {
        case .animal: drawn = "model"
        case .object: drawn = "model"
        case .robot: drawn = "robot_model"
        case .rcCar: drawn = "rc_car_model"
        case .drone: drawn = "drone"
        case .box: drawn = "box"
        }
        model.log.event("sim_server_body", ["id": .string(s.id), "kind": .string(s.kind), "drawn": .string(drawn),
                                            "scale": .double(s.scale ?? 0)])
        layer.simNode.addChild(b.root)
        bodies[s.id] = b
        if let tr = tracks[s.id] {
            b.render(pose: tr.pose(now: now), snap: tr.snap, serverNow: clock.serverNow(local: now), now: now)
        }
    }

    private func title(_ id: String) -> String {
        guard let s = tracks[id]?.snap else { return id }
        return s.name ?? (s.isDrone ? "Sim drone" : s.isRover ? "Sim rover" : s.kind.capitalized)
    }

    private func selection(_ s: SimEntitySnap) -> ServerSimSelection {
        var d = s.action ?? s.state ?? "idle"
        if let b = s.behaviour, b != d, !["teleop", "idle"].contains(b) { d += " · \(b)" }
        if let o = s.owner, o != model.agentID, !o.isEmpty { d += " · \(o)" }
        if s.isDrone { d += String(format: " · %.1f m up", s.pose.z - ((layer.cameraMap?[2] ?? 1.4) - 1.4)) }
        if let lv = s.level { d += " · L\(lv)" }
        if let n = s.nav, !(n.status == "walking" && n.targetLevel == s.level) { d += " · \(n.text)" }
        if follow.followers.contains(s.id) && s.behaviour == "follow" && s.nav?.isProblem != true { d += " · following you" }
        return ServerSimSelection(id: s.id, title: title(s.id), detail: d, rover: s.isRover, drone: s.isDrone,
                                  animal: s.role == .animal, role: s.role, drivable: s.isDrivable, driveKind: s.driveKind,
                                  rcCar: s.isRCCar)
    }

    // MARK: X-ray + path preview (10.8, API §5.9.11)

    /// Every 0.2 s: which bodies are hidden (house mesh ray, or the live LiDAR mesh near by, or another storey) ->
    /// ghost + badge while X-ray is on; everything normal when it is off.
    private func updateXRay(now t: TimeInterval) {
        let on = model.simXRay
        guard let cam = layer.cameraMap else { return }
        if on { layer.ensureOccluder() }
        let ly = layer
        for (id, b) in bodies {
            guard let tr = tracks[id] else { continue }
            let p = tr.pose(now: t)
            let s = tr.snap
            var hidden = false
            if on {
                let mid = [p.x, p.y, p.z + max(0.05, b.height * 0.5)]
                let dist = hypot(hypot(mid[0] - cam[0], mid[1] - cam[1]), mid[2] - cam[2])
                if let blocked = layer.blocked(from: cam, to: mid) {
                    hidden = blocked
                } else if dist < 12, let w = layer.toWorld(map: mid) {
                    let arView = model.controller.arView
                    let o = layer.camWorld, dir = w - o, len = simd_length(dir)    // fallback: the live LiDAR mesh
                    hidden = len > 0.5 && !arView.scene.raycast(origin: o, direction: simd_normalize(dir),
                                                                 length: len - 0.3, query: .any,
                                                                 mask: .sceneUnderstanding, relativeTo: nil).isEmpty
                }
                occluded[id] = hidden
                let ghost = SimXRay.ghost(enabled: true, occluded: hidden, bodyZ: p.z, cameraZ: cam[2])
                b.setGhost(ghost)
                b.setBadge(SimXRay.badge(enabled: true, occluded: hidden, bodyZ: p.z, bodyLevel: s.level,
                                         cameraZ: cam[2], distance: dist)) { text in
                    ly.makeLabel(text, size: 0.035)
                }
            } else {
                b.setGhost(false)
                b.setBadge(nil) { _ in Entity() }
            }
        }
        if !on { occluded.removeAll() }
    }

    /// The selected body's planned route (server `path`, trimmed to what is ahead): a cyan ribbon on the floor and up
    /// the stairs; drawn on top of walls while X-ray is on.
    private func drawSelectedPath(now t: TimeInterval) {
        guard isActive, let s = ui.selection, let tr = tracks[s.id], let path = tr.snap.path, path.count >= 2 else {
            clearPath()
            return
        }
        let p = tr.pose(now: t)
        guard let ahead = SimPathPreview.remaining(path, from: [p.x, p.y, p.z]) else { clearPath(); return }
        // rebuild only when it changed by a few cm (quantised key) or the X-ray mode flipped
        let key = "\(s.id)|\(model.simXRay)|" + ahead.map { String(format: "%.1f,%.1f,%.1f", $0[0], $0[1], $0[2]) }
            .joined(separator: ";")
        guard key != pathKey else { return }
        pathKey = key
        let m = SimPathPreview.ribbon(ahead, width: 0.05, lift: 0.03)
        guard !m.indices.isEmpty else { clearPath(); return }
        var pos = [SIMD3<Float>]()
        pos.reserveCapacity(m.positions.count / 3)
        var i = 0
        while i + 2 < m.positions.count {
            pos.append(SIMD3<Float>(m.positions[i], m.positions[i + 1], m.positions[i + 2]))
            i += 3
        }
        var d = MeshDescriptor(name: "simpath")
        d.positions = MeshBuffers.Positions(pos)
        d.primitives = .triangles(m.indices)
        guard let res = try? MeshResource.generate(from: [d]) else { return }
        var mat = UnlitMaterial(color: UIColor(red: 0.3, green: 0.95, blue: 1, alpha: 1))
        mat.blending = .transparent(opacity: 0.8)
        if model.simXRay {
            mat.readsDepth = false
            mat.writesDepth = false
        }
        if let e = pathEntity {
            e.model = ModelComponent(mesh: res, materials: [mat])
        } else {
            let e = ModelEntity(mesh: res, materials: [mat])
            e.name = "serversim.path"
            layer.simNode.addChild(e)
            pathEntity = e
        }
        model.overlayDrawn(.pathPreview)
    }

    private func clearPath() {
        pathEntity?.removeFromParent()
        pathEntity = nil
        pathKey = nil
    }

    // MARK: picking (map frame, z up, heading +x)

    private var pickBoxes: [ARBoxItem] {
        tracks.values.map { tr in
            let p = tr.pose(now: now), s = tr.snap
            let k = s.scale ?? 1                                 // 12.5: fallbacks at the body's sim scale
            let car = [RCCar.sizeM[0] * k, RCCar.sizeM[2] * k, RCCar.sizeM[1] * k]
            let size: [Double] = (s.dims?.count == 3 ? s.dims : nil)
                ?? (s.isDrone ? [0.5, 0.5, 0.2] : s.isRCCar ? car : s.isRover ? [0.82 * k, 0.62 * k, 0.6 * k] : [1.0, 0.4, 1.2])
            return ARBoxItem(id: s.id, label: s.kind, center: [p.x, p.y, p.z + size[2] / 2], size: size, yaw: p.theta,
                             movable: true, confidence: 1)
        }
    }

    // MARK: taps + commands

    /// true = consumed (in server mode every tap is ours: the local bodies are hidden). 12.5 `passThrough` (Select /
    /// Inspect): a tap that hits no body and clears no selection is left to the caller (a measure point).
    func handleTap(_ pt: CGPoint, arView: ARView, passThrough: Bool = false) -> Bool {
        guard isActive else { return false }
        if ui.droneAssistPending {
            guard let g = floorPoint(pt, arView: arView) else { model.flash("Aim at the floor"); return true }
            if let s = ui.selection {
                postTask(SimServerAPI.taskBody(task: "drone_assist", goal: g, agentID: model.agentID), on: s.id,
                     what: "drone assist")
                addMarker(g)
            }
            ui.droneAssistPending = false
            return true
        }
        if let p = ui.pending {
            guard let g = floorPoint(pt, arView: arView) else { model.flash("Aim at the floor"); return true }
            guard let s = ui.selection else { ui.pending = nil; return true }
            switch p {
            case .patrol:
                patrol.append([g[0], g[1]])
                addMarker(g)
                ui.patrolPoints = patrol.count
                return true
            case .move:
                held[s.id] = g
                send(.place(x: g[0], y: g[1], z: g[2]), to: s.id)
            default:                                            // Go to
                follow.drop(s.id)
                send(.goal(x: g[0], y: g[1], z: g[2]), to: s.id)
                addMarker(g)
            }
            ui.pending = nil
            return true
        }
        let hit = pickBody(pt)
        if let id = hit, let tr = tracks[id] {
            let again = ui.selection?.id == id
            ui.selection = again ? nil : selection(tr.snap)
            stick = .zero
            model.log.event("sim_select", ["id": .string(id), "kind": .string(tr.snap.kind), "mode": .string("server"),
                                           "cleared": .bool(again)])
        } else {
            let had = ui.selection != nil
            model.log.event("sim_tap", ["hit": .bool(false), "mode": .string("server"), "bodies": .int(tracks.count),
                                        "selected": .bool(had)])
            ui.selection = nil
            if passThrough && !had { return false }
        }
        return true
    }

    private func pickBody(_ pt: CGPoint) -> String? {
        guard let r = layer.mapRay(pt) else { return nil }
        return ARMapContent.pick(origin: r.origin, direction: r.direction, boxes: pickBoxes)?.id
    }

    // MARK: drag = move, flick = kick (the local sim's gestures, sent to the server)

    func panShouldBegin(start: CGPoint, now pt: CGPoint, arView: ARView) -> Bool {
        guard isActive, ui.pending == nil else { return false }
        return pickBody(start) != nil || pickBody(pt) != nil
    }

    func handlePan(_ g: UIPanGestureRecognizer, arView: ARView) {
        let pt = g.location(in: arView)
        switch g.state {
        case .began:
            let tr0 = g.translation(in: arView)
            let start = CGPoint(x: pt.x - tr0.x, y: pt.y - tr0.y)
            guard let id = pickBody(start) ?? pickBody(pt), let tr = tracks[id] else { drag = nil; return }
            drag = (id, now, nil)
            dragHot = false
            model.simDragging = true
            if ui.selection?.id != id {
                ui.selection = selection(tr.snap)
                model.log.event("sim_select", ["id": .string(id), "kind": .string(tr.snap.kind), "mode": .string("server"),
                                               "via": .string("drag")])
            }
        case .changed:
            dragHot = SimTrash.hit(x: Double(pt.x), y: Double(pt.y), viewWidth: Double(arView.bounds.width),
                                   viewHeight: Double(arView.bounds.height))
            if model.simDragHot != dragHot { model.simDragHot = dragHot }
            guard var d = drag, let p = floorPoint(pt, arView: arView) else { return }
            d.point = p
            drag = d
        case .ended, .cancelled, .failed:
            model.simDragging = false
            model.simDragHot = false
            guard let d = drag else { return }
            drag = nil
            if g.state == .ended && dragHot {                   // dropped on the trash can: delete for everyone
                dragHot = false
                despawn(d.id, via: "trash")
                return
            }
            guard g.state == .ended, let tr = tracks[d.id] else { return }
            let tr2 = g.translation(in: arView), v = g.velocity(in: arView)
            let short = (tr2.x * tr2.x + tr2.y * tr2.y).squareRoot() < 160
            let fast = (v.x * v.x + v.y * v.y).squareRoot() > 600
            if short && fast && now - d.start < 0.4 && (tr.snap.cat == "animal" || ui.selection?.animal == true) {
                // a flick on an animal: it bolts away from where the phone is
                let p = tr.pose(now: now)
                let from = layer.cameraMap ?? [p.x - cos(p.theta), p.y - sin(p.theta), p.z]
                send(.kick(fromX: from[0], fromY: from[1]), to: d.id)
                model.log.event("sim_server_kick", ["id": .string(d.id)])
            } else if let q = d.point {
                held[d.id] = q
                send(.place(x: q[0], y: q[1], z: q[2]), to: d.id)
                model.log.event("sim_server_move", ["id": .string(d.id), "to": .doubles(q)])
            }
        default: break
        }
    }

    private func floorPoint(_ pt: CGPoint, arView: ARView) -> [Double]? {
        guard let hit = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .horizontal).first else { return nil }
        return layer.toMap(world: Geo.position(hit.worldTransform))
    }

    /// The ONE bar's commands (SimBarView), all sent to the server (WS + ack).
    func command(_ c: SimCommand) {
        guard let s = ui.selection else { return }
        if c == .drive { model.openDrive(); return }
        if c.needsPoint { startPending(c); return }
        if c == .delete { despawnSelected(); return }
        guard let sc = c.serverCommand(agentID: model.agentID, phone: layer.cameraMap) else {
            model.flash("\(c.label): not available here", seconds: 1.5)
            return
        }
        if c == .follow { follow.follow(s.id, now: now) } else { follow.drop(s.id) }
        send(sc, to: s.id)
        if c == .follow { model.flash("\(s.title) follows you", seconds: 1.5) }
    }

    func startPending(_ p: SimCommand) {
        clearMarkers()
        patrol = []
        ui.patrolPoints = 0
        ui.droneAssistPending = false
        ui.pending = p
    }

    func startPatrol() {
        guard let s = ui.selection, patrol.count >= 2 else { return }
        send(.patrol(patrol), to: s.id)
        ui.pending = nil
    }

    func cancelPending() {
        ui.pending = nil
        ui.droneAssistPending = false
        patrol = []
        ui.patrolPoints = 0
        clearMarkers()
    }

    /// "Go to the lamp": the server resolves the label (S3); if it refuses, the phone picks the nearest match from the
    /// AR layer's objects of this map version and sends a spot beside it.
    func goTo(label: String) {
        guard let s = ui.selection else { return }
        labelGoals[s.id] = label
        send(.goToLabel(label), to: s.id)                    // ack ok: flash; refused: the phone's own pick (below)
    }

    private func goToLocally(label: String, id: String) {
        guard let s = ui.selection, s.id == id, let tr = tracks[s.id] else { return }
        let p = tr.pose(now: now)
        guard let objs = layer.objectsDoc?.objects, let o = SemanticGoal.pick(objs, query: label, from: [p.x, p.y]) else {
            model.flash("No \"\(label)\" in the house map objects")
            return
        }
        let g = SemanticGoal.standoff(o, from: [p.x, p.y])
        send(.goTo(label: o.label, objectID: o.id, x: g[0], y: g[1]), to: s.id)
        addMarker([g[0], g[1], o.centroid[2]])
        model.flash("\(s.title) → \(o.displayName)", seconds: 2)
    }

    /// S3 rover tasks (deter deer; drone assist goes through the floor-tap pending action).
    func deterDeer() {
        guard let s = ui.selection, s.rover else { return }
        postTask(SimServerAPI.taskBody(task: "deter", kinds: ["deer"], agentID: model.agentID), on: s.id, what: "deter deer")
    }

    func startDroneAssist() {
        guard let s = ui.selection, s.rover else {
            model.flash("Select a sim rover first, then Drone assist", seconds: 2.5)
            return
        }
        clearMarkers()
        ui.pending = nil
        ui.droneAssistPending = true
    }

    private func postTask(_ body: Data, on id: String, what: String) {
        post(SimServerAPI.taskPath(map: mapID, id: id), body: body, what: what)
    }

    /// 10.6: commands go over the sim WebSocket (the server acks the ref: sim_cmd {cmd, id, ack}); REST only when the
    /// socket is down or the caller needs the result (`done`).
    private func send(_ c: SimServerAPI.Command, to id: String, quiet: Bool = false, done: ((Bool) -> Void)? = nil) {
        if done == nil, connected, let tk = task {
            let ref: String? = quiet ? nil : acks.register(cmd: c.name, id: id, now: now)
            let d = SimServerAPI.wsCommand(c, id: id, agentID: model.agentID, ref: ref)
            tk.send(.string(String(decoding: d, as: UTF8.self))) { [weak self] err in
                guard let err else { return }
                DispatchQueue.main.async {
                    self?.model.log.event("sim_cmd", ["cmd": .string(c.name), "id": .string(id), "ack": .string("send_failed"),
                                                      "detail": .string(err.localizedDescription), "via": .string("ws")])
                }
            }
            return
        }
        guard cmdInFlight < 3 else { done?(false); return }
        cmdInFlight += 1
        let link = model.link!, path = SimServerAPI.cmdPath(map: mapID, id: id)
        let body = SimServerAPI.body(c, agentID: model.agentID)
        Task { [weak self] in
            let r = try? await link.request("POST", path, body: body, timeout: 5)
            await MainActor.run {
                guard let self else { return }
                self.cmdInFlight -= 1
                let st = r?.1 ?? 0
                if !quiet || !(200..<300).contains(st) {
                    self.model.log.event("sim_cmd", ["id": .string(id), "cmd": .string(c.name), "via": .string("rest"),
                                                     "ack": .string((200..<300).contains(st) ? "ok" : "refused"),
                                                     "status": .int(st)])
                }
                if st == 409 { self.model.flash("Another device is driving it", seconds: 2) }
                else if !quiet && !(200..<300).contains(st) { self.model.flash("The map server refused (\(st))", seconds: 2) }
                done?((200..<300).contains(st))
            }
        }
    }

    /// Spawn at the reticle (screen centre) or at a tapped floor point (Spawn mode). Animals / objects / the robot at
    /// the phone's Sim scale; sent over the WS (ack logged), REST when the socket is down.
    func spawn(_ kind: String, arView: ARView, at pt: CGPoint? = nil) {
        let c = pt ?? CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let g = floorPoint(c, arView: arView), let cam = layer.cameraMap else { model.flash("Aim at the floor"); return }
        let z = kind == "sim-drone" ? g[2] + 1.0 : g[2]
        let theta = atan2(cam[1] - g[1], cam[0] - g[0])          // face the phone
        let agent = kind == "sim-rover" || kind == "sim-drone"
        let scale: Double? = agent ? nil : SimScale.clampGlobal(model.simScale)
        model.log.event("sim_spawn_request", ["kind": .string(kind), "mode": .string("server"), "at": .doubles(g)])
        if connected, let tk = task {
            let ref = acks.register(cmd: "spawn \(kind)", id: kind, now: now)
            let d = SimServerAPI.wsSpawn(kind: kind, x: g[0], y: g[1], z: z, theta: theta, scale: scale,
                                         agentID: model.agentID, ref: ref)
            tk.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
            return
        }
        let body = SimServerAPI.spawnBody(kind: kind, x: g[0], y: g[1], z: z, theta: theta, agentID: model.agentID)
        post(SimServerAPI.entitiesPath(map: mapID), body: body, what: "spawn \(kind)")
    }


    func despawnSelected() {
        guard let s = ui.selection else { return }
        despawn(s.id, via: "bar")
    }

    /// Delete for everyone (authoritative + tombstoned on the server); gone here at once.
    func despawn(_ id: String, via: String) {
        model.log.event("sim_delete_request", ["id": .string(id), "via": .string(via), "mode": .string("server")])
        follow.drop(id)
        if ui.selection?.id == id { ui.selection = nil }
        forgetLocally(id)
        if connected, let tk = task {
            let ref = acks.register(cmd: "delete", id: id, now: now)
            let d = SimServerAPI.wsDelete(id: id, agentID: model.agentID, ref: ref)
            tk.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
            return
        }
        let s = (id: id, kind: "")
        let link = model.link!
        let path = SimServerAPI.entityPath(map: mapID, id: s.id)
        let q = [URLQueryItem(name: "agent_id", value: model.agentID)]
        Task { [weak self] in
            let r = try? await link.request("DELETE", path, query: q, timeout: 10)
            await MainActor.run {
                guard let self else { return }
                let st = r?.1 ?? 0
                self.model.log.event("sim_server_despawn", ["id": .string(s.id), "status": .int(st)])
                if !(200..<300).contains(st) { self.model.flash("Remove: the map server said \(st) (will not come back here)", seconds: 2.5) }
            }
        }
    }

    private func post(_ path: String, body: Data, what: String) {
        let link = model.link!
        Task { [weak self] in
            let r = try? await link.request("POST", path, body: body, timeout: 10)
            await MainActor.run {
                guard let self else { return }
                let st = r?.1 ?? 0
                self.model.log.event("sim_server_post", ["what": .string(what), "status": .int(st)])
                self.model.flash((200..<300).contains(st) ? "\(what.capitalized) ✓" : "\(what.capitalized): the map server said \(st)",
                                 seconds: 2)
            }
        }
    }

    private func addMarker(_ p: [Double]) {
        var m = UnlitMaterial(color: UIColor(red: 0.3, green: 0.95, blue: 1, alpha: 1))
        m.blending = .transparent(opacity: 0.7)
        let e = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.2, 0.2, 0.01), cornerRadius: 0.1), materials: [m])
        e.position = SIMD3<Float>(Float(p[0]), Float(p[1]), Float(p.count > 2 ? p[2] : 0) + 0.02)
        layer.simNode.addChild(e)
        markers.append(e)
        model.overlayDrawn(.goalMarkers)
    }

    private func clearMarkers() {
        for e in markers { e.removeFromParent() }
        markers = []
    }
}

/// The shared sim's adapter of the ONE bar (SimBarView): same commands as the local bar (SimCommand.offered), the
/// rover's S3 extras, and the Go to… object sheet.
struct ServerSimBar: View {
    @ObservedObject var ui: ServerSimUI
    let sim: ServerSimClient
    @State private var label = ""

    var body: some View {
        SimBarView(prompt: prompt, pending: ui.pending, patrolPoints: ui.patrolPoints,
                   selection: ui.selection.map { s in
                       SimBarModel(title: s.title, detail: s.detail, symbol: s.symbol,
                                   commands: SimCommand.offered(role: s.role, drone: s.drone, server: true, drivable: s.drivable),
                                   extras: extras(s))
                   },
                   hint: [ui.status.isEmpty ? "Server sim" : ui.status, "tap a body"].joined(separator: " · "),
                   scaleRef: nil) { a in
            switch a {
            case .command(let c): sim.command(c)
            case .cancel: sim.cancelPending()
            case .start: sim.startPatrol()
            case .extra(let x):
                switch x {
                case "goto_label": label = ""; ui.showGoToLabel = true
                case "deter": sim.deterDeer()
                case "drone_assist": sim.startDroneAssist()
                default: break
                }
            case .scale: break
            }
        }
        .sheet(isPresented: $ui.showGoToLabel) { goToSheet.presentationDetents([.height(200)]) }
    }

    private var prompt: String? {
        if ui.droneAssistPending { return "Tap where the drone should fly ahead" }
        switch ui.pending {
        case .goTo?: return "Tap the floor where it should go"
        case .move?: return "Tap the floor where it should stand (or drag it)"
        case .patrol?: return "Tap patrol points (\(ui.patrolPoints)), then Start"
        default: return nil
        }
    }

    private func extras(_ s: ServerSimSelection) -> [SimBarExtra] {
        guard s.rover || s.drone else { return [] }
        var x = [SimBarExtra(id: "goto_label", symbol: "magnifyingglass", label: "Go to…")]
        if s.rover && !s.drone && !s.rcCar {
            x.append(SimBarExtra(id: "deter", symbol: "hare", label: "Deter deer"))
            x.append(SimBarExtra(id: "drone_assist", symbol: "airplane.departure", label: "Drone assist"))
        }
        return x
    }

    private var goToSheet: some View {
        NavigationStack {
            Form {
                TextField("Object, e.g. lamp, sofa, door", text: $label)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { go() }
            }
            .navigationTitle("Go to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { ui.showGoToLabel = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { go() }.disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func go() {
        let l = label.trimmingCharacters(in: .whitespaces)
        ui.showGoToLabel = false
        guard !l.isEmpty else { return }
        sim.goTo(label: l)
    }
}

// MARK: - 12.0 UI shell: the near-you list, the Map, the command ring and agent ops read / drive the shared sim here

/// A shared-sim body as the sheet / Map show it (map frame).
struct ServerSimBodyInfo: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var role: SimKind.Role
    var rover: Bool
    var drone: Bool
    var pose: [Double]                  // x, y, z
    var yaw: Double
    var level: Int?
    var path: [[Double]]?
    var nav: SimNav?
    var selected: Bool
}

extension ServerSimClient {
    /// Every body of the shared sim (only while it is in charge), poses extrapolated to now.
    func bodyInfos() -> [ServerSimBodyInfo] {
        guard isActive else { return [] }
        let t = now
        return tracks.values.map { tr in
            let s = tr.snap
            let p = tr.pose(now: t)
            let sub = [s.action ?? s.behaviour ?? s.state ?? "idle", s.level.map { "L\($0)" }].compactMap { $0 }
                .joined(separator: " · ")
            return ServerSimBodyInfo(id: s.id, title: title(s.id), subtitle: sub, role: s.role, rover: s.isRover,
                                     drone: s.isDrone, pose: [p.x, p.y, p.z], yaw: p.theta, level: s.level,
                                     path: Self.route(s), nav: s.nav, selected: ui.selection?.id == s.id)
        }.sorted { $0.id < $1.id }
    }

    /// 12.5: the selected body's sim scale + kind + scaled dims (robot path tool footprint, sim nav query).
    var selectedBody: (scale: Double?, kind: String, dims: [Double]?)? {
        guard isActive, let id = ui.selection?.id, let s = tracks[id]?.snap else { return nil }
        return (s.scale, s.kind, s.dims)
    }

    /// The selected body's pose in the map frame.
    var selectedPose: [Double]? {
        guard isActive, let id = ui.selection?.id, let tr = tracks[id] else { return nil }
        let p = tr.pose(now: now)
        return [p.x, p.y, p.z]
    }

    /// The selected body's planned route ([[x, y, z(, level)]…]) and launch point.
    var selectedRoute: [[Double]]? {
        guard let sel = ui.selection, let tr = tracks[sel.id] else { return nil }
        return Self.route(tr.snap)
    }
    var selectedHome: [Double]? { ui.selection.flatMap { tracks[$0.id]?.snap.mission?.home ?? homes[$0.id] } }
    /// The selected drone's mission line ("cruise · over estimated · under canopy · 6.0 m AGL"), nil = no mission.
    var selectedMission: SimMission? { ui.selection.flatMap { tracks[$0.id]?.snap.mission } }

    /// A drone mission's path wins over the planner path.
    static func route(_ s: SimEntitySnap) -> [[Double]]? {
        if let m = s.mission, m.path.count >= 2 { return m.path }
        return s.path
    }
    var selectedNav: SimNav? { ui.selection.flatMap { tracks[$0.id]?.snap.nav } }

    /// O2 banner for the selected body: its latest sim event (≤ 8 s old), else a planner problem.
    func opsBanner(now t: Double) -> ObstacleBanner? {
        guard let id = ui.selection?.id else { return nil }
        if let e = lastEvents[id], t - e.t < 8,
           let b = ObstacleBanner.make(nav: tracks[id]?.snap.nav, event: e.kind, eventDetail: e.text, now: e.t) { return b }
        return ObstacleBanner.make(nav: tracks[id]?.snap.nav, event: nil, now: t)
    }

    /// Select a body by id (sheet row / Map tap); nil clears.
    func select(id: String?) {
        guard let id, let tr = tracks[id] else { ui.selection = nil; return }
        ui.selection = selection(tr.snap)
        model.log.event("sim_select", ["id": .string(id), "kind": .string(tr.snap.kind), "mode": .string("server"),
                                       "via": .string("ui12")])
    }

    /// Map tap: the selected body goes to this map point (Go to), or is put there (Move pending).
    func goTo(mapPoint g: [Double]) {
        guard let s = ui.selection, g.count >= 2 else { return }
        follow.drop(s.id)
        if ui.pending == .move {
            send(.place(x: g[0], y: g[1], z: g.count > 2 ? g[2] : nil), to: s.id)
        } else {
            send(.goal(x: g[0], y: g[1], z: g.count > 2 ? g[2] : nil), to: s.id)
            addMarker([g[0], g[1], g.count > 2 ? g[2] : 0])
        }
        ui.pending = nil
        model.flash("\(s.title) → map point", seconds: 1.5)
    }

    /// O2 control on the selected drone / rover.
    func ops(_ c: AgentOpsControl) {
        guard let s = ui.selection else { return }
        let f = model.serverFeatures.list
        guard let cmd = c.command(drone: s.drone, features: f, home: homes[s.id]) else {
            model.flash("\(c.title): not available yet", seconds: 2)
            return
        }
        model.log.event("agent_ops", ["id": .string(s.id), "control": .string(c.rawValue), "cmd": .string(cmd.name)])
        send(cmd, to: s.id)
        model.flash("\(s.title): \(c.title)", seconds: 1.5)
    }

    /// "Explore gaps": a drone / rover mission to a goal (explore mode where the server has missions).
    func explore(goal g: [Double]) {
        guard let s = ui.selection, s.rover || s.drone, g.count >= 2 else {
            model.flash("Select a sim drone or rover first", seconds: 2)
            return
        }
        if s.drone, model.serverFeatures.list.contains(AgentOpsControl.missionsFlag) {
            send(.mission(goal: g, mode: "explore", canopy: "auto"), to: s.id)
        } else {
            send(.goal(x: g[0], y: g[1], z: g.count > 2 ? g[2] : nil), to: s.id)
        }
        model.flash("\(s.title) → explore the gap", seconds: 2)
    }
}
