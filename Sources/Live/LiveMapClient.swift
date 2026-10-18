// SnailSight 10.1 L3/L4 client (plan §8.4 downlink, §8.9 L3/L4; API §6b).
// - Other agents: every agent placed in the live map (phones, replays, rovers, drones) is drawn in AR at its newest
//   keyframe with a short trail and a name tag; it works today from GET /v1/live/state (polled every 2 s while
//   More ▸ House ▸ Other agents is on). The Scans viewer gets the same list (`model.liveAgents`).
// - Downlink (feature `live_downlink` advertised by GET /v1, or Settings ▸ Live map ▸ Force live downlink): one WebSocket
//   to /v1/maps/{map}/live (API §6b.1), subscribe {layers, bbox ±12 m around you, since{epoch, seq, tiles}, json
//   transport}; `agent` messages replace the poll (trails grown locally); `f32` mesh tiles are drawn as a faint
//   amber "live" wireframe in the map frame; `change` (L4) becomes a subtle outline that fades over 90 s (`cleared`
//   removes it, `dynamic` is never flagged); `doc` re-reads rooms / objects; `rebase` / `commit` keep the old tiles
//   until their re-fused versions arrive. Ping every 10 s; reconnect 1, 2, 4, 8, 10 s, resuming from the last seq.
import ARKit
import RealityKit
import UIKit
import SnailSightCore

final class LiveMapClient {
    private unowned let model: AppModel
    private var lastPoll: TimeInterval = 0
    private var polling = false
    private var agentEntities: [String: Entity] = [:]
    private var agentSig: [String: String] = [:]
    private var agentTags: [String: Entity] = [:]
    // downlink
    private var task: URLSessionWebSocketTask?
    private var gen = 0
    private var connected = false
    private var connecting = false
    private var reconnectAt: TimeInterval = 0
    private var attempt = 0
    private var lastInbound: TimeInterval = 0
    private var tiles = LiveTileStore()
    private var tileEntities: [String: ModelEntity] = [:]
    private var changes = ChangeMarkers()
    private var changeEntities: [String: Entity] = [:]
    private var stats = (msgs: 0, tiles: 0, drawn: 0, changes: 0, docs: 0)
    private var lastStats: TimeInterval = 0
    private var downlinkAgentsAt: TimeInterval = 0
    private var trails = AgentTrails()
    private var epoch: String?
    private var lastSeq: Int?
    private var lastPing: TimeInterval = 0
    private var subCenter: [Double]?
    /// ±12 m around you in AR; ±40 m while the Map is open (it shows the whole storey).
    var bboxHalf: Double { model.showMap ? 40 : 12 }
    private var subHalf = 12.0
    // 12.0 Mesh (live): highlight steps of fresh tiles (2 fresh → 1 fading → 0 settled), base-swap outlines, storey floors
    private var tileStep: [String: Int] = [:]
    private var baseOutlines: [String: (entity: Entity, at: TimeInterval, step: Int, box: [Double])] = [:]
    private var floorZ: [Int: Double] = [:]
    private var loggedFirstMesh = false
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(model: AppModel) { self.model = model }

    private var layer: MapARLayer { model.controller.mapLayer }
    private var now: TimeInterval { Date().timeIntervalSince1970 }
    private var mapID: String { model.liveMapID }

    /// Downlink wanted: advertised (or forced) and some live layer is on.
    var downlinkWanted: Bool {
        model.serverFeatures.liveDownlink(forced: model.forceLiveDownlink) && model.serverBase != nil
            && (model.arAgents || model.houseStyle != .off || model.meshLive) && !model.showScans
    }

    /// 12.0: what the downlink subscribes to: the live layers, + the estimated world's tree events when the server has it.
    private var layers: [String] {
        LiveSubscribe.layers + (model.serverFeatures.estimatedWorld ? ["estimated"] : [])
    }

    /// Fresh tile looks (literal opacities): just arrived / changed = bright, then fading, then the settled amber.
    private static func freshMaterial(_ step: Int) -> UnlitMaterial {
        var m = UnlitMaterial(color: UIColor(red: 0.45, green: 1, blue: 0.75, alpha: 1))
        if #available(iOS 18.0, *) {
            m.triangleFillMode = .lines
            m.blending = .transparent(opacity: step >= 2 ? 0.9 : 0.6)
        } else {
            m.blending = .transparent(opacity: step >= 2 ? 0.45 : 0.3)
        }
        return m
    }
    private static let fresh2 = freshMaterial(2)
    private static let fresh1 = freshMaterial(1)

    private static func material(step: Int) -> UnlitMaterial {
        step >= 2 ? fresh2 : step == 1 ? fresh1 : liveMaterial
    }

    private static let liveMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 1, green: 0.78, blue: 0.25, alpha: 1))
        if #available(iOS 18.0, *) {
            m.triangleFillMode = .lines
            m.blending = .transparent(opacity: 0.35)
        } else {
            m.blending = .transparent(opacity: 0.15)
        }
        return m
    }()

    /// Twice a second from the AR controller's HUD tick (main).
    /// 10.6.x: foreground / Scans closed / network back: reconnect now (no leftover backoff).
    func resume(why: String) {
        guard reconnectAt > now || attempt > 0 else { return }
        reconnectAt = 0
        attempt = 0
        model.log.event("live_down_resume", ["why": .string(why)])
    }

    func tick() {
        let t = now
        layer.agentNode.isEnabled = model.arAgents
        layer.liveNode.isEnabled = model.meshLive                   // 12.0 layers ▸ Mesh (live)
        restyleFresh()
        if model.arAgents && model.serverBase != nil && !model.showScans && t - downlinkAgentsAt > 5
            && t - lastPoll >= 2 && !polling {
            poll()
        }
        if downlinkWanted {
            if !connected && !connecting && t >= reconnectAt { connect() }
            if connected && t - lastInbound > 30 { fail("silent 30 s") }
            if connected && t - lastPing >= 10 { lastPing = t; sendText(["type": "ping"]) }
            if connected, let c = layer.cameraMap, let sc = subCenter,
               hypot(c[0] - sc[0], c[1] - sc[1]) > 6 || subHalf != bboxHalf {
                resubscribe(center: c)                      // walked away / Map opened: move or grow the tile bbox
            }
            if t - downlinkAgentsAt < 5 {
                trails.expire(now: t)
                if model.arAgents { showMarks(trails.marks(me: model.agentID, now: t)) }
            }
        } else if connected || connecting {
            close("not wanted")
        }
        if changes.expire(now: t) || !changes.markers.isEmpty { renderChanges(now: t) }
        if t - lastStats >= 30, connected {
            lastStats = t
            model.log.event("live_down_stats", ["msgs": .int(stats.msgs), "tiles": .int(stats.tiles), "drawn": .int(stats.drawn),
                                                "changes": .int(stats.changes), "docs": .int(stats.docs),
                                                "held": .int(tiles.have.count),
                                                "mesh_tiles": .int(model.meshStore.feed.liveCount),
                                                "mesh_mine": .int(model.meshStore.feed.mineCount),
                                                "mesh_agents": .string(model.meshStore.feed.otherAgents.joined(separator: ",")),
                                                "mesh_live": .bool(model.meshLive)])
        }
    }

    // MARK: agents (poll)

    private func poll() {
        polling = true
        lastPoll = now
        let link = model.link!, map = mapID
        Task { [weak self] in
            let r = try? await link.request("GET", "/v1/live/state", query: [URLQueryItem(name: "map_id", value: map)], timeout: 8)
            let doc = (r?.1 == 200) ? r.flatMap { try? JSONDecoder().decode(LiveStateDoc.self, from: $0.0) } : nil
            await MainActor.run {
                guard let self else { return }
                self.polling = false
                if let doc {
                    if let v = doc.baseVersion, self.model.liveBaseVersion != v { self.model.liveBaseVersion = v }
                    self.showAgents(doc.agents)
                }
            }
        }
    }

    private func showAgents(_ list: [LiveAgent]) { showMarks(AgentMark.from(list, me: model.agentID, now: now)) }

    private func showMarks(_ marks: [AgentMark]) {
        if model.liveAgents != marks { model.liveAgents = marks }
        let ids = Set(marks.map(\.id))
        for (id, e) in agentEntities where !ids.contains(id) {
            e.removeFromParent()
            agentEntities[id] = nil
            agentSig[id] = nil
            agentTags[id] = nil
        }
        for m in marks {
            // rebuild only when the trail grew / moved (≤ every 2 s anyway)
            let sig = "\(m.trail.count)|\(m.position.map { String(format: "%.2f", $0) }.joined(separator: ","))|\(m.live)"
            if agentSig[m.id] == sig { continue }
            agentSig[m.id] = sig
            agentEntities[m.id]?.removeFromParent()
            let (e, tag) = agentEntity(m)
            layer.agentNode.addChild(e)
            agentEntities[m.id] = e
            agentTags[m.id] = tag
        }
    }

    private func agentEntity(_ m: AgentMark) -> (Entity, Entity) {
        let holder = Entity()
        let colour: UIColor = m.live ? UIColor(red: 0.95, green: 0.4, blue: 0.95, alpha: 1) : UIColor(white: 0.6, alpha: 1)
        let mat = UnlitMaterial(color: colour)
        let body = Entity()
        body.position = SIMD3<Float>(Float(m.position[0]), Float(m.position[1]), Float(m.position[2]))
        body.orientation = simd_quatf(angle: Float(m.heading), axis: SIMD3<Float>(0, 0, 1))
        // a small "camera" box with a nose along its heading (+x)
        let box = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.14, 0.08, 0.08), cornerRadius: 0.015), materials: [mat])
        let nose = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.08, 0.02, 0.02)), materials: [mat])
        nose.position = SIMD3<Float>(0.1, 0, 0)
        body.addChild(box)
        body.addChild(nose)
        let tag = layer.makeLabel(m.label, size: 0.025)
        tag.position = SIMD3<Float>(0, 0, 0.16)
        body.addChild(tag)
        holder.addChild(body)
        // trail: a dot every ~3rd point, newest 60
        let dot = MeshResource.generateSphere(radius: 0.012)
        for (i, p) in m.trail.suffix(60).enumerated() where i % 3 == 0 {
            let d = ModelEntity(mesh: dot, materials: [mat])
            d.position = SIMD3<Float>(Float(p[0]), Float(p[1]), Float(p[2]))
            holder.addChild(d)
        }
        return (holder, tag)
    }

    /// Agent name tags: MapARLayer turns them to the camera with its own labels.
    var tagEntities: [Entity] { model.arAgents ? Array(agentTags.values) : [] }

    // MARK: downlink WebSocket

    private func connect() {
        guard let b = model.serverBase else { return }
        var ws = b
        if ws.hasPrefix("https://") { ws = "wss://" + String(ws.dropFirst(8)) }
        else if ws.hasPrefix("http://") { ws = "ws://" + String(ws.dropFirst(7)) }
        guard let url = URL(string: ws + "/v1/maps/\(mapID)/live") else { return }
        gen += 1
        let g = gen
        connecting = true
        lastInbound = now
        let tk = session.webSocketTask(with: url)
        tk.maximumMessageSize = 8 << 20
        task = tk
        tk.resume()
        let c = layer.cameraMap
        subCenter = c
        subHalf = bboxHalf
        let half = subHalf
        let sub = LiveSubscribe.message(agentID: model.agentID, mapID: mapID, baseVersion: tiles.baseVersion ?? layer.mapVersion,
                                        tiles: tiles.allSince, epoch: epoch, seq: lastSeq,
                                        bbox: c.map { Self.bbox($0, half: half) }, layers: layers)
        tk.send(.string(String(decoding: sub, as: UTF8.self))) { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async { if self?.gen == g { self?.fail("send: \(err.localizedDescription)") } }
        }
        model.log.event("live_down_connect", ["url": .string(url.absoluteString), "held": .int(tiles.have.count),
                                              "attempt": .int(attempt)])
        receive(g)
    }

    private static func bbox(_ c: [Double], half: Double) -> [Double] {
        [c[0] - half, c[1] - half, c[0] + half, c[1] + half]
    }

    private func resubscribe(center c: [Double]) {
        subCenter = c
        subHalf = bboxHalf
        sendText(["type": "subscribe", "map_id": mapID, "layers": layers, "bbox": Self.bbox(c, half: subHalf)])
    }

    private func sendText(_ o: [String: Any]) {
        guard let tk = task, let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        let g = gen
        tk.send(.string(String(decoding: d, as: UTF8.self))) { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async { if self?.gen == g { self?.fail("send: \(err.localizedDescription)") } }
        }
    }

    private func receive(_ g: Int) {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, g == self.gen else { return }
                switch result {
                case .success(let m):
                    self.lastInbound = self.now
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
        let wasOpen = connected
        close(why)
        let d = LiveBackoff.delay(attempt: attempt)
        attempt += 1
        reconnectAt = now + d
        if wasOpen || attempt <= 2 { model.log.event("live_down_drop", ["why": .string(why), "retry_s": .double(d)]) }
    }

    private func close(_ why: String) {
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        connecting = false
    }

    private func handle(_ d: Data) {
        stats.msgs += 1
        model.mapFollower.liveMessage(d)            // 10.7: `rev` (map head) rides this socket too
        guard let (m, seq) = LiveDownMessage.parseWithSeq(d) else { return }
        if let q = seq { lastSeq = max(lastSeq ?? q, q) }
        switch m {
        case .head(let v, let q, let e):
            if let o = JSON.object(d)["levels"] as? [[String: Any]] {        // storey floors (Map raster heights)
                for l in o {
                    if let i = (l["level"] as? NSNumber)?.intValue, let z = (l["floor_z"] as? NSNumber)?.doubleValue { floorZ[i] = z }
                }
            }
            if let e, e != epoch { epoch = e; lastSeq = q }
            if let v { model.liveBaseVersion = v; if tiles.baseVersion == nil { tiles.rebase(v) } }
        case .agents(let list):
            downlinkAgentsAt = now
            for a in list { trails.update(a, now: now) }
            if model.arAgents { showMarks(trails.marks(me: model.agentID, now: now)) }
        case .correction:
            break                                   // own stream corrections arrive on the uplink (LiveStreamer)
        case .tile(let l, let key, let ver, let enc, let data):
            stats.tiles += 1
            guard tiles.accept(layer: l, key: key, ver: ver) else { return }
            if l == "mesh", let mesh = LiveMeshTile.decode(enc: enc, base64: data) {
                let h = LiveTileHeader.parse(d) ?? LiveTileHeader(layer: l, key: key, ver: ver)
                let applied = model.meshStore.applyLive(h, mesh: mesh, floorZ: floorZ[h.levelIndex], me: model.agentID)
                drawTile(key: key, mesh: mesh)
                if applied == .new, !loggedFirstMesh {
                    loggedFirstMesh = true
                    model.log.event("live_mesh_first", ["key": .string(key), "agents": .string(h.agents.joined(separator: ",")),
                                                        "triangles": .int(mesh.triangleCount)])
                }
            }
        case .doc(let kind, _):
            stats.docs += 1
            if kind == "objects" || kind == "rooms" { layer.reloadDocs() }
        case .change(let key, let kind, let state, let bbox):
            stats.changes += 1
            let fz = (layer.cameraMap?[2] ?? 1.4) - 1.4
            if changes.add(key: key, kind: kind, state: state, bbox: bbox, floorZ: fz, now: now) { renderChanges(now: now) }
        case .rebase(let v), .commit(let v):
            // keep drawing the old tiles until their re-fused versions (new base_version) arrive (API §6b.1)
            tiles.rebase(v)
            model.liveBaseVersion = v
            model.log.event("live_down_rebase", ["version": .int(v)])
        case .error(let s):
            model.log.event("live_down_error", ["detail": .string(s)])
        case .other(let t):
            if t == "estimated", let m = EstimatedLiveMessage.parse(d) { model.planData.estimatedLive(m) }
        }
    }

    /// 12.0: a base tile the M4 sync swapped in place: a fading outline of its box (same three steps as live tiles).
    func baseSwapped(key: String, box: [Double]) {
        guard box.count >= 12 else { return }
        baseOutlines[key]?.entity.removeFromParent()
        let e = boxOutline(box, step: 2)
        layer.liveNode.addChild(e)
        baseOutlines[key] = (e, now, 2, box)
    }

    private func boxOutline(_ b: [Double], step: Int) -> Entity {
        var mat = UnlitMaterial(color: UIColor(red: 0.45, green: 1, blue: 0.75, alpha: 1))
        mat.blending = .transparent(opacity: step >= 2 ? 0.7 : 0.35)
        let holder = Entity()
        holder.position = SIMD3<Float>(Float(b[0]), Float(b[1]), Float(b[2]))
        let sx = Float(b[3] * 2), sy = Float(b[7] * 2), sz = Float(min(b[11] * 2, 3)), t: Float = 0.01
        for a in [Float(-1), 1] {
            for c in [Float(-1), 1] {
                let ex = ModelEntity(mesh: .generateBox(size: SIMD3(sx, t, t)), materials: [mat])
                ex.position = SIMD3(0, a * sy / 2, c * sz / 2)
                let ey = ModelEntity(mesh: .generateBox(size: SIMD3(t, sy, t)), materials: [mat])
                ey.position = SIMD3(a * sx / 2, 0, c * sz / 2)
                holder.addChild(ex); holder.addChild(ey)
            }
        }
        return holder
    }

    /// Fresh tiles step down (2 → 1 → 0) as they age; base-swap outlines fade the same way and go.
    private func restyleFresh() {
        for (k, old) in tileStep {
            let st = model.meshStore.step(key: k)
            guard st != old else { continue }
            tileEntities[k]?.model?.materials = [Self.material(step: st)]
            if st == 0 { tileStep[k] = nil } else { tileStep[k] = st }
        }
        for (k, o) in baseOutlines {
            let st = model.meshStore.step(key: k, source: .base)
            if st == 0 { o.entity.removeFromParent(); baseOutlines[k] = nil; continue }
            if st != o.step {
                o.entity.removeFromParent()
                let e = boxOutline(o.box, step: st)
                layer.liveNode.addChild(e)
                baseOutlines[k] = (e, o.at, st, o.box)
            }
        }
    }

    private func drawTile(key: String, mesh m: FlatMesh) {
        var pos = [SIMD3<Float>]()
        pos.reserveCapacity(m.vertexCount)
        var i = 0
        while i + 2 < m.positions.count {
            pos.append(SIMD3<Float>(m.positions[i], m.positions[i + 1], m.positions[i + 2]))
            i += 3
        }
        var d = MeshDescriptor(name: "live")
        d.positions = MeshBuffers.Positions(pos)
        d.primitives = .triangles(m.indices)
        guard let res = try? MeshResource.generate(from: [d]) else { return }
        let st = model.meshStore.step(key: key)                         // a new / changed tile glows, then settles
        if let e = tileEntities[key] {
            e.model?.mesh = res                                         // in place: same entity, new mesh
            e.model?.materials = [Self.material(step: st)]
        } else {
            let e = ModelEntity(mesh: res, materials: [Self.material(step: st)])
            layer.liveNode.addChild(e)
            tileEntities[key] = e
        }
        if st > 0 { tileStep[key] = st }
        stats.drawn += 1
    }

    /// L4 markers: thin outlines, three opacity steps as they age (literal opacities only).
    private func renderChanges(now t: Double) {
        let keys = Set(changes.markers.map(\.key))
        for (k, e) in changeEntities where !keys.contains(k) { e.removeFromParent(); changeEntities[k] = nil }
        for mk in changes.markers {
            let f = changes.fade(mk, now: t)
            let step = f > 0.66 ? 2 : (f > 0.33 ? 1 : 0)
            let id = mk.key
            if let e = changeEntities[id], e.name == "chg\(step)" { continue }
            changeEntities[id]?.removeFromParent()
            let e = changeOutline(mk, step: step)
            e.name = "chg\(step)"
            layer.liveNode.addChild(e)
            changeEntities[id] = e
        }
    }

    private func changeOutline(_ mk: ChangeMarkers.Marker, step: Int) -> Entity {
        let colour: UIColor = mk.kind == "removed" ? UIColor(red: 1, green: 0.35, blue: 0.35, alpha: 1)
                                                   : UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
        var mat = UnlitMaterial(color: colour)
        switch step {
        case 2: mat.blending = .transparent(opacity: 0.8)
        case 1: mat.blending = .transparent(opacity: 0.5)
        default: mat.blending = .transparent(opacity: 0.25)
        }
        let holder = Entity()
        holder.position = SIMD3<Float>(Float(mk.center[0]), Float(mk.center[1]), Float(mk.center[2]))
        let sx = Float(mk.size[0]), sy = Float(mk.size[1]), sz = Float(mk.size[2]), t: Float = 0.006
        for a in [Float(-1), 1] {
            for c in [Float(-1), 1] {
                let ex = ModelEntity(mesh: .generateBox(size: SIMD3(sx, t, t)), materials: [mat])
                ex.position = SIMD3(0, a * sy / 2, c * sz / 2)
                let ey = ModelEntity(mesh: .generateBox(size: SIMD3(t, sy, t)), materials: [mat])
                ey.position = SIMD3(a * sx / 2, 0, c * sz / 2)
                let ez = ModelEntity(mesh: .generateBox(size: SIMD3(t, t, sz)), materials: [mat])
                ez.position = SIMD3(a * sx / 2, c * sy / 2, 0)
                holder.addChild(ex); holder.addChild(ey); holder.addChild(ez)
            }
        }
        return holder
    }
}
