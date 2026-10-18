// SnailSight 12.0 Map (concept A2 + O1): the data behind the full-screen plan.
// - Storeys + floor plans: the shown house version's scene descriptor (`layers.floorplans[]`, API §8.1: per-level clean
//   RGBA plan overlay, 2 cm/px, `bounds_xy`); only the storey on screen is downloaded (cached in Caches/plans/).
// - Cameras / sensors: map entities `?include=placements` (API §5.7a).
// - Yard (outdoor, O1): the robot terrain grid of the entry storey (API §8.10: slope / cost → slope shading + robot
//   no-go) and, when the server has `estimated_world` (API §5.16), the surveyed-vs-estimated coverage mask (estimated =
//   hatched), lidar trees (ghost = estimate only, corrected = a line from the estimate to where our sensors saw it) and
//   the estimated-ground no-go slope. Without §5.16 the Yard says "estimate unavailable" and shows only what we measured.
// - Live mesh: LiveMeshStore (the mesh as it is built, all agents) — read by the view directly.
import Foundation
import UIKit
import SnailSightCore

final class MapPlanData: ObservableObject {
    struct Floorplan: Equatable {
        let level: Int
        let floorZ: Double?
        let url: String
        let bounds: [Double]          // x0, y0, x1, y1
    }

    @Published private(set) var levels: [PlanLevel] = []
    @Published private(set) var floorplans: [Int: Floorplan] = [:]
    @Published private(set) var planImages: [Int: CGImage] = [:]
    @Published private(set) var cameras: [Placement] = []
    @Published private(set) var sceneBounds: [Double]?          // x0, y0, x1, y1 of the house map
    // Yard / terrain
    @Published private(set) var terrainImage: (image: CGImage, bounds: [Double])?
    @Published private(set) var terrainStats: TerrainPlanRaster.Result?
    @Published private(set) var terrainUnknown: (mask: [Bool], nx: Int, ny: Int, x0: Double, y0: Double, cell: Double)?
    // §5.16 estimated world
    @Published private(set) var coverage: CoverageDoc?
    @Published private(set) var coverageImage: (image: CGImage, bounds: [Double])?
    @Published private(set) var estimated: EstimatedDoc?
    @Published private(set) var dem: EstimatedDEM?
    @Published private(set) var noGoImage: (image: CGImage, bounds: [Double])?
    @Published private(set) var estimatedNote: String?

    private unowned let model: AppModel
    private var sceneLoaded: String?
    private var sceneLoading = false
    private var planLoading = Set<Int>()
    private var camerasAt: TimeInterval = 0
    private var estimatedAt: TimeInterval = 0
    private var estimatedLoading = false
    private var terrainKey: String?

    init(model: AppModel) { self.model = model }

    private var layer: MapARLayer { model.controller.mapLayer }
    private var now: TimeInterval { Date().timeIntervalSince1970 }

    /// "site@14": the AR content version, else the followed head.
    var scene: String? {
        if let s = layer.sceneID { return s }
        guard let v = model.mapFollower.followVersion ?? model.liveBaseVersion else { return nil }
        return "\(layer.mapID)@\(v)"
    }

    /// The Map opened / the storey changed: fetch what is missing.
    func refresh(level: PlanLevel?) {
        guard model.serverBase != nil else { return }
        if let s = scene, s != sceneLoaded, !sceneLoading { loadScene(s) }
        if now - camerasAt > 60 { loadCameras() }
        if let l = level?.level { loadPlan(l) }
        if level?.level == nil || model.arTerrain { refreshYard() }
    }

    // MARK: scene descriptor → storeys + floor plans

    private func loadScene(_ scene: String) {
        sceneLoading = true
        let link = model.link!
        let enc = scene.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? scene
        Task { [weak self] in
            let r = try? await link.request("GET", "/v1/scenes/\(enc)", timeout: 20)
            var plans: [Int: Floorplan] = [:]
            var bounds: [Double]?
            if let r, r.1 == 200 {
                let o = JSON.object(r.0)
                if let b = o["bounds"] as? [String: Any], let lo = b["min"] as? [NSNumber], let hi = b["max"] as? [NSNumber],
                   lo.count >= 2, hi.count >= 2 {
                    bounds = [lo[0].doubleValue, lo[1].doubleValue, hi[0].doubleValue, hi[1].doubleValue]
                }
                let layers = o["layers"] as? [String: Any]
                for fp in (layers?["floorplans"] as? [[String: Any]]) ?? [] {
                    guard let lv = (fp["level"] as? NSNumber)?.intValue, let url = fp["url"] as? String,
                          let meta = fp["meta"] as? [String: Any], let bx = meta["bounds_xy"] as? [NSNumber], bx.count == 4
                    else { continue }
                    plans[lv] = Floorplan(level: lv, floorZ: (fp["floor_z"] as? NSNumber)?.doubleValue, url: url,
                                          bounds: bx.map(\.doubleValue))
                }
            }
            let plansF = plans, boundsF = bounds
            await MainActor.run {
                guard let self else { return }
                self.sceneLoading = false
                guard r?.1 == 200 else { return }
                self.sceneLoaded = scene
                self.floorplans = plansF
                self.sceneBounds = boundsF
                self.planImages = [:]
                self.levels = PlanLevels.make(plansF.values.map { (level: $0.level, floorZ: $0.floorZ) }, yard: true)
                self.model.log.event("map_scene", ["scene": .string(scene), "levels": .int(plansF.count)])
            }
        }
    }

    private func loadPlan(_ level: Int) {
        guard planImages[level] == nil, !planLoading.contains(level), let fp = floorplans[level], let scene = sceneLoaded
        else { return }
        planLoading.insert(level)
        let link = model.link!
        Task { [weak self] in
            let fm = FileManager.default
            let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("plans", isDirectory: true)
            if let dir { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            let file = dir?.appendingPathComponent(scene.replacingOccurrences(of: "@", with: "-v") + "-L\(level).png")
            var data = file.flatMap { try? Data(contentsOf: $0) }
            if data == nil, let r = try? await link.request("GET", fp.url, timeout: 60), r.1 == 200 {
                data = r.0
                if let file { try? r.0.write(to: file, options: .atomic) }
            }
            let img = data.flatMap { UIImage(data: $0)?.cgImage }
            await MainActor.run {
                guard let self else { return }
                self.planLoading.remove(level)
                if let img { self.planImages[level] = img }
                self.model.log.event("map_plan", ["scene": .string(scene), "level": .int(level), "ok": .bool(img != nil),
                                                  "bytes": .int(data?.count ?? 0)])
            }
        }
    }

    // MARK: cameras

    /// The sheet's near-you list wants the cameras too (once a minute at most).
    func ensureCameras() {
        if model.serverBase != nil, now - camerasAt > 60 { loadCameras() }
    }

    private func loadCameras() {
        camerasAt = now
        let link = model.link!, map = layer.mapID
        Task { [weak self] in
            let r = try? await link.request("GET", "/v1/maps/\(map)/entities",
                                            query: [URLQueryItem(name: "include", value: "placements")], timeout: 15)
            let list = (r?.1 == 200) ? r.map { PlacementDoc.parse($0.0) } ?? [] : []
            await MainActor.run {
                guard let self else { return }
                if r?.1 == 200 { self.cameras = list }
            }
        }
    }

    // MARK: Yard: measured terrain + the estimated world

    /// The entry storey's robot terrain → O1 colours; the §5.16 coverage / trees / estimated slopes around the house.
    func refreshYard() {
        let entry = PlanLevels.entry(levels)?.level ?? 1
        if let g = model.terrainLayer.grid(level: entry) {
            let key = "\(scene ?? "?")-L\(entry)"
            if key != terrainKey {
                terrainKey = key
                let r = TerrainPlanRaster.build(g)
                let b = [g.x0, g.y0, g.x0 + Double(g.nx) * g.cell, g.y0 + Double(g.ny) * g.cell]
                if let img = LiveMeshStore.rgbaImage(r.rgba, w: r.nx, h: r.ny) { terrainImage = (img, b) }
                terrainStats = r
                terrainUnknown = (TerrainPlanRaster.unknownMask(g), g.nx, g.ny, g.x0, g.y0, g.cell)
                model.log.event("map_terrain", ["level": .int(entry), "surveyed": .int(r.surveyed), "unknown": .int(r.unknown),
                                                "nogo": .int(r.noGo)])
            }
        }
        guard model.serverFeatures.estimatedWorld else {
            estimatedNote = "Estimate unavailable: the map server has no estimated world yet (showing measured ground only)"
            return
        }
        if now - estimatedAt > 120 && !estimatedLoading { loadEstimated() }
    }

    /// The area the Yard asks the estimate for: the house map ± 25 m (inside the server's 300 m extent).
    private var yardBBox: [Double] {
        let b = sceneBounds ?? [-30, -36, 15, 12]
        return [b[0] - 25, b[1] - 25, b[2] + 25, b[3] + 25].map { ($0 * 2).rounded() / 2 }
    }

    private func loadEstimated() {
        estimatedLoading = true
        estimatedAt = now
        let link = model.link!, map = layer.mapID
        let bb = yardBBox.map { String(format: "%.1f", $0) }.joined(separator: ",")
        Task { [weak self] in
            let c = try? await link.request("GET", "/v1/maps/\(map)/estimated/coverage",
                                            query: [URLQueryItem(name: "bbox", value: bb), URLQueryItem(name: "mask", value: "1")],
                                            timeout: 30)
            let e = try? await link.request("GET", "/v1/maps/\(map)/estimated",
                                            query: [URLQueryItem(name: "bbox", value: bb), URLQueryItem(name: "dem", value: "1")],
                                            timeout: 30)
            let cov = (c?.1 == 200) ? c.flatMap { CoverageDoc.parse($0.0) } : nil
            let est = (e?.1 == 200) ? e.flatMap { EstimatedDoc.parse($0.0) } : nil
            let grid = cov?.grid
            let covImg = grid.flatMap { g -> (CGImage, [Double])? in
                guard let img = LiveMeshStore.rgbaImage(g.rgba(), w: g.w, h: g.h) else { return nil }
                return (img, [g.origin[0], g.origin[1], g.origin[0] + Double(g.w) * g.res, g.origin[1] + Double(g.h) * g.res])
            }
            let dem = est?.dem.flatMap(EstimatedDEM.init)
            let ngImg = dem.flatMap { d -> (CGImage, [Double])? in
                guard let img = LiveMeshStore.rgbaImage(d.noGoRGBA(coverage: grid), w: d.w, h: d.h) else { return nil }
                return (img, [d.origin[0], d.origin[1], d.origin[0] + Double(d.w) * d.res, d.origin[1] + Double(d.h) * d.res])
            }
            await MainActor.run {
                guard let self else { return }
                self.estimatedLoading = false
                if let cov { self.coverage = cov }
                if let covImg { self.coverageImage = covImg }
                if let est { self.estimated = est }
                if let dem { self.dem = dem }
                if let ngImg { self.noGoImage = ngImg }
                self.estimatedNote = (cov == nil && est == nil) ? "Estimate unavailable right now (map server \(c?.1 ?? 0))" : nil
                self.model.log.event("map_estimated", ["coverage": .int(c?.1 ?? 0), "trees": .int(est?.trees.count ?? -1),
                                                       "corrected": .int(est?.correctedCount ?? -1),
                                                       "surveyed_frac": .double(cov?.surveyedFrac ?? -1)])
            }
        }
    }

    /// Downlink `estimated` message: tree status changes (corrected trees are "corrected for everyone") → toast + refetch.
    func estimatedLive(_ m: EstimatedLiveMessage) {
        let evs = m.events ?? []
        if let e = evs.last(where: { $0.kind == "tree_status" }), model.showMap || model.serverSim.ui.selection?.drone == true {
            model.flash(e.text, seconds: 3)
        }
        model.log.event("estimated_live", ["rev": .int(m.rev ?? -1), "events": .int(evs.count),
                                           "coverage_changed": .bool(m.coverageChanged ?? false)])
        if !evs.isEmpty || m.coverageChanged == true { estimatedAt = 0 }      // refetch on the next Yard refresh
        if model.showMap { refreshYard() }
    }

    /// Canopy / ground lookups for the O2 altitude strip (estimated DEM, else the measured terrain elevation).
    func groundZ(x: Double, y: Double) -> Double? {
        if let d = dem, let z = d.ground(x: x, y: y) { return z }
        return nil
    }

    func canopyZ(x: Double, y: Double) -> Double? { dem?.canopy(x: x, y: y) }

    /// Explore gaps: the biggest unmeasured area next to measured ground (terrain grid), as a map xy goal.
    func gapGoal() -> GapFinder.Gap? {
        if let g = coverage?.grid {                     // §5.16: estimated-only ground next to surveyed ground
            let unknown = g.values.map { $0 == CoverageGrid.Cls.estimated.rawValue }
            let known = g.values.map { $0 == CoverageGrid.Cls.surveyed.rawValue }
            if let gap = GapFinder.find(nx: g.w, ny: g.h, x0: g.origin[0], y0: g.origin[1], cell: g.res, unknown: unknown,
                                        known: known, minCells: 40) { return gap }
        }
        guard let u = terrainUnknown else { return nil }
        let known = u.mask.indices.map { _ in false }
        var unknownGrid = known, knownGrid = known
        // the mask is in image order (row 0 = max y): back to grid order (row 0 = min y)
        for row in 0..<u.ny {
            for ix in 0..<u.nx {
                let iy = u.ny - 1 - row
                let v = u.mask[row * u.nx + ix]
                unknownGrid[iy * u.nx + ix] = v
                knownGrid[iy * u.nx + ix] = !v
            }
        }
        return GapFinder.find(nx: u.nx, ny: u.ny, x0: u.x0, y0: u.y0, cell: u.cell, unknown: unknownGrid, known: knownGrid,
                              minCells: 40)
    }
}
