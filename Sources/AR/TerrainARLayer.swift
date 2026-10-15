// SnailSight 10.1 P3 in AR (plan §7 P3 "phone as mock robot", API §8.10): More ▸ House ▸ Robot terrain colours the
// real floor by RobosnailBob's traversability (green free → amber → orange → red can't stand; unknown left clear),
// 10 cm quads within ~6 m of you, rebuilt as you walk. Tool "Robot path": tap a floor spot → "can the robot go here"
// (nav/query at the spot + a footprint ghost) and the A* path from the robot (the sim robot, else where you stand)
// drawn as a dotted line on the floor (nav/path).
// Data: GET /v1/maps/{map}/nav?version=<the localized version> → the level under you → its grid_map.yaml + .bin
// (cached in Caches/terrain/), parsed by SnailSightCore.TerrainGrid off the main thread.
import ARKit
import RealityKit
import UIKit
import SnailSightCore

final class TerrainARLayer {
    private unowned let model: AppModel
    private var nav: NavDoc?
    private var navKey: String?                 // "site@10"
    private var navLoading = false
    private var navFailedAt: TimeInterval = 0
    private var grids: [Int: TerrainGrid] = [:]   // level → grid (of navKey)
    private var gridLoading = Set<Int>()
    private var patchCenter: [Double]?
    private var patchLevel: Int?
    private var building = false
    private var patchEntities: [ModelEntity] = []
    private var pathEntities: [Entity] = []
    private var pathBusy = false

    static let cacheKeep = 6

    init(model: AppModel) { self.model = model }

    private var layer: MapARLayer { model.controller.mapLayer }

    private static func material(_ c: TerrainClass) -> UnlitMaterial {
        let (r, g, b) = c.rgb
        var m = UnlitMaterial(color: UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1))
        m.blending = .transparent(opacity: 0.38)
        return m
    }

    // MARK: overlay (MapARLayer.slowTick, every 0.5 s while aligned)

    func tick(cameraMap cam: [Double]) {
        let on = model.arTerrain
        layer.terrainNode.isEnabled = on
        guard on, let v = layer.mapVersion, model.serverBase != nil else { return }
        let key = "\(layer.mapID)@\(v)"
        if key != navKey { resetFor(key) }
        guard let nav else { loadNav(v); return }
        guard let L = nav.level(x: cam[0], y: cam[1], cameraZ: cam[2]) else { return }
        guard let g = grids[L.level] else { loadGrid(L, key: key); return }
        guard !building, L.level != patchLevel || TerrainPatch.needsRebuild(last: patchCenter, x: cam[0], y: cam[1]) else { return }
        building = true
        let cx = cam[0], cy = cam[1], level = L.level
        Task.detached(priority: .utility) { [weak self] in
            let r = TerrainPatch.build(g, cx: cx, cy: cy, radius: 6, block: 2)
            await MainActor.run {
                guard let self else { return }
                self.building = false
                guard self.navKey == key else { return }
                self.show(r)
                self.patchCenter = [cx, cy]
                self.patchLevel = level
            }
        }
    }

    private func resetFor(_ key: String) {
        navKey = key
        nav = nil
        grids = [:]
        gridLoading = []
        patchCenter = nil
        patchLevel = nil
        for e in patchEntities { e.removeFromParent() }
        patchEntities = []
    }

    private func show(_ r: TerrainPatch.Result) {
        for e in patchEntities { e.removeFromParent() }
        patchEntities = []
        for cls in TerrainClass.allCases {
            guard let m = r.meshes[cls], m.triangleCount > 0 else { continue }
            var pos = [SIMD3<Float>]()
            pos.reserveCapacity(m.vertexCount)
            var i = 0
            while i + 2 < m.positions.count {
                pos.append(SIMD3<Float>(m.positions[i], m.positions[i + 1], m.positions[i + 2]))
                i += 3
            }
            var d = MeshDescriptor(name: "terrain")
            d.positions = MeshBuffers.Positions(pos)
            d.primitives = .triangles(m.indices)
            guard let res = try? MeshResource.generate(from: [d]) else { continue }
            let e = ModelEntity(mesh: res, materials: [Self.material(cls)])
            layer.terrainNode.addChild(e)
            patchEntities.append(e)
        }
    }

    private func loadNav(_ v: Int) {
        let now = Date().timeIntervalSince1970
        guard !navLoading, now - navFailedAt > 30 else { return }
        navLoading = true
        let link = model.link!, map = layer.mapID, key = navKey
        Task { [weak self] in
            let r = try? await link.request("GET", "/v1/maps/\(map)/nav", query: [URLQueryItem(name: "version", value: String(v))],
                                            timeout: 20)
            let doc = (r?.1 == 200) ? r.flatMap { try? JSONDecoder().decode(NavDoc.self, from: $0.0) } : nil
            await MainActor.run {
                guard let self else { return }
                self.navLoading = false
                guard self.navKey == key else { return }
                if let doc { self.nav = doc } else {
                    self.navFailedAt = Date().timeIntervalSince1970
                    self.model.log.event("terrain_nav_error", ["status": .int(r?.1 ?? 0), "version": .int(v)])
                    if r?.1 == 404 { self.model.flash("No robot terrain for house map v\(v) yet", seconds: 2.5) }
                }
            }
        }
    }

    private func loadGrid(_ L: NavLevel, key: String) {
        guard !gridLoading.contains(L.level), let bin = L.gridMap?.bin, let b = L.boundsXY, b.count == 4,
              let shape = L.shape, shape.count == 2, let cell = nav?.cellM else { return }
        gridLoading.insert(L.level)
        let link = model.link!, yaml = L.gridMap?.yaml, level = L.level
        Task { [weak self] in
            let fm = FileManager.default
            let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("terrain", isDirectory: true)
            if let dir { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            let file = dir?.appendingPathComponent(key.replacingOccurrences(of: "@", with: "-v") + "-L\(level).bin")
            var data = file.flatMap { try? Data(contentsOf: $0) }
            if data == nil, let r = try? await link.request("GET", bin, timeout: 90), r.1 == 200 {
                data = r.0
                if let file { try? r.0.write(to: file, options: .atomic) }
                if let dir { TerrainARLayer.trim(dir) }
            }
            var names = GridMapYAML.defaultLayers
            if let y = yaml, let r = try? await link.request("GET", y, timeout: 20), r.1 == 200 {
                names = GridMapYAML.layers(String(decoding: r.0, as: UTF8.self))
            }
            let grid = data.flatMap {
                TerrainGrid.parse(bin: $0, nx: shape[0], ny: shape[1], x0: b[0], y0: b[1], cell: cell, layerNames: names)
            }
            await MainActor.run {
                guard let self else { return }
                self.gridLoading.remove(level)
                guard self.navKey == key else { return }
                if let grid { self.grids[level] = grid }
                self.model.log.event("terrain_grid", ["scene": .string(key), "level": .int(level), "ok": .bool(grid != nil),
                                                      "bytes": .int(data?.count ?? 0)])
            }
        }
    }

    private static func trim(_ dir: URL) {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let old = all.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.dropFirst(cacheKeep)
        for u in old { try? fm.removeItem(at: u) }
    }

    // MARK: tool "Robot path"

    /// Tap → query the spot + plan from the robot (sim robot, else the floor under the phone). true = handled.
    func handleTap(_ pt: CGPoint, arView: ARView) -> Bool {
        guard layer.isAligned, let v = layer.mapVersion else {
            model.flash("Robot path needs LOCALIZED in the house map")
            return true
        }
        guard let hit = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .horizontal).first,
              let goal = layer.toMap(world: Geo.position(hit.worldTransform)), let cam = layer.cameraMap else {
            model.flash("Aim at the floor")
            return true
        }
        guard !pathBusy else { return true }
        pathBusy = true
        var start = [cam[0], cam[1], cam[2] - 1.4]
        if let r = model.controller.sim.robotWorldPosition, let s = layer.toMap(world: r) { start = s }
        if let s = model.serverSim.selectedRoverMap { start = s }
        let link = model.link!, map = layer.mapID
        let req = NavPathRequest(start: start, goal: [goal[0], goal[1]])
        let vq = [URLQueryItem(name: "version", value: String(v))]
        let qq = vq + [URLQueryItem(name: "x", value: String(goal[0])), URLQueryItem(name: "y", value: String(goal[1])),
                       URLQueryItem(name: "z", value: String(goal[2]))]
        Task { [weak self] in
            var query: NavQueryAnswer?
            if let r = try? await link.request("GET", "/v1/maps/\(map)/nav/query", query: qq, timeout: 15), r.1 == 200 {
                query = try? JSONDecoder().decode(NavQueryAnswer.self, from: r.0)
            }
            var path: NavPathAnswer?
            var status = 0
            if let body = try? JSONEncoder().encode(req),
               let r = try? await link.request("POST", "/v1/maps/\(map)/nav/path", query: vq, body: body, timeout: 20) {
                status = r.1
                if r.1 == 200 { path = try? JSONDecoder().decode(NavPathAnswer.self, from: r.0) }
            }
            let qF = query, pF = path, stF = status
            await MainActor.run {
                guard let self else { return }
                self.pathBusy = false
                self.drawResult(goal: goal, query: qF, path: pF)
                let text = [qF?.text, pF?.text ?? (stF == 404 ? "No robot terrain here yet" : nil)].compactMap { $0 }
                    .joined(separator: "\n")
                self.model.flash(text.isEmpty ? "The map server did not answer" : text, seconds: 4)
                self.model.log.event("terrain_path", ["ok": .bool(pF?.ok ?? false), "len_m": .double(pF?.lengthM ?? -1),
                                                      "status": .int(stF), "traversable": .bool(qF?.traversable ?? false),
                                                      "goal": .doubles(goal)])
            }
        }
        return true
    }

    func clearPath() {
        for e in pathEntities { e.removeFromParent() }
        pathEntities = []
    }

    private func drawResult(goal: [Double], query: NavQueryAnswer?, path: NavPathAnswer?) {
        clearPath()
        let node = layer.pathNode
        // footprint ghost at the goal (RobosnailBob 0.82 × 0.62 m), green if it can stand there, red if not
        let ok = query?.traversable ?? false
        var fm = UnlitMaterial(color: ok ? UIColor(red: 0.2, green: 0.8, blue: 0.35, alpha: 1)
                                        : UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        fm.blending = .transparent(opacity: 0.45)
        let foot = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.82, 0.62, 0.02), cornerRadius: 0.01), materials: [fm])
        let gz = query?.elevation ?? goal[2]
        foot.position = SIMD3<Float>(Float(goal[0]), Float(goal[1]), Float(gz) + 0.03)
        node.addChild(foot)
        pathEntities.append(foot)
        guard let p = path, p.ok else { return }
        let dot = UnlitMaterial(color: UIColor(red: 0.3, green: 0.95, blue: 1, alpha: 1))
        let mesh = MeshResource.generateSphere(radius: 0.025)
        for q in p.dense(spacing: 0.15).prefix(400) {
            let e = ModelEntity(mesh: mesh, materials: [dot])
            e.position = SIMD3<Float>(Float(q[0]), Float(q[1]), Float(q.count > 2 ? q[2] : gz) + 0.04)
            node.addChild(e)
            pathEntities.append(e)
        }
    }
}
