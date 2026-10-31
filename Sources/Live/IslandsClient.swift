// SnailSight 12.22 islands (server live 0.10, API §6b.13): a walk outside the mapped house becomes an island (its own
// live map `<base>~isl-<hex6>`, its own frame), joined to the house / other islands later by geometry.
// - World: GET /v1/live/islands?map_id=<base> (on Live map / Map open, every 30 s, and at once when an ack or a WS
//   message names a newer revision); `{"type": "islands"}` world revisions from the base downlink and every island feed.
// - The pill: `ack.islands` says which island this stream founds / extends ("NEW AREA · island ‹ab12cd› · approx ±6 m")
//   instead of FINDING YOU / NOT IN MAP.
// - Tiles: up to MemPlan.islandMaxMaps island live feeds (the island you are in first, then exact islands near you with
//   the house lock, then placed ones while Map 3D is open), each a WebSocket on /v1/maps/<island>/live subscribed to
//   corrections + mesh. Mesh tiles are drawn in the island's frame under one entity per island:
//     AR: the island you are in draws in its OWN frame (its feed's correction of this stream = T_island_arkit); islands
//         of the same component chain through it; with the house lock, EXACT islands go through T_house_frame;
//         approximate islands are never drawn in AR (metres off).
//     Map 3D: every placed island through T_house_frame, approximate ones translucent.
//   Tiles total <= MemPlan.islandMaxTiles (the island you are in keeps half, near you first).
// - 2D Map: outlines at their lat/lon (MapPlanView), dashed when approximate.
import ARKit
import CoreLocation
import Metal
import RealityKit
import UIKit
import SnailSightCore

final class IslandsClient {
    private unowned let model: AppModel
    private(set) var world = IslandWorld()
    private var feeds: [String: IslandFeed] = [:]
    /// T_island_arkit per island this phone is placed in (its feed's correction of our CURRENT stream).
    private var islandArkit: [String: (T: Mat4, stream: String, at: Double)] = [:]
    private var lastFetch: TimeInterval = 0
    private var fetching = false
    private var needFetch = false
    private var pathsFetched: [String: Int] = [:]          // island id -> keyframes when its path was read
    private var fix: CLLocation?
    private(set) var outlines: [IslandOutline] = []
    /// Bumps when tiles or placements change (Map 3D re-clones).
    private(set) var rev = 0
    private var lastStats: TimeInterval = 0
    private var lastMine: [IslandAck] = []
    private var lastPill: IslandPillNote?

    init(model: AppModel) { self.model = model }

    private var layer: MapARLayer { model.controller.mapLayer }
    private var now: TimeInterval { Date().timeIntervalSince1970 }
    var base: String { model.liveMapID.split(separator: "~").first.map(String.init) ?? model.liveMapID }

    /// The pill's note (MapLocalizer, only while the house is not locked).
    var pillNote: IslandPillNote? {
        guard model.liveOn else { return nil }
        var far: Double?
        if let f = fix, f.horizontalAccuracy >= 0, f.horizontalAccuracy <= 100,
           let d = world.distanceFromHouse(lat: f.coordinate.latitude, lon: f.coordinate.longitude),
           d > 80 + 3 * f.horizontalAccuracy {
            far = d
        }
        return world.pillNote(farFromHouseM: far)
    }

    // MARK: inputs

    /// Every uplink ack (main).
    func ack(_ o: [String: Any]) {
        let r = world.applyAck(o)
        if r.fetch { needFetch = true }
        if r.changed { mineChanged() }
    }

    /// A `{"type": "islands"}` world revision (any feed, main).
    func worldMessage(_ o: [String: Any]) {
        if world.applyMessage(o) { worldChanged(source: "ws") }
    }

    func fixChanged(_ l: CLLocation) { fix = l }

    /// The ARKit world changed: island corrections belong to the old world; the new stream feeds no island yet.
    func worldFrameChanged() {
        islandArkit.removeAll()
        world.clearMine()
        mineChanged()
    }

    func liveChanged(_ on: Bool) {
        if on { needFetch = true } else {
            world.clearMine()
            islandArkit.removeAll()
            mineChanged()
        }
    }

    /// An island feed saw a correction of one of this phone's streams.
    fileprivate func correction(island: String, T: Mat4, stream: String) {
        guard stream == model.liveStreamer.streamID else { return }
        let first = islandArkit[island] == nil
        islandArkit[island] = (T, stream, now)
        if first {
            model.log.event("island_frame", ["island": .string(island), "stream_id": .string(stream),
                                             "x": .double(T[0, 3]), "y": .double(T[1, 3]), "z": .double(T[2, 3])])
        }
    }

    fileprivate func feedTilesChanged() { rev &+= 1 }

    private func mineChanged() {
        let m = world.mine
        guard m != lastMine else { return }
        lastMine = m
        let c = world.current
        var ev: [String: LogValue] = ["islands": .string(m.map(\.island).joined(separator: ",")), "rev": .int(world.rev)]
        if let c {
            ev["island"] = .string(c.island); ev["placed"] = .bool(c.placed)
            if let e = c.exact { ev["exact"] = .bool(e) }
            if let a = c.approx { ev["approx"] = .bool(a) }
        }
        model.log.event("island_state", ev)
        rev &+= 1
    }

    private func worldChanged(source: String) {
        outlines = world.outlines()
        rev &+= 1
        let placed = world.islands.values.filter { $0.placement.T_house_frame != nil }.count
        let exact = world.islands.values.filter { $0.placement.exact }.count
        model.log.event("islands_world", ["rev": .int(world.rev), "source": .string(source), "islands": .int(world.islands.count),
                                          "placed": .int(placed), "exact": .int(exact), "joins": .int(world.joins),
                                          "house_datum": .bool(world.houseDatum != nil),
                                          "mine": .string(world.mine.map(\.island).joined(separator: ","))])
    }

    // MARK: tick (HUD, 2 Hz)

    private var wanted: Bool {
        model.serverBase != nil && (model.liveOn || model.showMap || model.showMap3D)
    }

    func tick() {
        let t = now
        if wanted, !fetching, needFetch || t - lastFetch > 30 { fetch() }
        let p = model.memPlan
        let houseShown = layer.shown != nil && model.mapLocalizer.alignment != nil
        let plan = wanted ? world.feedPlan(maxMaps: p.islandMaxMaps, camHouse: houseShown ? layer.cameraMap : nil,
                                           radiusM: max(p.islandRadiusM, 40), mapOpen: model.showMap3D || model.showMap) : []
        for (id, f) in feeds where !plan.contains(id) {
            f.close("not wanted")
            feeds[id] = nil
            rev &+= 1
            model.log.event("island_feed", ["island": .string(id), "state": .string("closed")])
        }
        for id in plan where feeds[id] == nil {
            guard let info = world.islands[id] ?? world.mine.first(where: { $0.island == id }).map({ IslandInfo(id: $0.island, mapID: $0.mapID) }) else { continue }
            let f = IslandFeed(model: model, client: self, id: id, mapID: info.mapID)
            layer.islandRoot.addChild(f.node)
            feeds[id] = f
            model.log.event("island_feed", ["island": .string(id), "map_id": .string(info.mapID), "state": .string("open")])
        }
        // AR placement (stale corrections > 120 s or of an old stream are dropped, as MapARLayer's liveAlign)
        let sid = model.liveStreamer.streamID
        islandArkit = islandArkit.filter { $0.value.stream == sid && t - $0.value.at < 120 }
        let ia: [String: Mat4] = islandArkit.mapValues { $0.T }
        let H: Mat4? = houseShown ? layer.shown?.matrix : nil
        var camIsland: [String: [Double]] = [:]
        let cw = layer.camWorld
        for (id, f) in feeds {
            let T = world.arPlacement(id, islandArkit: ia, houseArkit: H)
            f.place(T)
            if let T {
                camIsland[id] = T.inverse.apply([Double(cw.x), Double(cw.y), Double(cw.z)])
            }
        }
        layer.islandRoot.isEnabled = model.worldOn && !model.recording && !model.arSuspended
            && (model.drawMeshLive || model.liveMapView || !world.mine.isEmpty)
        // budget: the island you are in keeps half the tiles (near you), the rest share
        let cur = world.current?.island
        var curHeld = false
        if let c = cur, feeds[c] != nil { curHeld = true }
        let others = max(1, feeds.count - (curHeld ? 1 : 0))
        for (id, f) in feeds {
            let mine = id == cur
            let cap = feeds.count <= 1 ? p.islandMaxTiles : (mine ? p.islandMaxTiles / 2 : max(2, (p.islandMaxTiles / 2) / others))
            f.tick(cam: camIsland[id], radius: mine ? p.islandRadiusM : .infinity, maxTiles: cap)
        }
        if t - lastStats >= 60, !feeds.isEmpty || !world.islands.isEmpty {
            lastStats = t
            model.log.event("island_stats", ["rev": .int(world.rev), "islands": .int(world.islands.count), "feeds": .int(feeds.count),
                                             "connected": .int(feeds.values.filter(\.connected).count),
                                             "tiles": .int(heldTiles),
                                             "mem_mb": .double((Double(estimatedBytes) / 1_048_576 * 10).rounded() / 10),
                                             "in_frame": .string(ia.keys.sorted().joined(separator: ",")),
                                             "mine": .string(world.mine.map(\.island).joined(separator: ","))])
        }
        let note = pillNote
        if note != lastPill {
            lastPill = note
            model.log.event("island_pill", ["text": .string(note?.text ?? "")])
        }
    }

    // MARK: REST

    private func fetch() {
        guard let link = model.link else { return }
        fetching = true
        needFetch = false
        lastFetch = now
        let b = base
        Task { [weak self] in
            let r = try? await link.request("GET", "/v1/live/islands", query: [URLQueryItem(name: "map_id", value: b)], timeout: 10)
            let o: [String: Any]? = (r?.1 == 200) ? r.map { JSON.object($0.0) } : nil
            let status = r?.1 ?? 0
            await MainActor.run {
                guard let self else { return }
                self.fetching = false
                guard let o else {
                    if status != 404 { self.model.log.event("islands_fetch_error", ["status": .int(status)]) }
                    return
                }
                if self.world.applyDoc(o) { self.worldChanged(source: "rest") }
                self.fetchPaths()
            }
        }
    }

    /// Paths for the 2D Map outlines (<= 500 points each), re-read when an island grew by >= 25 %.
    private func fetchPaths() {
        guard let link = model.link else { return }
        let todo = world.islands.values.filter { i in
            guard i.live, i.placement.T_house_frame != nil || i.placement.datum != nil else { return false }
            let seen = pathsFetched[i.id] ?? 0
            return seen == 0 || Double(i.keyframes) >= Double(seen) * 1.25
        }.prefix(6)
        for i in todo {
            pathsFetched[i.id] = max(1, i.keyframes)
            let id = i.id
            Task { [weak self] in
                let r = try? await link.request("GET", "/v1/live/islands/\(id)", timeout: 10)
                guard let r, r.1 == 200 else { return }
                let o = JSON.object(r.0)
                let raw = (o["path"] as? [[NSNumber]]) ?? ((o["island"] as? [String: Any])?["path"] as? [[NSNumber]]) ?? []
                let path: [[Double]] = raw.compactMap { p in p.count >= 2 ? p.map(\.doubleValue) : nil }
                guard !path.isEmpty else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.world.setPath(id, path)
                    self.outlines = self.world.outlines()
                }
            }
        }
    }

    // MARK: memory / Map 3D

    var estimatedBytes: Int {
        var b = 0
        for f in feeds.values { b += f.estimatedBytes }
        return b
    }
    var heldTiles: Int {
        var n = 0
        for f in feeds.values { n += f.tileCount }
        return n
    }

    /// Map 3D (house frame): every held island tile through T_house_frame, approximate ones translucent.
    func map3DSources() -> [Entity] {
        var out: [Entity] = []
        for pl in world.map3DPlacements() {
            guard let f = feeds[pl.id], f.tileCount > 0 else { continue }
            let holder = Entity()
            holder.transform = Transform(matrix: pl.T.simdMatrix)
            for e in f.cloneTiles(approx: pl.approx) { holder.addChild(e) }
            out.append(holder)
        }
        return out
    }
}

/// One island's live feed: WebSocket /v1/maps/<island>/live (corrections + mesh), its tiles under `node` in the
/// island frame.
final class IslandFeed {
    private unowned let model: AppModel
    private unowned let client: IslandsClient
    let id: String
    let mapID: String
    let node = Entity()
    private var task: URLSessionWebSocketTask?
    private var gen = 0
    private(set) var connected = false
    private var connecting = false
    private var reconnectAt: TimeInterval = 0
    private var attempt = 0
    private var lastInbound: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var store = LiveTileStore()
    private var entities: [String: ModelEntity] = [:]
    private var data: [String: (mesh: FlatMesh, rgb: [UInt8]?)] = [:]
    private var lru = SpatialLRU<String>()
    private var subCenter: [Double]?
    private var placed = false
    private var drawnLook: String?
    static let half = 20.0

    init(model: AppModel, client: IslandsClient, id: String, mapID: String) {
        self.model = model; self.client = client; self.id = id; self.mapID = mapID
        node.name = "island." + id
        node.isEnabled = false
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }
    var tileCount: Int { data.count }
    var estimatedBytes: Int { lru.totalBytes }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: placement + tick

    /// T_arkit_island (nil = not drawn in AR).
    func place(_ T: Mat4?) {
        if let T {
            node.transform = Transform(matrix: T.simdMatrix)
            placed = true
        } else {
            placed = false
        }
        let on = placed && !data.isEmpty
        if node.isEnabled != on { node.isEnabled = on }
    }

    /// `cam` = the camera in the island frame (when placed in AR), `radius` / `maxTiles` = this feed's budget.
    func tick(cam: [Double]?, radius: Double, maxTiles: Int) {
        let t = now
        let look = model.liveMapView ? "live" : model.meshColour.rawValue
        if look != drawnLook {
            drawnLook = look
            for (k, d) in data { draw(key: k, mesh: d.mesh, rgb: d.rgb) }
        }
        if model.serverBase == nil { if connected || connecting { close("offline") }; return }
        if !connected && !connecting && t >= reconnectAt { connect(cam: cam) }
        if connected && t - lastInbound > 30 { fail("silent 30 s") }
        if connected && t - lastPing >= 10 { lastPing = t; send(["type": "ping"]) }
        if connected, let c = cam {
            if let sc = subCenter {
                if hypot(c[0] - sc[0], c[1] - sc[1]) > 6 { resubscribe(c) }
            } else {
                resubscribe(c)
            }
        }
        let c = cam ?? subCenter ?? [0, 0]
        for k in lru.evictions(x: c[0], y: c[1], radius: radius, maxCount: maxTiles) { drop(k) }
    }

    // MARK: socket

    private func connect(cam: [Double]?) {
        guard let b = model.serverBase else { return }
        var ws = b
        if ws.hasPrefix("https://") { ws = "wss://" + String(ws.dropFirst(8)) }
        else if ws.hasPrefix("http://") { ws = "ws://" + String(ws.dropFirst(7)) }
        guard let url = URL(string: ws + "/v1/maps/\(mapID)/live") else { return }
        gen += 1
        let g = gen
        connecting = true
        lastInbound = now
        let tk = Self.session.webSocketTask(with: url)
        tk.maximumMessageSize = 8 << 20
        task = tk
        tk.resume()
        subCenter = cam
        let bbox: [Double]? = cam.map { [$0[0] - Self.half, $0[1] - Self.half, $0[0] + Self.half, $0[1] + Self.half] }
        let sub = LiveSubscribe.message(agentID: model.agentID, mapID: mapID, baseVersion: store.baseVersion,
                                        tiles: store.allSince, bbox: bbox, layers: ["corrections", "mesh"])
        tk.send(.string(String(decoding: sub, as: UTF8.self))) { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async { if self?.gen == g { self?.fail("send: \(err.localizedDescription)") } }
        }
        receive(g)
    }

    private func resubscribe(_ c: [Double]) {
        subCenter = c
        send(["type": "subscribe", "map_id": mapID, "layers": ["corrections", "mesh"],
              "bbox": [c[0] - Self.half, c[1] - Self.half, c[0] + Self.half, c[1] + Self.half]])
    }

    private func send(_ o: [String: Any]) {
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
                    if self.connecting {
                        self.connecting = false
                        self.connected = true
                        self.attempt = 0
                        self.model.log.event("island_feed", ["island": .string(self.id), "state": .string("connected")])
                    }
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
        if wasOpen || attempt <= 2 {
            model.log.event("island_feed", ["island": .string(id), "state": .string("drop"), "why": .string(why), "retry_s": .double(d)])
        }
    }

    func close(_ why: String) {
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        connecting = false
        if why == "not wanted" {
            for k in Array(data.keys) { drop(k) }
            node.removeFromParent()
        }
    }

    // MARK: messages

    private func handle(_ d: Data) {
        let o = JSON.object(d)
        let type = o["type"] as? String ?? ""
        if type == "islands" { client.worldMessage(o); return }
        if type == "correction" {
            guard (o["agent_id"] as? String) == model.agentID, (o["placed"] as? Bool) ?? false,
                  let sid = o["stream_id"] as? String,
                  let A = (o["T_map_arkit"] as? [NSNumber])?.map(\.doubleValue), A.count == 16, A.allSatisfy(\.isFinite) else { return }
            client.correction(island: id, T: Mat4(A), stream: sid)
            return
        }
        let parsed = type == "tile" ? LiveDownMessage.parseWithSeq(d) : nil
        guard let msg = parsed?.message, case .tile(let l, let key, let ver, let enc, let b64) = msg, l == "mesh" else {
            if type == "rebase" || type == "commit", let v = o["base_version"] as? Int { store.rebase(v) }
            return
        }
        guard store.accept(layer: l, key: key, ver: ver), let mesh = LiveMeshTile.decode(enc: enc, base64: b64) else { return }
        let h = LiveTileHeader.parse(d) ?? LiveTileHeader(layer: l, key: key, ver: ver)
        let rgb = LiveMeshTile.decodeColour(base64: h.rgb, vertexCount: mesh.vertexCount)
        data[key] = (mesh, rgb)
        let cpu: Int = (mesh.positions.count + mesh.indices.count) * 4
        let gpu: Int = rgb != nil ? mesh.triangleCount * 64 : cpu
        let col: Int = (rgb?.count ?? 0) * 2
        var cx = 0.0, cy = 0.0
        if let sq = h.square { cx = (sq[0] + sq[2]) / 2; cy = (sq[1] + sq[3]) / 2 }
        lru.put(key, x: cx, y: cy, bytes: cpu + gpu + col, now: now)
        draw(key: key, mesh: mesh, rgb: rgb)
        if placed, !node.isEnabled { node.isEnabled = true }
        client.feedTilesChanged()
    }

    private func drop(_ key: String) {
        lru.remove(key)
        entities.removeValue(forKey: key)?.removeFromParent()
        data[key] = nil
        store.forget(layer: "mesh", key: key)
        client.feedTilesChanged()
    }

    // MARK: drawing (island frame, z up)

    /// Islands read as "another area": a cool blue wire; photo / Live map view looks as the house's live tiles.
    private static let wire: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.45, green: 0.62, blue: 1, alpha: 1))
        if #available(iOS 18.0, *) {
            m.triangleFillMode = .lines
            m.blending = .transparent(opacity: 0.45)
        } else {
            m.blending = .transparent(opacity: 0.2)
        }
        return m
    }()

    private static let approxWire: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.45, green: 0.62, blue: 1, alpha: 1))
        if #available(iOS 18.0, *) {
            m.triangleFillMode = .lines
            m.blending = .transparent(opacity: 0.22)
        } else {
            m.blending = .transparent(opacity: 0.1)
        }
        return m
    }()

    private static let nearest: MaterialParameters.Texture.Sampler = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .nearest
        d.magFilter = .nearest
        d.mipFilter = .notMipmapped
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        return MaterialParameters.Texture.Sampler(d)
    }()

    private func draw(key: String, mesh: FlatMesh, rgb: [UInt8]?) {
        guard let built = Self.build(mesh, rgb: rgb, live: model.liveMapView, photo: model.meshColour == .photo) else { return }
        var mat: any RealityKit.Material = Self.wire
        if let tex = built.1 {
            var u = UnlitMaterial()
            u.color = .init(tint: .white, texture: .init(tex, sampler: Self.nearest))
            if !model.liveMapView { u.blending = .transparent(opacity: 0.92) }
            mat = u
        }
        if let e = entities[key] {
            e.model?.mesh = built.0
            e.model?.materials = [mat]
        } else {
            let e = ModelEntity(mesh: built.0, materials: [mat])
            node.addChild(e)
            entities[key] = e
        }
    }

    private static func build(_ m: FlatMesh, rgb: [UInt8]?, live: Bool, photo: Bool) -> (MeshResource, TextureResource?)? {
        var d = MeshDescriptor(name: "island")
        var tex: TextureResource?
        let strip: LiveMeshTile.FaceTextured? = live ? LiveMeshTile.faceTextured(m, faceRGB: LiveViewLook.faceColours(m, rgb: rgb))
            : (photo ? rgb.flatMap { LiveMeshTile.faceTextured(m, rgb: $0) } : nil)
        if let ft = strip, let img = stripImage(ft.rgba, w: ft.width, h: ft.rows),
           let t = try? TextureResource.generate(from: img, options: .init(semantic: .color, mipmapsMode: .none)) {
            var pos = [SIMD3<Float>](), uv = [SIMD2<Float>]()
            pos.reserveCapacity(ft.positions.count / 3)
            uv.reserveCapacity(ft.uvs.count / 2)
            var i = 0
            while i + 2 < ft.positions.count { pos.append(SIMD3<Float>(ft.positions[i], ft.positions[i + 1], ft.positions[i + 2])); i += 3 }
            i = 0
            while i + 1 < ft.uvs.count { uv.append(SIMD2<Float>(ft.uvs[i], ft.uvs[i + 1])); i += 2 }
            d.positions = MeshBuffers.Positions(pos)
            d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
            d.primitives = .triangles(ft.indices)
            tex = t
        } else {
            var pos = [SIMD3<Float>]()
            pos.reserveCapacity(m.vertexCount)
            var i = 0
            while i + 2 < m.positions.count { pos.append(SIMD3<Float>(m.positions[i], m.positions[i + 1], m.positions[i + 2])); i += 3 }
            d.positions = MeshBuffers.Positions(pos)
            d.primitives = .triangles(m.indices)
        }
        guard let res = try? MeshResource.generate(from: [d]) else { return nil }
        return (res, tex)
    }

    private static func stripImage(_ px: [UInt8], w: Int, h: Int) -> CGImage? {
        guard w > 0, h > 0, px.count == w * h * 4, let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Map 3D clones (shared mesh resources); approximate islands get the faint wire.
    func cloneTiles(approx: Bool) -> [Entity] {
        var out: [Entity] = []
        for e in entities.values {
            let c: ModelEntity = e.clone(recursive: true)
            c.isEnabled = true
            if approx { c.model?.materials = [Self.approxWire] }
            out.append(c)
        }
        return out
    }
}
