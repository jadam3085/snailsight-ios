// SnailSight 12.18: Layer B consumer in AR and Map ▸ 3D (live world build 2026-10-28 item 3; API §6b.7, SnailSightCore
// LayerB.swift).
//  - The live downlink (LiveMapClient, one socket) subscribes to layer `surface` too; its tile frames come here.
//  - Deltas apply in arrival order (LayerBStore): `since` = held → applied at once; a gap → the tile is fetched in full
//    (GET /v1/live/surface/{level}/{tx}/{ty}?transport=json); `since: null` → full replacement; epoch change → start over.
//  - Each tile's surface blocks are drawn as ONE mesh under MapARLayer.blockNode (photo colour when the server sent
//    colour and Mesh colour is Photo, else the live wire), rebuilt per delta. Where this phone's own device surface has
//    seen the place, its faces are hidden too (DeviceSurface: the device wins near you).
//  - Base tiles hide their faces inside every `surface` / `empty` cube (TileStreamer.blocksChanged; Map ▸ 3D the same
//    in Map3DTileLoader), and show them again when a block is `removed`.
//  - The old `mesh` live tile of the same key is not drawn while Layer B has surface there (never two surfaces).
//  - M4 held-tile sync: base tiles swapped by a `sync` re-mask against the current cubes on attach, so cubes and base
//    content stay consistent. Resume: since.tiles.surface = held versions (LiveSubscribe), same epoch → deltas only.
// Logs: layerb_first, layerb_stats (every 30 s), layerb_gap, layerb_refetch.
import Foundation
import Metal
import QuartzCore
import RealityKit
import UIKit
import SnailSightCore

final class LayerBClient {
    private unowned let model: AppModel
    private(set) var store = LayerBStore()
    /// Bumped when anything drawn changed (Map ▸ 3D re-clones).
    private(set) var rev = 0
    private var entities: [String: ModelEntity] = [:]
    private var full: [String: (mesh: FlatMesh, rgb: [UInt8]?)] = [:]      // the tile's surface (unmasked)
    private var deviceMasks: [String: [Bool]] = [:]
    private var refetching = Set<String>()
    private var stats = (frames: 0, blocks: 0, removed: 0, gaps: 0, refetches: 0, buildMs: 0.0, lagMs: [Double]())
    private var lastStats: TimeInterval = 0
    private var firstLogged = false
    private var drawnColour: MeshColour?
    private var shownLive: Bool?
    /// 12.20: lag counts only frames that carry a NEWER capture for the tile (12.19 p50 39 s = a repeated old hw_wall).
    private var freshLag = FreshLag()
    private var drawnLive: Bool?
    private var lastEvict: TimeInterval = 0
    private(set) var evicted = 0

    init(model: AppModel) { self.model = model }

    private var layer: MapARLayer { model.controller.mapLayer }
    private var now: TimeInterval { Date().timeIntervalSince1970 }

    var surfaceKeys: Set<String> { Set(store.tiles.values.filter { $0.surfaceCount > 0 }.map(\.key)) }

    /// `since.tiles` entries for the subscribe ("surface:<key>" form).
    var heldSince: [String: TileVer] {
        Dictionary(uniqueKeysWithValues: store.held.map { ("surface:" + $0.key, $0.value) })
    }

    func setEpoch(_ e: String?) {
        let before = store.blockCount
        store.setEpoch(e)
        if before > 0 && store.blockCount == 0 { clearDrawn() }
    }

    /// The AR tick (2 Hz): Mesh colour / Mesh (live) switches.
    func tick() {
        layer.blockNode.isEnabled = model.drawMeshLive || model.liveMapView        // 12.21 live view shows it
        let on = model.meshLive || model.liveMapView
        if shownLive != on {
            shownLive = on
            layer.tiles.remaskAll()                                    // Layer B off = base everywhere again
        }
        if drawnColour != model.meshColour || drawnLive != model.liveMapView {
            drawnColour = model.meshColour
            drawnLive = model.liveMapView
            for k in full.keys { draw(k) }
        }
        if now - lastEvict >= 2 { lastEvict = now; evictFar() }
        maybeLog()
    }

    // MARK: 12.20 memory: Layer B tiles near you only

    var estimatedBytes: Int {
        var n = store.estimatedBytes
        for f in full.values {
            n += (f.mesh.positions.count + f.mesh.indices.count) * 8
            n += f.rgb?.count ?? 0
        }
        return n
    }

    private func evictFar() {
        guard let c = layer.cameraMap, !store.tiles.isEmpty else { return }
        let p = model.memPlan
        let radius = max(p.layerBRadiusM, model.liveMap.bboxHalf * 1.42 + 4)
        var lru = SpatialLRU<String>()
        for k in store.tiles.keys { if let ce = store.centre(k) { lru.put(k, x: ce.x, y: ce.y, bytes: 0, now: 0) } }
        let drop = lru.evictions(x: c[0], y: c[1], radius: radius, maxCount: p.layerBMaxTiles)
        guard !drop.isEmpty else { return }
        var changed = Set<BlockKey>()
        for k in drop {
            changed.formUnion(store.forget(k))
            entities.removeValue(forKey: k)?.removeFromParent()
            full[k] = nil
            deviceMasks[k] = nil
            freshLag.forget(k)
            layer.surface.unregister(id: "blk|" + k)
            evicted += 1
        }
        let sq = squares(of: changed, blockM: store.blockM)
        layer.tiles.blocksChanged(squares: sq)
        model.map3DBlocksChanged(squares: sq)
        rev &+= 1
    }

    // MARK: frames

    /// A downlink text frame with layer `surface` (LiveMapClient). Returns true when it was one.
    @discardableResult
    func handle(_ d: Data) -> Bool {
        guard SurfaceFrame.isSurface(d), let f = SurfaceFrame.parse(d) else { return false }
        apply(f, refetched: false)
        return true
    }

    private func apply(_ f: SurfaceFrame, refetched: Bool) {
        let t = now
        stats.frames += 1
        switch store.apply(f, now: t) {
        case .gap(let held, let since):
            stats.gaps += 1
            model.log.event("layerb_gap", ["key": .string(f.key), "held": .int(held ?? -1), "since": .int(since)])
            refetch(f.key, level: f.level, tx: f.tx, ty: f.ty)
        case .applied(let changed, let wasFull):
            stats.blocks += f.blocks.count
            stats.removed += f.removed.count
            let t0 = CACurrentMediaTime()
            if let m = store.tileMesh(f.key) { full[f.key] = (m.mesh, m.rgb) }
            deviceMasks[f.key] = nil
            draw(f.key)
            if let m = full[f.key] {                                   // device surface wins near you
                layer.surface.register(id: "blk|" + f.key,
                                       centroids: CoveredFaces.centroids(positions: m.mesh.positions, indices: m.mesh.indices)) { [weak self] hidden, n in
                    guard let self, let cur = self.full[f.key], cur.mesh.triangleCount == hidden.count || n == 0 else { return }
                    self.deviceMasks[f.key] = n > 0 ? hidden : nil
                    self.draw(f.key)
                }
            }
            stats.buildMs += (CACurrentMediaTime() - t0) * 1000
            // base tiles touching the changed cubes re-mask
            let sq = squares(of: changed, blockM: store.blockM)
            layer.tiles.blocksChanged(squares: sq)
            model.map3DBlocksChanged(squares: sq)
            // the Map: a top-down raster of the tile like the live mesh tiles
            if let m = full[f.key] {
                var h = LiveTileHeader(layer: "surface", key: f.key, level: f.level, tx: f.tx, ty: f.ty, ver: f.ver,
                                       origin: [Double(f.tx) * 4, Double(f.ty) * 4], sizeM: 4)
                h.hw = Dictionary(uniqueKeysWithValues: f.agents.map { ("\($0)/surface", 0) })
                model.meshStore.applyLive(h, mesh: m.mesh, rgb: m.rgb, floorZ: nil, me: model.agentID)
            }
            if let w = f.hwWall {
                let fresh = freshLag.lag(key: f.key, hwWall: w, now: t)
                if let lag = fresh { stats.lagMs.append(lag) }
                if fresh != nil, f.agents.contains(model.agentID) {                  // M0: our own keyframe reached the screen
                    model.liveStages.tileArrived(hwWall: w, now: t)
                    model.liveStages.tileDrawn(hwWall: w, now: now)
                    model.liveStagesChanged()
                }
            }
            rev &+= 1
            if !firstLogged {
                firstLogged = true
                model.log.event("layerb_first", ["key": .string(f.key), "blocks": .int(f.blocks.count), "full": .bool(wasFull),
                                                 "surface_blocks": .int(store.surfaceBlocks), "refetched": .bool(refetched)])
            }
        }
    }

    private func squares(of keys: Set<BlockKey>, blockM m: Double) -> [[Double]] {
        var tiles = Set<String>()
        var out: [[Double]] = []
        for k in keys {
            let tx = Int((Double(k.x) * m / 4).rounded(.down)), ty = Int((Double(k.y) * m / 4).rounded(.down))
            if tiles.insert("\(tx)/\(ty)").inserted { out.append([Double(tx) * 4, Double(ty) * 4, Double(tx + 1) * 4, Double(ty + 1) * 4]) }
        }
        return out
    }

    /// A missed delta: GET the tile in full and apply it.
    private func refetch(_ key: String, level: Int, tx: Int, ty: Int) {
        guard !refetching.contains(key), let link = model.link else { return }
        refetching.insert(key)
        stats.refetches += 1
        let map = model.liveMapID
        Task { [weak self] in
            var frame: SurfaceFrame?
            var status = 0
            if let r = try? await link.request("GET", "/v1/live/surface/\(level)/\(tx)/\(ty)",
                                               query: [URLQueryItem(name: "map_id", value: map),
                                                       URLQueryItem(name: "transport", value: "json")], timeout: 20) {
                status = r.1
                if r.1 == 200 { frame = SurfaceFrame.parse(r.0) }
            }
            let fr = frame, st = status
            await MainActor.run {
                guard let self else { return }
                self.refetching.remove(key)
                self.model.log.event("layerb_refetch", ["key": .string(key), "status": .int(st), "ok": .bool(fr != nil)])
                if var f = fr {
                    f.since = nil                                       // a full tile replaces what we hold
                    self.apply(f, refetched: true)
                }
            }
        }
    }

    // MARK: drawing

    private static let wire: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1))
        if #available(iOS 18.0, *) {
            m.triangleFillMode = .lines
            m.blending = .transparent(opacity: 0.45)
        } else {
            m.blending = .transparent(opacity: 0.2)
        }
        return m
    }()

    private func draw(_ key: String) {
        guard let f = full[key] else { return }
        var m = f.mesh
        if !model.liveMapView, let mask = deviceMasks[key], mask.count == m.triangleCount {   // 12.21: live view shows all
            var idx = [UInt32]()
            idx.reserveCapacity(m.indices.count)
            for i in 0..<mask.count where !mask[i] { idx.append(m.indices[i * 3]); idx.append(m.indices[i * 3 + 1]); idx.append(m.indices[i * 3 + 2]) }
            m = FlatMesh(positions: m.positions, indices: idx)
        }
        guard m.triangleCount > 0,
              let ent = Self.entity(m, rgb: f.rgb, photo: model.meshColour == .photo, live: model.liveMapView) else {
            entities.removeValue(forKey: key)?.removeFromParent()
            return
        }
        entities.removeValue(forKey: key)?.removeFromParent()
        ent.name = "blk.\(key)"
        layer.blockNode.addChild(ent)
        entities[key] = ent
    }

    /// One tile's surface as an entity: flat photo colour per triangle (one texel each) or the wire look.
    static func entity(_ m: FlatMesh, rgb: [UInt8]?, photo: Bool, live: Bool = false) -> ModelEntity? {
        var d = MeshDescriptor(name: "layerb")
        var mat: any RealityKit.Material = wire
        // 12.21 Live map view: solid + shaded high-contrast faces (LiveViewLook); else photo strip or the blue wire
        let strip: LiveMeshTile.FaceTextured? = live ? LiveMeshTile.faceTextured(m, faceRGB: LiveViewLook.faceColours(m, rgb: rgb))
            : (photo ? rgb.flatMap { LiveMeshTile.faceTextured(m, rgb: $0) } : nil)
        if let ft = strip, let img = stripImage(ft.rgba, w: ft.width, h: ft.rows),
           let tex = try? TextureResource.generate(from: img, options: .init(semantic: .color, mipmapsMode: .none)) {
            var pos = [SIMD3<Float>](), uv = [SIMD2<Float>]()
            var i = 0
            while i + 2 < ft.positions.count { pos.append(SIMD3<Float>(ft.positions[i], ft.positions[i + 1], ft.positions[i + 2])); i += 3 }
            i = 0
            while i + 1 < ft.uvs.count { uv.append(SIMD2<Float>(ft.uvs[i], ft.uvs[i + 1])); i += 2 }
            d.positions = MeshBuffers.Positions(pos)
            d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
            d.primitives = .triangles(ft.indices)
            var u = UnlitMaterial()
            u.color = .init(tint: .white, texture: .init(tex, sampler: nearest))
            mat = u
        } else {
            var pos = [SIMD3<Float>]()
            var i = 0
            while i + 2 < m.positions.count { pos.append(SIMD3<Float>(m.positions[i], m.positions[i + 1], m.positions[i + 2])); i += 3 }
            d.positions = MeshBuffers.Positions(pos)
            d.primitives = .triangles(m.indices)
        }
        guard let res = try? MeshResource.generate(from: [d]) else { return nil }
        return ModelEntity(mesh: res, materials: [mat])
    }

    private static let nearest: MaterialParameters.Texture.Sampler = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .nearest
        d.magFilter = .nearest
        d.mipFilter = .notMipmapped
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        return MaterialParameters.Texture.Sampler(d)
    }()

    private static func stripImage(_ px: [UInt8], w: Int, h: Int) -> CGImage? {
        guard w > 0, h > 0, px.count == w * h * 4, let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Map ▸ 3D: every tile's full surface (no device view there).
    func map3DSources() -> [Entity] {
        full.compactMap { k, f in
            guard f.mesh.triangleCount > 0 else { return nil }
            if deviceMasks[k] == nil || model.liveMapView, let e = entities[k] { return e.clone(recursive: true) }
            return Self.entity(f.mesh, rgb: f.rgb, photo: model.meshColour == .photo, live: model.liveMapView)
        }
    }

    private func clearDrawn() {
        for e in entities.values { e.removeFromParent() }
        for k in entities.keys { layer.surface.unregister(id: "blk|" + k) }
        entities.removeAll()
        full.removeAll()
        deviceMasks.removeAll()
        layer.tiles.remaskAll()
        rev &+= 1
    }

    private func maybeLog() {
        guard now - lastStats >= 30, stats.frames > 0 else { return }
        lastStats = now
        let l = stats.lagMs.sorted()
        model.log.event("layerb_stats", [
            "frames": .int(stats.frames), "blocks": .int(stats.blocks), "removed": .int(stats.removed),
            "gaps": .int(stats.gaps), "refetches": .int(stats.refetches), "tiles": .int(store.tiles.count),
            "surface_blocks": .int(store.surfaceBlocks), "cubes": .int(store.blockCount),
            "build_ms": .double((stats.buildMs * 10).rounded() / 10),
            "lag_ms_p50": .double(l.isEmpty ? -1 : l[l.count / 2].rounded()),
            "lag_ms_max": .double(l.last?.rounded() ?? -1), "lag_n": .int(l.count),
            "evicted": .int(evicted), "mem_mb": .double((Double(estimatedBytes) / 1_048_576 * 10).rounded() / 10),
        ])
        stats = (0, 0, 0, 0, 0, 0, [])
    }
}
