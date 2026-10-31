import XCTest
@testable import SnailSightCore

/// 12.20 memory budgets (owner report 2026-10-30, app 12.19.305 killed by jetsam after 130 s of walking with Live map).
final class MemoryBudgetTests: XCTestCase {

    // MARK: governor

    func testThresholdsFollowTargetAndLimit() {
        let g = MemoryGovernor()
        let th = g.thresholds(limitMB: 3376)                      // the owner's iPhone16,2
        XCTAssertEqual(th.shed, 1800, accuracy: 0.1)              // min(1800, 0.55 * 3376 = 1857)
        XCTAssertEqual(th.trim, 1530, accuracy: 0.1)
        XCTAssertEqual(th.critical, 2400, accuracy: 0.1)          // min(1800 + 600, 0.75 * 3376 = 2532)
        let small = g.thresholds(limitMB: 2000)                   // a smaller phone: shares of its limit
        XCTAssertEqual(small.shed, 1100, accuracy: 0.1)
        XCTAssertEqual(small.critical, 1500, accuracy: 0.1)
        XCTAssertLessThan(small.trim, small.shed)
    }

    func testRaisesAtOnceLowersOneStepAfterHoldWithHysteresis() {
        var g = MemoryGovernor()
        XCTAssertEqual(g.update(footprintMB: 900, limitMB: 3376, now: 0), .normal)
        XCTAssertEqual(g.update(footprintMB: 2500, limitMB: 3376, now: 1), .critical)        // at once
        // just under the critical threshold: no drop (hysteresis 150 MB)
        for t in 2...40 { g.update(footprintMB: 2350, limitMB: 3376, now: Double(t)) }
        XCTAssertEqual(g.level, .critical)
        // clearly under: one step per 20 s hold, never two at once
        g.update(footprintMB: 1000, limitMB: 3376, now: 41)
        g.update(footprintMB: 1000, limitMB: 3376, now: 60)
        XCTAssertEqual(g.level, .critical)
        g.update(footprintMB: 1000, limitMB: 3376, now: 61)
        XCTAssertEqual(g.level, .shed)
        g.update(footprintMB: 1000, limitMB: 3376, now: 81)
        XCTAssertEqual(g.level, .trim)
        g.update(footprintMB: 1000, limitMB: 3376, now: 101)
        XCTAssertEqual(g.level, .normal)
        XCTAssertEqual(g.peakLevel, .critical)
    }

    func testMemoryWarningAlwaysSheds() {
        var g = MemoryGovernor()
        XCTAssertEqual(g.warning(now: 0), .shed)                  // 12.19: 38 warnings shed nothing
        XCTAssertEqual(g.warning(now: 5), .shed)
        XCTAssertEqual(g.warning(now: 10), .critical)             // 3 inside a minute
        // with a recent warning the level never drops below trim, even with a low footprint
        for t in 11...69 { g.update(footprintMB: 800, limitMB: 3376, now: Double(t)) }
        XCTAssertGreaterThanOrEqual(g.level, .trim)
    }

    /// The real 12.19 session (footprint every 10 s + every iOS memory warning, numbers only): the governor reaches
    /// `shed` at 31 s, 55 s before iOS's first warning, and `critical` by the warning burst.
    func testRealSessionFootprintReplay() {
        let mem: [(Double, Double)] = [(1.08, 501.7), (11.07, 847.9), (21.07, 960.1), (31.07, 1876.9), (41.08, 1883.1),
                                       (51.1, 1924.4), (61.12, 1971.3), (71.1, 2091), (81.12, 2203.4), (91.12, 2447),
                                       (101.13, 2403.5), (111.14, 2794.1), (121.12, 2477)]
        let warn: [Double] = [86.38, 86.5, 89.53, 89.73, 89.92, 98.53, 111.14, 111.21, 111.3]
        var g = MemoryGovernor()
        var firstShed: Double?, firstCritical: Double?
        var events = mem.map { ($0.0, $0.1, false) } + warn.map { ($0, 0.0, true) }
        events.sort { $0.0 < $1.0 }
        for (t, f, w) in events {
            if w { g.warning(now: t) } else { g.update(footprintMB: f, limitMB: 3376, now: t) }
            if firstShed == nil, g.level >= .shed { firstShed = t }
            if firstCritical == nil, g.level == .critical { firstCritical = t }
        }
        XCTAssertEqual(firstShed ?? -1, 31.07, accuracy: 0.01)
        XCTAssertLessThan(firstShed!, warn[0] - 50)
        XCTAssertNotNil(firstCritical)
        XCTAssertLessThanOrEqual(firstCritical!, 89.6)
    }

    // MARK: plan

    func testPlanTightensMonotonically() {
        for th in ThermalLevel.allCases {
            for w in [false, true] {
                let ps = MemLevel.allCases.map { MemPlan.plan(level: $0, thermal: th, walking: w) }
                for (a, b) in zip(ps, ps.dropFirst()) {
                    XCTAssertLessThanOrEqual(b.tileNearMB, a.tileNearMB)
                    XCTAssertLessThanOrEqual(b.tileMidMB, a.tileMidMB)
                    XCTAssertLessThanOrEqual(b.tileLingerMB, a.tileLingerMB)
                    XCTAssertLessThanOrEqual(b.tileConcurrent, a.tileConcurrent)
                    XCTAssertLessThanOrEqual(b.liveRadiusM, a.liveRadiusM)
                    XCTAssertLessThanOrEqual(b.liveMaxTiles, a.liveMaxTiles)
                    XCTAssertLessThanOrEqual(b.layerBMaxTiles, a.layerBMaxTiles)
                    XCTAssertLessThanOrEqual(b.deviceCellsMax, a.deviceCellsMax)
                    XCTAssertLessThanOrEqual(b.deviceKeepRadiusM, a.deviceKeepRadiusM)
                    XCTAssertGreaterThanOrEqual(b.deviceEveryS, a.deviceEveryS)
                    XCTAssertGreaterThanOrEqual(b.maskRebuildMinS, a.maskRebuildMinS)
                    XCTAssertLessThanOrEqual(b.overlayMaxVertices, a.overlayMaxVertices)
                    XCTAssertLessThanOrEqual(b.arMeshVertexCap, a.arMeshVertexCap)
                    XCTAssertFalse(b.environmentProbes && !a.environmentProbes)
                }
            }
        }
    }

    func testThermalSeriousStepsWorkDownAndActionsAreNamed() {
        let n = MemPlan.plan(level: .normal, thermal: .nominal)
        XCTAssertEqual(n.actions, [])
        XCTAssertTrue(n.environmentProbes)
        XCTAssertFalse(MemPlan.plan(level: .normal, thermal: .nominal, walking: true).environmentProbes)
        let hot = MemPlan.plan(level: .normal, thermal: .serious)
        XCTAssertEqual(hot.deviceEveryS, 1.2)                     // 3x slower depth marking
        XCTAssertEqual(hot.maskRebuildMinS, 4)
        XCTAssertEqual(hot.tileConcurrent, 1)
        XCTAssertFalse(hot.environmentProbes)
        XCTAssertTrue(hot.actions.contains("device_every_1.2s"))
        let shed = MemPlan.plan(level: .shed, thermal: .nominal)
        XCTAssertEqual(Array(shed.actions.prefix(3)), ["env_probes_off", "tile_linger_off", "sim_templates_unused"])
        XCTAssertTrue(shed.actions.contains("ar_mesh_cap_250k"))
        XCTAssertTrue(shed.actions.contains("overlay_120k"))
        let crit = MemPlan.plan(level: .critical, thermal: .nominal)
        XCTAssertTrue(crit.actions.contains("ar_mesh_reset"))
        XCTAssertTrue(crit.actions.contains("overlay_off"))
        XCTAssertTrue(crit.actions.contains("sim_templates_all"))
    }

    // MARK: spatial LRU

    func testSpatialLRUEvictsFarFirstThenFarthestOverCount() {
        var l = SpatialLRU<String>()
        for i in 0..<10 { l.put("t\(i)", x: Double(i) * 4, y: 0, bytes: 100, now: Double(i)) }
        XCTAssertEqual(l.totalBytes, 1000)
        // beyond 20 m of x = 0: t6..t9 (24..36 m)
        XCTAssertEqual(Set(l.evictions(x: 0, y: 0, radius: 20, maxCount: 100)), ["t6", "t7", "t8", "t9"])
        // count cap 3 inside a huge radius: the farthest go, the nearest 3 stay
        XCTAssertEqual(Set(l.evictions(x: 0, y: 0, radius: 1000, maxCount: 3)), Set((3..<10).map { "t\($0)" }))
        // bytes cap
        XCTAssertEqual(l.evictions(x: 0, y: 0, radius: 1000, maxCount: 100, maxBytes: 850).count, 2)
        // protected never chosen
        XCTAssertFalse(l.evictions(x: 0, y: 0, radius: 1, maxCount: 0, protected: ["t9"]).contains("t9"))
        l.remove("t9")
        XCTAssertEqual(l.totalBytes, 900)
        l.put("t0", x: 0, y: 0, bytes: 50, now: 99)               // replace keeps the total right
        XCTAssertEqual(l.totalBytes, 850)
    }

    // MARK: device-surface grid cap

    /// A synthetic LiDAR frame: camera at (x, 1.4, z) looking along −z, every pixel 2.5 m away.
    static func frame(_ g: inout DeviceCoverageGrid, x: Float, z: Float, stride: Int = 8) {
        let w = 64, h = 48
        let depth = [Float](repeating: 2.5, count: w * h)
        let m: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, 1.4, z, 1]
        g.observe(depth: depth, width: w, height: h, confidence: nil, K: [50, 50, 32, 24], camToWorld: m, stride: stride)
    }

    func testGridPruneKeepsNearCellsAndHiddenFacesStayHidden() {
        var g = DeviceCoverageGrid()
        Self.frame(&g, x: 0, z: 0, stride: 1)
        var cf = CoveredFaces(id: "t", centroids: [0.05, 2.05, 1.45])   // map (x, y, z) -> world (x, z, -y) = (0.05, 1.45, -2.05)
        let al = Align4(x: 0, y: 0, z: 0, yaw: 0)
        cf.update(grid: g, align: al, force: true)
        XCTAssertEqual(cf.hiddenCount, 1)
        for i in 1...60 { Self.frame(&g, x: Float(i), z: 0) }    // walk 60 m along x
        let before = g.count
        XCTAssertGreaterThan(before, 5000)
        let cut = g.prune(x: 60, z: 0, radius: 15, maxCells: before / 3)
        XCTAssertGreaterThan(cut, 0)
        XCTAssertLessThanOrEqual(g.count, Int(Double(before / 3) * 0.8))
        for k in g.cells {                                       // only cells near the camera remain
            let hz = DeviceCoverageGrid.horizontal(k)
            let dx = Float(hz.i) * g.cellM - 60, dz = Float(hz.k) * g.cellM
            XCTAssertLessThanOrEqual((dx * dx + dz * dz).squareRoot(), 15.2)
        }
        cf.update(grid: g, align: al, force: true)                // sticky: the far face stays hidden
        XCTAssertEqual(cf.hiddenCount, 1)
        XCTAssertFalse(g.saturated)
        XCTAssertEqual(g.prune(x: 60, z: 0, radius: 15, maxCells: 10_000_000), 0)   // under the cap: nothing
    }

    // MARK: Layer B / live tile lag

    func testFreshLagIgnoresRepeatedCaptures() {
        var f = FreshLag()
        XCTAssertEqual(f.lag(key: "0/1/2", hwWall: 100, now: 101.5) ?? -1, 1500, accuracy: 0.1)
        // 12.19: the same tile re-sent with its old hw_wall 30 s later is NOT 31 s of lag
        XCTAssertNil(f.lag(key: "0/1/2", hwWall: 100, now: 131))
        XCTAssertNil(f.lag(key: "0/1/2", hwWall: 99, now: 132))
        XCTAssertEqual(f.lag(key: "0/1/2", hwWall: 131, now: 132) ?? -1, 1000, accuracy: 0.1)
        XCTAssertEqual(f.lag(key: "0/1/3", hwWall: 100, now: 100.2) ?? -1, 200, accuracy: 0.1)
        XCTAssertNil(f.lag(key: "x", hwWall: nil, now: 1))
        f.forget("0/1/2")
        XCTAssertNotNil(f.lag(key: "0/1/2", hwWall: 100, now: 101))
    }

    func testLayerBForgetFreesCubesAndHeld() {
        var s = LayerBStore()
        s.setEpoch("e1")
        let blocks = (0..<6).map { SurfaceBlock(key: BlockKey($0, 0, 3), surface: true, rev: 1, tracked: 1, settled: true,
                                                mesh: FlatMesh(positions: [0, 0, 0, 0.1, 0, 0, 0, 0.1, 0], indices: [0, 1, 2]), rgb: nil) }
        let f = SurfaceFrame(key: "0/0/0", level: 0, tx: 0, ty: 0, ver: TileVer(base: 1, seq: 1), since: nil, blockM: 0.4,
                             blocks: blocks, removed: [], hwWall: 1, agents: [], captureToCommitMs: nil)
        _ = s.apply(f, now: 1)
        XCTAssertEqual(s.blockCount, 6)
        XCTAssertGreaterThan(s.estimatedBytes, 0)
        XCTAssertEqual(s.centre("0/0/0")?.x, 2)
        XCTAssertEqual(s.forget("0/0/0").count, 6)
        XCTAssertEqual(s.blockCount, 0)
        XCTAssertTrue(s.held.isEmpty)                             // a resubscribe asks for it in full
    }

    func testLiveTileStoreForget() {
        var s = LiveTileStore()
        XCTAssertTrue(s.accept(layer: "mesh", key: "0/1/1", ver: TileVer(base: 1, seq: 4)))
        XCTAssertFalse(s.accept(layer: "mesh", key: "0/1/1", ver: TileVer(base: 1, seq: 4)))
        s.forget(layer: "mesh", key: "0/1/1")
        XCTAssertTrue(s.since(layer: "mesh").isEmpty)
        XCTAssertTrue(s.accept(layer: "mesh", key: "0/1/1", ver: TileVer(base: 1, seq: 4)))   // drawn again on return
    }

    // MARK: sim blob cache thrash (the 1.39 GB of disk writes)

    static func hex(_ i: Int) -> String { String(repeating: String(format: "%02x", i % 256), count: 32) }

    /// 60 items x (idle + walk 8 MB, thumb 0.1 MB) = ~970 MB of phone blobs: more than the 600 MB budget.
    static func bigCatalog() -> [SimCatalogItem] {
        (0..<60).map { i in
            var it = SimCatalogItem(key: "k\(i)", label: "K\(i)", category: .animal, group: "Wild", symbol: "pawprint",
                                    sizeM: [1, 1, 1], files: ["idle": "k\(i)_idle.usdz", "walk": "k\(i)_walk.usdz"], thumb: "k\(i).png")
            it.blobs = ["k\(i)_idle.usdz": SimBlobRef(sha256: hex(i * 3), bytes: 8 << 20),
                        "k\(i)_walk.usdz": SimBlobRef(sha256: hex(i * 3 + 1), bytes: 8 << 20),
                        "k\(i).png": SimBlobRef(sha256: hex(i * 3 + 2), bytes: 100_000)]
            return it
        }
    }

    struct SimDisk {
        var have: [String: Int] = [:]
        var uses: [String: Double] = [:]
        var exposed: [SimCatalogItem] = []
        var written = 0
        var budget = SimBlobCache.defaultBudget

        /// One SimContentStore.refresh pass (fetch plan -> download -> reconcile -> evict). `legacy` = the 12.19 rule.
        mutating func sync(_ items: [SimCatalogItem], spawned: Set<String>, recents: [String], now: Double, legacy: Bool) -> Int {
            let haveSet = Set(have.keys)
            let changed: Set<String>
            let haveBytes: Int
            if legacy {
                let d = SimContentDiff.diff(old: exposed.filter { $0.blobs != nil }, new: items)
                changed = Set(d.added).union(d.changed)
                haveBytes = have.values.reduce(0, +)
            } else {
                changed = SimBlobCache.mustFetch(prior: exposed, doc: items, hint: [])
                haveBytes = SimBlobCache.referencedBytes(items: items, have: haveSet) { have[$0] ?? 0 }
            }
            let plan = SimBlobCache.fetchPlan(items: items, have: haveSet, haveBytes: haveBytes, spawned: spawned,
                                              changed: changed, recents: recents, budget: budget)
            var fetched = 0
            for m in plan {
                let b = m.ref.bytes ?? 0
                have[m.blob] = b
                uses[m.blob] = now
                fetched += b
            }
            written += fetched
            exposed = SimContent.reconcile(previous: exposed, doc: items, have: Set(have.keys))
            let entries = have.map { SimBlobEntry(name: $0.key, bytes: $0.value, lastUse: uses[$0.key] ?? 0) }
            let keep = Set(recents).union(spawned)
            let drop = SimBlobCache.evict(entries: entries, inUse: SimContent.referenced(items: items + exposed),
                                          protected: SimContent.referenced(items: (items + exposed).filter { keep.contains($0.key) }),
                                          budget: budget)
            for n in drop { have[n] = nil; uses[n] = nil }
            exposed = SimContent.reconcile(previous: exposed, doc: items, have: Set(have.keys))
            return fetched
        }
    }

    func testSimSyncNoLongerThrashes() {
        let items = Self.bigCatalog()
        let spawned: Set<String> = ["k5", "k17", "k40"]
        // 12.19: every sync re-downloads what the previous one evicted
        var old = SimDisk()
        _ = old.sync(items, spawned: spawned, recents: [], now: 0, legacy: true)
        let again = (1...4).map { old.sync(items, spawned: spawned, recents: [], now: Double($0 * 30), legacy: true) }
        XCTAssertTrue(again.allSatisfy { $0 > 300 << 20 }, "legacy re-fetch \(again.map { $0 >> 20 }) MB")
        // 12.20: the first sync fills the budget, later ones fetch nothing; the cache stays under budget
        var new = SimDisk()
        let first = new.sync(items, spawned: spawned, recents: ["k2"], now: 0, legacy: false)
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThanOrEqual(first, SimBlobCache.defaultBudget)
        for i in 1...60 {                                          // 30 min of syncs every 30 s
            XCTAssertEqual(new.sync(items, spawned: spawned, recents: ["k2"], now: Double(i * 30), legacy: false), 0)
        }
        XCTAssertLessThanOrEqual(new.have.values.reduce(0, +), SimBlobCache.defaultBudget)
        for k in spawned.union(["k2"]) { XCTAssertTrue(new.exposed.contains { $0.key == k }) }
        // a real change of an exposed item still comes, even when the cache is full
        var changed = items
        changed[5].blobs?["k5_idle.usdz"] = SimBlobRef(sha256: Self.hex(250), bytes: 8 << 20)
        changed[10].blobs?["k10_idle.usdz"] = SimBlobRef(sha256: Self.hex(251), bytes: 8 << 20)
        XCTAssertEqual(SimBlobCache.mustFetch(prior: new.exposed, doc: changed, hint: []).contains("k5"), true)
        XCTAssertGreaterThan(new.sync(changed, spawned: spawned, recents: ["k2"], now: 2000, legacy: false), 0)
        XCTAssertEqual(new.sync(changed, spawned: spawned, recents: ["k2"], now: 2030, legacy: false), 0)
    }

    // MARK: soak: a 30 min walk with Live map, the sim, Mesh and the device surface on

    /// Footprint model per subsystem (MB). ARKit's own mesh cost is calibrated PESSIMISTICALLY from the 12.19 log:
    /// all residual growth between 41 s and 121 s (+594 MB) charged to its +347 k vertices = 1.7 KB a vertex.
    func testSoakLongWalkPlateausUnderTarget() {
        var gov = MemoryGovernor()
        var plan = MemPlan.plan(level: .normal, thermal: .nominal, walking: true)
        var live = SpatialLRU<String>(), layerB = LayerBStore()
        layerB.setEpoch("e")
        var grid = DeviceCoverageGrid()
        var disk = SimDisk()
        let items = Self.bigCatalog()
        var arVerts = 0, lastReset = -1e9, resets = 0
        var foot: [Double] = []
        var syncBytesAfterFirst = 0
        let limit = 3376.0
        var lbSeq: [String: Int] = [:]
        let pathLen = 160.0                                       // a 50 x 30 m loop (house + yard), 0.5 m/s
        func pos(_ t: Double) -> (Double, Double) {
            var s = (t * 0.5).truncatingRemainder(dividingBy: pathLen)
            if s < 50 { return (s, 0) }; s -= 50
            if s < 30 { return (50, s) }; s -= 30
            if s < 50 { return (50 - s, 30) }; s -= 50
            return (0, 30 - s)
        }
        for step in 0..<1800 {
            let t = Double(step)
            let (x, y) = pos(t)
            // live downlink: ~1 tile / s inside ±12 m (12.19: 122 tiles in 120 s), ~100 KB each held
            let tx = Int(((x + Double((step * 7) % 25) - 12) / 4).rounded(.down)), ty = Int(((y + Double((step * 11) % 25) - 12) / 4).rounded(.down))
            live.put("0/\(tx)/\(ty)", x: (Double(tx) + 0.5) * 4, y: (Double(ty) + 0.5) * 4, bytes: 100_000, now: t)
            if step % 2 == 0 {
                for k in live.evictions(x: x, y: y, radius: max(plan.liveRadiusM, 12 * 1.42 + 4), maxCount: plan.liveMaxTiles) { live.remove(k) }
            }
            // Layer B: a delta every 2 s of 6 blocks in the tile under you
            if step % 2 == 0 {
                let bx = Int((x / 4).rounded(.down)), by = Int((y / 4).rounded(.down)), key = "0/\(bx)/\(by)"
                let seq = (lbSeq[key] ?? 0) + 1
                lbSeq[key] = seq
                let blocks = (0..<6).map { j in SurfaceBlock(key: BlockKey(bx * 10 + (step + j) % 10, by * 10 + j, 3), surface: true, rev: seq,
                                                             tracked: 1, settled: false,
                                                             mesh: FlatMesh(positions: [Float](repeating: 0, count: 300), indices: [UInt32](repeating: 0, count: 300)),
                                                             rgb: [UInt8](repeating: 1, count: 300)) }
                let f = SurfaceFrame(key: key, level: 0, tx: bx, ty: by, ver: TileVer(base: 1, seq: seq), since: seq == 1 ? nil : seq - 1,
                                     blockM: 0.4, blocks: blocks, removed: [], hwWall: t, agents: [], captureToCommitMs: nil)
                _ = layerB.apply(f, now: t)
                var lru = SpatialLRU<String>()
                for k in layerB.tiles.keys { if let c = layerB.centre(k) { lru.put(k, x: c.x, y: c.y, bytes: 0, now: 0) } }
                for k in lru.evictions(x: x, y: y, radius: max(plan.layerBRadiusM, 21), maxCount: plan.layerBMaxTiles) {
                    layerB.forget(k)
                    lbSeq[k] = nil
                }
            }
            // device surface: one depth frame a second (ARKit world x = map x, z = -map y), then the spatial cap
            Self.frame(&grid, x: Float(x), z: Float(-y))
            grid.prune(x: Float(x), z: Float(-y), radius: Float(plan.deviceKeepRadiusM), maxCells: plan.deviceCellsMax)
            // ARKit mesh: grows 4.5 k vertices / s (12.19), reset over the plan's cap (≤ every 30 s)
            arVerts += 4500
            if arVerts > plan.arMeshVertexCap, t - lastReset >= 30 { arVerts = 0; lastReset = t; resets += 1 }
            // sim catalog sync every 30 s (reconnects, catalog events)
            if step % 30 == 0 {
                let b = disk.sync(items, spawned: ["k5", "k17", "k40"], recents: [], now: t, legacy: false)
                if step > 0 { syncBytesAfterFirst += b }
            }
            // footprint = app + tracking 500, base tiles (raw: ~360 MB near you, capped by the plan), mask bookkeeping,
            // live + Layer B + grid, our overlay copies (40 B a vertex), ARKit's mesh, sim templates
            let tilesMB = min(360.0, Double(plan.tileNearMB + plan.tileMidMB)) + 12
            let simMB: Double = plan.simTemplates == .all ? 150 : (plan.simTemplates == .inUse ? 60 : 0)
            let overlay = Double(min(arVerts, plan.overlayMaxVertices)) * 40 / 1_048_576
            let f = 500 + tilesMB + Double(live.totalBytes + layerB.estimatedBytes + grid.estimatedBytes) / 1_048_576
                + overlay + Double(arVerts) * 1700 / 1_048_576 + simMB
            foot.append(f)
            gov.update(footprintMB: f, limitMB: limit, now: t)
            plan = MemPlan.plan(level: gov.level, thermal: step > 600 ? .serious : .fair, walking: true)
        }
        let peak = foot.max()!
        let lastTen = foot.suffix(600), midTen = foot[600..<1200]
        print(String(format: "soak: peak %.0f MB, min 10-20 max %.0f, min 20-30 max %.0f mean %.0f, peak level %@, resets %d, live %d, layerB %d, cells %d, sim re-download %d B",
                     peak, midTen.max()!, lastTen.max()!, lastTen.reduce(0, +) / 600, gov.peakLevel.label, resets, live.count,
                     layerB.tiles.count, grid.count, syncBytesAfterFirst))
        XCTAssertLessThan(peak, gov.thresholds(limitMB: limit).critical, "peak \(Int(peak)) MB")
        XCTAssertLessThan(peak, limit * 0.75)
        XCTAssertLessThanOrEqual(lastTen.max()!, 1850, "steady max \(Int(lastTen.max()!))")
        XCTAssertLessThanOrEqual(lastTen.max()!, midTen.max()! + 50, "plateau, not growth")
        XCTAssertLessThanOrEqual(live.count, MemPlan.plan(level: .normal, thermal: .nominal).liveMaxTiles)
        XCTAssertLessThanOrEqual(layerB.tiles.count, 64)
        XCTAssertLessThanOrEqual(grid.count, 800_000)
        XCTAssertFalse(grid.saturated)
        XCTAssertEqual(syncBytesAfterFirst, 0, "no sim re-downloads (the 12.19 disk writes)")
        XCTAssertLessThanOrEqual(resets, 1800 / 30)
        XCTAssertNotEqual(gov.peakLevel, .critical)
    }
}
