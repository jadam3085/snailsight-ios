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
import ARKit
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
}

/// The shared sim's HUD state (its own ObservableObject: no AppModel churn at 10 Hz).
final class ServerSimUI: ObservableObject {
    enum Pending: Equatable { case goTo, patrol, droneAssist }
    @Published var active = false              // server authoritative right now
    @Published var status = ""                 // "Shared sim · 3 bodies" / "Shared sim: connecting"
    @Published var selection: ServerSimSelection?
    @Published var pending: Pending?
    @Published var patrolPoints = 0
    @Published var showGoToLabel = false
}

final class ServerSimClient {
    private unowned let model: AppModel
    let ui = ServerSimUI()
    private var authority = SimAuthority()
    private var tracks: [String: RemoteTrack] = [:]
    private var entities: [String: Entity] = [:]
    private var tags: [String: Entity] = [:]
    private var kinds: [String: String] = [:]
    private var statics: [String: SimEntitySnap] = [:]      // entity docs: name, cat, dims
    private var lastMessageAt: Double?
    private var teleop = TeleopSender()
    private var stick = V2.zero
    private let shaper = StickShaper()
    private var cmdInFlight = 0
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

    init(model: AppModel) { self.model = model }

    private var layer: MapARLayer { model.controller.mapLayer }
    private var now: TimeInterval { Date().timeIntervalSince1970 }
    private var mapID: String { layer.mapID }

    var enabled: Bool {
        model.simOn && model.sharedSim && model.serverFeatures.serverSim(forced: model.forceServerSim) && !model.recording
    }
    var isActive: Bool { authority.mode == .server }
    var tagEntities: [Entity] { isActive ? Array(tags.values) : [] }

    /// The selected rover's position in the map (Robot path starts there).
    var selectedRoverMap: [Double]? {
        guard isActive, let s = ui.selection, s.rover, let t = tracks[s.id] else { return nil }
        let p = t.pose(now: now)
        return [p.x, p.y, p.z]
    }

    // MARK: ticks

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
        Set(model.controller.sim.snapshot().map(\.id)).subtracting(deletedHere)
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
        for (id, tr) in tracks {
            guard let e = entities[id] else { continue }
            let p = tr.pose(now: t)
            e.position = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            e.orientation = simd_quatf(angle: Float(p.theta), axis: SIMD3<Float>(0, 0, 1))
        }
        if let s = ui.selection, s.rover {
            let c = shaper.command(stick, profile: RobotProfile.robosnailbob)
            if let cmd = teleop.next(v: c.v, w: c.omega, now: t) {
                send(.teleop(v: cmd.v, w: cmd.w, ttl: cmd.ttl), to: s.id, quiet: true)
            }
        }
    }

    func setStick(_ v: SIMD2<Double>) { stick = v }

    private func authorityChanged() {
        let server = authority.mode == .server
        ui.active = server
        model.controller.sim.remoteAuthority = server
        if !server {
            ui.selection = nil
            ui.pending = nil
            clearMarkers()
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
            if entities[doc.id] != nil, let tr = tracks[doc.id] {                    // re-draw with the new description
                entities[doc.id]?.removeFromParent()
                let (e, tag) = makeEntity(tr.snap.merged(withStatic: doc))
                layer.simNode.addChild(e)
                entities[doc.id] = e
                tags[doc.id] = tag
            }
        case .event(let kind, let text, let id):
            events += 1
            model.log.event("sim_server_event", ["kind": .string(kind), "id": .string(id ?? ""), "text": .string(text ?? "")])
            if isActive, let text, !text.isEmpty { model.flash(text, seconds: 2) }
            else if isActive, kind == "arrive" || kind == "arrived" { model.flash("\(title(id ?? "")) arrived", seconds: 1.5) }
            else if isActive, kind == "goal_failed" { model.flash("\(title(id ?? "")) can't get there", seconds: 2) }
        case .lease(let id, let owner, let granted):
            if granted == false, owner != model.agentID, ui.selection?.id == id {
                model.flash("\(title(id)) is driven by \(owner ?? "another device")", seconds: 2)
            }
        case .error(let s):
            model.log.event("sim_server_error", ["detail": .string(s)])
        case .other:
            break
        }
    }

    private func apply(_ raw: [SimEntitySnap], full: Bool) {
        let t = now
        let list = raw.map { $0.merged(withStatic: statics[$0.id]) }
        let ids = Set(list.map(\.id))
        for id in Array(tracks.keys) where full && !ids.contains(id) {
            tracks[id] = nil
            entities[id]?.removeFromParent()
            entities[id] = nil
            tags[id] = nil
            kinds[id] = nil
            statics[id] = nil
            if ui.selection?.id == id { ui.selection = nil }
        }
        for s in list {
            if var tr = tracks[s.id] { tr.update(s, now: t); tracks[s.id] = tr } else { tracks[s.id] = RemoteTrack(s, now: t) }
            if entities[s.id] == nil || kinds[s.id] != s.kind {
                entities[s.id]?.removeFromParent()
                let (e, tag) = makeEntity(s)
                layer.simNode.addChild(e)
                entities[s.id] = e
                tags[s.id] = tag
                kinds[s.id] = s.kind
            }
        }
        if let sel = ui.selection, let tr = tracks[sel.id] {
            let d = selection(tr.snap)
            if d != sel { ui.selection = d }
        }
    }

    private func title(_ id: String) -> String {
        guard let s = tracks[id]?.snap else { return id }
        return s.name ?? (s.isDrone ? "Sim drone" : s.isRover ? "Sim rover" : s.kind.capitalized)
    }

    private func selection(_ s: SimEntitySnap) -> ServerSimSelection {
        var d = s.state ?? "idle"
        if let o = s.owner, o != model.agentID, !o.isEmpty { d += " · \(o)" }
        if s.isDrone { d += String(format: " · %.1f m up", s.pose.z - ((layer.cameraMap?[2] ?? 1.4) - 1.4)) }
        return ServerSimSelection(id: s.id, title: title(s.id), detail: d, rover: s.isRover, drone: s.isDrone)
    }

    // MARK: drawing (map frame, z up, heading +x)

    private func makeEntity(_ s: SimEntitySnap) -> (Entity, Entity) {
        let e = Entity()
        let body: [(SIMD3<Float>, SIMD3<Float>, UIColor)]          // (size, offset, colour)
        if s.isDrone {
            let c = UIColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)
            body = [(SIMD3(0.18, 0.18, 0.06), SIMD3(0, 0, 0), c),
                    (SIMD3(0.5, 0.03, 0.02), SIMD3(0, 0, 0.02), c),
                    (SIMD3(0.03, 0.5, 0.02), SIMD3(0, 0, 0.02), c),
                    (SIMD3(0.06, 0.04, 0.03), SIMD3(0.1, 0, 0), UIColor.systemRed)]
        } else if s.isRover {
            let c = UIColor(red: 0.35, green: 0.45, blue: 0.6, alpha: 1)
            body = [(SIMD3(0.82, 0.62, 0.25), SIMD3(0, 0, 0.195), c),           // Q6 Edge base, 0.07 m clearance
                    (SIMD3(0.08, 0.08, 0.3), SIMD3(0.15, 0, 0.47), UIColor.darkGray),
                    (SIMD3(0.06, 0.3, 0.05), SIMD3(0.4, 0, 0.25), UIColor.systemYellow)]
        } else if s.isObject, let d = s.dims, d.count == 3 {
            let size = SIMD3<Float>(Float(max(d[0], 0.05)), Float(max(d[1], 0.05)), Float(max(d[2], 0.05)))
            body = [(size, SIMD3<Float>(0, 0, size.z / 2), UIColor(red: 0.75, green: 0.7, blue: 0.6, alpha: 1))]
        } else if let d = s.dims, d.count == 3 {
            let c = UIColor(red: 0.6, green: 0.42, blue: 0.25, alpha: 1)
            let L = Float(max(d[0], 0.1)), W = Float(max(d[1], 0.05)), H = Float(max(d[2], 0.1))
            body = [(SIMD3<Float>(L * 0.75, W, H * 0.55), SIMD3<Float>(0, 0, H * 0.5), c),
                    (SIMD3<Float>(L * 0.22, W * 0.7, H * 0.3), SIMD3<Float>(L * 0.4, 0, H * 0.85), c)]
        } else {
            let small = ["fox", "rabbit"].contains { s.kind.contains($0) }
            let c = UIColor(red: 0.6, green: 0.42, blue: 0.25, alpha: 1)
            body = small ? [(SIMD3(0.4, 0.15, 0.25), SIMD3(0, 0, 0.13), c)]
                         : [(SIMD3(1.0, 0.3, 0.8), SIMD3(0, 0, 0.45), c), (SIMD3(0.2, 0.15, 0.25), SIMD3(0.55, 0, 0.95), c)]
        }
        for (size, off, colour) in body {
            let m = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(size.x, size.y, size.z) * 0.2),
                                materials: [SimpleMaterial(color: colour, roughness: 0.6, isMetallic: false)])
            m.position = off
            e.addChild(m)
        }
        let tag = layer.makeLabel(title(s.id), size: 0.03)
        let top = Float(s.dims.flatMap { $0.count == 3 ? $0[2] : nil } ?? (s.isRover ? 0.6 : (s.isDrone ? 0.05 : 1.0)))
        tag.position = SIMD3<Float>(0, 0, top + 0.15)
        e.addChild(tag)
        return (e, tag)
    }

    private var pickBoxes: [ARBoxItem] {
        tracks.values.map { tr in
            let p = tr.pose(now: now), s = tr.snap
            let size: [Double] = (s.dims?.count == 3 ? s.dims : nil)
                ?? (s.isDrone ? [0.5, 0.5, 0.2] : s.isRover ? [0.82, 0.62, 0.6] : [1.0, 0.4, 1.2])
            return ARBoxItem(id: s.id, label: s.kind, center: [p.x, p.y, p.z + size[2] / 2], size: size, yaw: p.theta,
                             movable: true, confidence: 1)
        }
    }

    // MARK: taps + commands

    /// true = consumed (in server mode every tap is ours: the local bodies are hidden).
    func handleTap(_ pt: CGPoint, arView: ARView) -> Bool {
        guard isActive else { return false }
        if let p = ui.pending {
            guard let g = floorPoint(pt, arView: arView) else { model.flash("Aim at the floor"); return true }
            switch p {
            case .goTo:
                if let s = ui.selection { send(.goal(x: g[0], y: g[1], z: g[2]), to: s.id); addMarker(g) }
                ui.pending = nil
            case .patrol:
                patrol.append([g[0], g[1]])
                addMarker(g)
                ui.patrolPoints = patrol.count
            case .droneAssist:
                if let s = ui.selection {
                    task(SimServerAPI.taskBody(task: "drone_assist", goal: g, agentID: model.agentID), on: s.id,
                         what: "drone assist")
                    addMarker(g)
                }
                ui.pending = nil
            }
            return true
        }
        if let r = layer.mapRay(pt), let hit = ARMapContent.pick(origin: r.origin, direction: r.direction, boxes: pickBoxes),
           let tr = tracks[hit.id] {
            ui.selection = ui.selection?.id == hit.id ? nil : selection(tr.snap)
            stick = .zero
        } else {
            ui.selection = nil
        }
        return true
    }

    private func floorPoint(_ pt: CGPoint, arView: ARView) -> [Double]? {
        guard let hit = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .horizontal).first else { return nil }
        return layer.toMap(world: Geo.position(hit.worldTransform))
    }

    func command(_ c: SimServerAPI.Command) {
        guard let s = ui.selection else { return }
        send(c, to: s.id)
    }

    func startPending(_ p: ServerSimUI.Pending) {
        clearMarkers()
        patrol = []
        ui.patrolPoints = 0
        ui.pending = p
    }

    func startPatrol() {
        guard let s = ui.selection, patrol.count >= 2 else { return }
        send(.patrol(patrol), to: s.id)
        ui.pending = nil
    }

    func cancelPending() {
        ui.pending = nil
        patrol = []
        ui.patrolPoints = 0
        clearMarkers()
    }

    /// "Go to the lamp": the server resolves the label (S3); if it refuses, the phone picks the nearest match from the
    /// AR layer's objects of this map version and sends a spot beside it.
    func goTo(label: String) {
        guard let s = ui.selection else { return }
        send(.goToLabel(label), to: s.id, quiet: true) { [weak self] ok in
            if ok { self?.model.flash("\(s.title) → \(label)", seconds: 2) } else { self?.goToLocally(label: label, id: s.id) }
        }
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
        task(SimServerAPI.taskBody(task: "deter", kinds: ["deer"], agentID: model.agentID), on: s.id, what: "deter deer")
    }

    func startDroneAssist() {
        guard let s = ui.selection, s.rover else {
            model.flash("Select a sim rover first, then Drone assist", seconds: 2.5)
            return
        }
        startPending(.droneAssist)
    }

    private func task(_ body: Data, on id: String, what: String) {
        post(SimServerAPI.taskPath(map: mapID, id: id), body: body, what: what)
    }

    private func send(_ c: SimServerAPI.Command, to id: String, quiet: Bool = false, done: ((Bool) -> Void)? = nil) {
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
                    self.model.log.event("sim_server_cmd", ["id": .string(id), "status": .int(st),
                                                            "cmd": .string(String(describing: c).prefix(60).description)])
                }
                if st == 409 { self.model.flash("Another device is driving it", seconds: 2) }
                else if !quiet && !(200..<300).contains(st) { self.model.flash("The map server refused (\(st))", seconds: 2) }
                done?((200..<300).contains(st))
            }
        }
    }

    /// Spawn at the reticle (screen centre) on the floor.
    func spawn(_ kind: String, arView: ARView) {
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let g = floorPoint(c, arView: arView), let cam = layer.cameraMap else { model.flash("Aim the + at the floor"); return }
        let z = kind == "sim-drone" ? g[2] + 1.0 : g[2]
        let theta = atan2(cam[1] - g[1], cam[0] - g[0])          // face the phone
        let body = SimServerAPI.spawnBody(kind: kind, x: g[0], y: g[1], z: z, theta: theta, agentID: model.agentID)
        post(SimServerAPI.entitiesPath(map: mapID), body: body, what: "spawn \(kind)")
    }


    func despawnSelected() {
        guard let s = ui.selection else { return }
        let link = model.link!, path = SimServerAPI.entityPath(map: mapID, id: s.id)
        ui.selection = nil
        deletedHere.insert(s.id)
        Task { [weak self] in
            let r = try? await link.request("DELETE", path, timeout: 10)
            await MainActor.run { self?.model.log.event("sim_server_despawn", ["id": .string(s.id), "status": .int(r?.1 ?? 0)]) }
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
    }

    private func clearMarkers() {
        for e in markers { e.removeFromParent() }
        markers = []
    }
}

/// The shared sim's floating bar (selected body + commands), in the slim 9.8 style.
struct ServerSimBar: View {
    @ObservedObject var ui: ServerSimUI
    let sim: ServerSimClient
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let p = ui.pending { pendingRow(p) }
            if let s = ui.selection { selected(s) } else { idle }
        }
        .sheet(isPresented: $ui.showGoToLabel) { goToSheet.presentationDetents([.height(200)]) }
    }

    private var idle: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack").font(.caption2)
            Text(ui.status.isEmpty ? "Shared sim" : ui.status).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            Text("· tap a body").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func pendingRow(_ p: ServerSimUI.Pending) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill").foregroundStyle(.cyan)
            Text(p == .goTo ? "Tap the floor where it should go"
                 : p == .droneAssist ? "Tap where the drone should fly ahead"
                 : "Tap patrol points (\(ui.patrolPoints)), then Start")
                .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if p == .patrol { Button("Start") { sim.startPatrol() }.font(.caption.weight(.bold)).disabled(ui.patrolPoints < 2) }
            Button { sim.cancelPending() } label: { Image(systemName: "xmark.circle.fill") }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func selected(_ s: ServerSimSelection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: s.drone ? "airplane" : s.rover ? "car.side" : "pawprint").font(.caption).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.title).font(.caption.weight(.bold)).lineLimit(1)
                Text(s.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 4)
            if s.rover || s.drone {
                icon("mappin.and.ellipse", "Go to") { sim.startPending(.goTo) }
                icon("magnifyingglass", "Go to object") { label = ""; ui.showGoToLabel = true }
                icon("point.3.connected.trianglepath.dotted", "Patrol") { sim.startPending(.patrol) }
                if s.rover {
                    icon("hare", "Deter deer") { sim.deterDeer() }
                    icon("airplane.departure", "Drone assist") { sim.startDroneAssist() }
                }
                icon("stop.fill", "Stop") { sim.command(.stop) }
            }
            icon("trash", "Remove") { sim.despawnSelected() }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.cyan.opacity(0.35)))
    }

    private func icon(_ name: String, _ a11y: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.caption.weight(.semibold)).frame(width: 28, height: 26) }
            .buttonStyle(.plain)
            .accessibilityLabel(a11y)
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
