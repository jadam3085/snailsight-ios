import XCTest
@testable import SnailSightCore

/// 12.3 Map ▸ 3D: whole-site tile LOD under the memory budget, the Fly controller maths, ground, slicer, shapes.
final class Map3DTests: XCTestCase {

    // MARK: fixture: the TileSelect fixture tree (two storeys, 24 × 12 m, 4 m leaves → 64 m roots), 1 MB a leaf

    static func tree(leafMem: Int = 1 << 20) -> [TileNode] {
        func node(_ level: Int, _ size: Int, _ tx: Int, _ ty: Int, _ z0: Double) -> TileNode {
            let key = size == 4 ? "\(level)/\(tx)/\(ty)" : "\(level)/\(size)/\(tx)/\(ty)"
            let lo = [Double(tx * size), Double(ty * size), z0], hi = [Double((tx + 1) * size), Double((ty + 1) * size), z0 + 2.6]
            let c = (0..<3).map { (lo[$0] + hi[$0]) / 2 }, e = (0..<3).map { (hi[$0] - lo[$0]) / 2 }
            var kids: [TileNode] = []
            if size > 4 {
                let s2 = size / 2
                for a in 0...1 { for b in 0...1 {
                    let cx = tx * 2 + a, cy = ty * 2 + b
                    if cx * s2 >= 24 || cy * s2 >= 12 { continue }
                    kids.append(node(level, s2, cx, cy, z0))
                } }
            }
            let box = [c[0], c[1], c[2], e[0], 0, 0, 0, e[1], 0, 0, 0, e[2]]
            return TileNode(key: key, level: level, size: size, box: box, uri: "\(TileSelectTests.fakeHash(key)).usdz",
                            bytes: 1000, mem: leafMem, children: kids)
        }
        return [node(0, 64, 0, 0, -0.1), node(1, 64, 0, 0, 2.9)]
    }

    /// Every leaf area of every visible root is covered by exactly one selected node (no holes, no overlap).
    func assertCover(_ want: [String: TileSelect.Want], roots: [TileNode], maxLevel: Int? = nil, file: StaticString = #file, line: UInt = #line) {
        let par = TileSelect.ancestorsMap(roots)
        for leaf in TileSet.flatten(roots) where leaf.children.isEmpty && Map3DTiles.visible(leaf, maxLevel: maxLevel) {
            var n = 0
            var k: String? = leaf.key
            while let kk = k { if want[kk] != nil { n += 1 }; k = par[kk] }
            XCTAssertEqual(n, 1, "leaf \(leaf.key) covered \(n) times", file: file, line: line)
        }
    }

    func testWholeSiteAlwaysCoveredAndRefinedNearCamera() {
        let roots = Self.tree()
        let w = Map3DTiles.select(roots, cam: [2, 2, 1.5])
        assertCover(w, roots: roots)
        XCTAssertNotNil(w["0/0/0"], "the leaf under the camera is drawn")
        // far end of the site stays coarser than the near end
        let far = w.values.filter { $0.node.box[0] > 18 && $0.node.level == 0 }.map(\.node.size).max() ?? 0
        XCTAssertGreaterThan(far, TileSelect.LEAF_M)
        // from far above the site nothing refines: just the two roots
        let high = Map3DTiles.select(roots, cam: [12, 6, 300])
        XCTAssertEqual(Set(high.keys), ["0/64/0/0", "1/64/0/0"])
    }

    func testBudgetIsNeverExceededAndCoverHolds() {
        let roots = Self.tree(leafMem: 10 << 20)              // 10 MB a tile
        for budget in [20 << 20, 45 << 20, 120 << 20, 600 << 20] {
            let w = Map3DTiles.select(roots, cam: [5, 5, 1.5], budget: budget, k: 3)
            XCTAssertLessThanOrEqual(w.values.reduce(0) { $0 + $1.node.mem }, budget)
            assertCover(w, roots: roots)
        }
        // roots alone over budget: the nearest root's storey only (refined where it costs nothing more)
        let tiny = Map3DTiles.select(roots, cam: [5, 5, 1.5], budget: 15 << 20)
        XCTAssertEqual(tiny.count, 1)
        XCTAssertTrue(tiny.values.allSatisfy { $0.node.level == 0 })
    }

    func testMoreDetailWithBiggerK() {
        let roots = Self.tree()
        let a = Map3DTiles.select(roots, cam: [12, 6, 8], k: 0.6)
        let b = Map3DTiles.select(roots, cam: [12, 6, 8], k: 2.5)
        XCTAssertGreaterThan(b.count, a.count)
    }

    func testLevelSlicerHidesUpperStoreys() {
        let roots = Self.tree()
        let w = Map3DTiles.select(roots, cam: [2, 2, 1.5], maxLevel: 0)
        XCTAssertTrue(w.values.allSatisfy { $0.node.level == 0 })
        assertCover(w, roots: roots, maxLevel: 0)
        let all = Map3DTiles.select(roots, cam: [2, 2, 1.5], maxLevel: nil)
        XCTAssertTrue(all.values.contains { $0.node.level == 1 })
    }

    func testFetchOrderCoarseAndNearFirst() {
        let roots = Self.tree()
        let w = Map3DTiles.select(roots, cam: [2, 2, 1.5])
        let order = Map3DTiles.fetchOrder(w, loaded: [])
        XCTAssertEqual(order.count, w.count)
        // the first fetch is near (distance / size smallest): a leaf right under the camera or a big parent
        let first = order[0]
        XCTAssertLessThanOrEqual(first.distance / Double(first.node.size), order.last!.distance / Double(order.last!.node.size))
        XCTAssertEqual(Map3DTiles.fetchOrder(w, loaded: Set(w.keys)).count, 0)
    }

    func testEvictionUnderBudgetFarthestFirst() {
        let roots = Self.tree()
        let w = Map3DTiles.select(roots, cam: [2, 2, 1.5])
        var loaded: [String: (mem: Int, distance: Double)] = [:]
        for (k, v) in w { loaded[k] = (v.node.mem, v.distance) }
        loaded["stale"] = (1 << 20, 3)                                // neither wanted nor drawn
        loaded["filler"] = (1 << 20, 50)                              // hole-filler: drawn, not wanted
        let drawn = Set(w.keys).union(["filler"])
        // generous budget: only the stale one goes
        XCTAssertEqual(Map3DTiles.evict(loaded: loaded, want: w, drawn: drawn, budget: 1 << 30), ["stale"])
        // tight budget: the filler next, then the farthest wanted tiles; what stays fits
        let budget = (w.count - 3) << 20
        let ev = Map3DTiles.evict(loaded: loaded, want: w, drawn: drawn, budget: budget)
        XCTAssertEqual(Array(ev.prefix(2)), ["stale", "filler"])
        let left = loaded.filter { !ev.contains($0.key) }
        XCTAssertLessThanOrEqual(left.values.reduce(0) { $0 + $1.mem }, budget)
        let evictedWanted = ev.dropFirst(2).compactMap { loaded[$0]?.distance }
        let keptMax = left.values.map(\.distance).max() ?? 0
        XCTAssertTrue(evictedWanted.allSatisfy { $0 >= keptMax }, "evicted wanted tiles are the farthest")
    }

    func testBounds() {
        let b = Map3DTiles.bounds(Self.tree())!
        XCTAssertEqual(b[0], 0, accuracy: 1e-9)
        XCTAssertEqual(b[3], 64, accuracy: 1e-9)
        XCTAssertEqual(b[5], 5.5, accuracy: 1e-9)
        XCTAssertNil(Map3DTiles.bounds([]))
    }

    // MARK: fly controller

    func testStickToVelocityInCameraFrame() {
        let p = Map3DFlyParams(speed: .drone)
        // yaw 0 looks along −Z: full forward = (0, 0, −8)
        let f = Map3DFly.targetVelocity(stick: (0, 1), climb: 0, yaw: 0, params: p)
        XCTAssertEqual(f.x, 0, accuracy: 1e-9); XCTAssertEqual(f.z, -8, accuracy: 1e-9)
        // strafe right at yaw 0 = +X
        let r = Map3DFly.targetVelocity(stick: (1, 0), climb: 0, yaw: 0, params: p)
        XCTAssertEqual(r.x, 8, accuracy: 1e-9)
        // turned 90° left (yaw +π/2): forward = −X
        let l = Map3DFly.targetVelocity(stick: (0, 1), climb: 0, yaw: .pi / 2, params: p)
        XCTAssertEqual(l.x, -8, accuracy: 1e-9); XCTAssertEqual(l.z, 0, accuracy: 1e-9)
        // diagonal is clamped to the unit disc
        let d = Map3DFly.targetVelocity(stick: (1, 1), climb: 0, yaw: 0.3, params: p)
        XCTAssertEqual((d.x * d.x + d.z * d.z).squareRoot(), 8, accuracy: 1e-9)
        // climb only for the drone
        XCTAssertEqual(Map3DFly.targetVelocity(stick: (0, 0), climb: 1, yaw: 0, params: p).y, 8 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(Map3DFly.targetVelocity(stick: (0, 0), climb: 1, yaw: 0, params: Map3DFlyParams(speed: .walk)).y, 0)
        // presets
        XCTAssertEqual(Map3DFly.targetVelocity(stick: (0, 1), climb: 0, yaw: 0, params: Map3DFlyParams(speed: .walk)).length, 1.4, accuracy: 1e-9)
        XCTAssertEqual(Map3DSpeed.walk.next, .run); XCTAssertEqual(Map3DSpeed.drone.next, .walk)
    }

    func testLookClamp() {
        let p = Map3DFlyParams()
        XCTAssertEqual(Map3DFly.clampPitch(3, params: p), p.maxPitch)
        XCTAssertEqual(Map3DFly.clampPitch(-3, params: p), -p.maxPitch)
        var s = Map3DFlyState(eye: Map3DVec(0, 5, 0))
        for _ in 0..<200 { s = Map3DFly.step(s, stick: (0, 0), look: (0, 1), climb: 0, dt: 1.0 / 30, params: p) }
        XCTAssertEqual(s.pitch, p.maxPitch, accuracy: 1e-9)
        s = Map3DFly.step(s, stick: (0, 0), look: (1, 0), climb: 0, dt: 0.1, params: p)
        XCTAssertLessThan(s.yaw, 0, "right look turns right (yaw decreases)")
    }

    func testGroundClamp() {
        let flat: (Double, Double) -> Double? = { _, _ in 0 }
        // drone: never under the clearance
        var d = Map3DFlyState(eye: Map3DVec(0, 2, 0))
        for _ in 0..<120 { d = Map3DFly.step(d, stick: (0, 0), climb: -1, dt: 1.0 / 30, params: Map3DFlyParams(speed: .drone), ground: flat) }
        XCTAssertEqual(d.eye.y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(d.velocity.y, 0, "no build-up into the ground")
        // walk: the eye settles at eye height above the floor, also stepping up onto a 3 m storey
        var w = Map3DFlyState(eye: Map3DVec(0, 10, 0))
        for _ in 0..<90 { w = Map3DFly.step(w, stick: (0, 1), climb: 1, dt: 1.0 / 30, params: Map3DFlyParams(speed: .walk), ground: flat) }
        XCTAssertEqual(w.eye.y, 1.6, accuracy: 0.01)
        XCTAssertLessThan(w.eye.z, -2, "walked forward")
        let step: (Double, Double) -> Double? = { _, z in z < -4 ? 3 : 0 }
        for _ in 0..<120 { w = Map3DFly.step(w, stick: (0, 1), climb: 0, dt: 1.0 / 30, params: Map3DFlyParams(speed: .walk), ground: step) }
        XCTAssertEqual(w.eye.y, 4.6, accuracy: 0.01)
        // no ground known: unchanged
        XCTAssertEqual(Map3DFly.groundClamp(7, ground: nil, dt: 0.1, params: Map3DFlyParams(speed: .walk)), 7)
        // a hitch never teleports
        let h = Map3DFly.step(Map3DFlyState(eye: .zero, velocity: Map3DVec(0, 0, -8)), stick: (0, 1), climb: 0, dt: 5,
                              params: Map3DFlyParams(speed: .drone))
        XCTAssertLessThanOrEqual(h.eye.length, 0.81)
    }

    func testOrbitMinPitchAndGyro() {
        // target on the ground, 10 m away: eye 0.3 m above → asin(0.03)
        XCTAssertEqual(Map3DFly.orbitMinPitch(targetY: 0, distance: 10, groundY: 0)!, asin(0.03), accuracy: 1e-9)
        XCTAssertNil(Map3DFly.orbitMinPitch(targetY: 0, distance: 10, groundY: nil))
        XCTAssertNil(Map3DFly.orbitMinPitch(targetY: 50, distance: 10, groundY: 0), "far above: anything goes")
        let g = Map3DFly.gyroDelta(from: (3.1, 0), to: (-3.1, 0.1))
        XCTAssertEqual(g.0, 2 * .pi - 6.2, accuracy: 1e-9)
        XCTAssertEqual(g.1, 0.1, accuracy: 1e-9)
    }

    // MARK: ground, slicer, shapes, quality

    func testGroundUnderCamera() {
        let floors = [Map3DFloor(z: -2.6, bounds: [0, 0, 10, 10]), Map3DFloor(z: 0, bounds: [0, 0, 12, 10]),
                      Map3DFloor(z: 2.9, bounds: [0, 0, 12, 10])]
        XCTAssertEqual(Map3DGround.height(x: 5, y: 5, eyeZ: 1.6, floors: floors, dem: nil), 0)
        XCTAssertEqual(Map3DGround.height(x: 5, y: 5, eyeZ: 4.5, floors: floors, dem: nil), 2.9)
        XCTAssertEqual(Map3DGround.height(x: 5, y: 5, eyeZ: -1, floors: floors, dem: nil), -2.6)
        // outside every plan: the DEM
        XCTAssertEqual(Map3DGround.height(x: 30, y: 5, eyeZ: 1.6, floors: floors, dem: 0.7), 0.7)
        XCTAssertNil(Map3DGround.height(x: 30, y: 5, eyeZ: 1.6, floors: [], dem: nil))
    }

    func testSliceCut() {
        let lv = PlanLevels.make([(level: 0, floorZ: -2.6), (level: 1, floorZ: 0), (level: 2, floorZ: 2.9)], yard: true)
        let main = lv.first { $0.level == 1 }
        XCTAssertEqual(Map3DSlice.cutZ(levels: lv, slice: main)!, 2.8, accuracy: 1e-9)
        XCTAssertNil(Map3DSlice.cutZ(levels: lv, slice: lv.first { $0.level == 2 }))
        XCTAssertNil(Map3DSlice.cutZ(levels: lv, slice: lv.first { $0.level == nil }), "Yard = everything")
        XCTAssertEqual(Map3DSlice.maxLevel(main), 1)
    }

    func testFrustumCornersAreOnTheEdgeOfView() {
        let c = [1.0, 2.0, 3.0]
        let pts = Map3DShapes.frustum(camera: c, yaw: 0.7, pitchDeg: -20, hfovDeg: 90, vfovDeg: 60, far: 8)
        XCTAssertEqual(pts.count, 5)
        for p in pts.dropFirst() {
            // a point slightly toward the centre of the far plane is seen; slightly outside is not
            let centre = Map3DShapes.frustum(camera: c, yaw: 0.7, pitchDeg: -20, hfovDeg: 0.001, vfovDeg: 0.001, far: 7.9)[1]
            var inside = [0.0, 0.0, 0.0]
            for i in 0..<3 {
                let toCorner: Double = (p[i] - c[i]) * 0.855
                let toCentre: Double = (centre[i] - c[i]) * 0.05
                inside[i] = c[i] + toCorner + toCentre
            }
            XCTAssertTrue(CameraFrustum.sees(camera: c, yaw: 0.7, pitchDeg: -20, hfovDeg: 90, vfovDeg: 60, far: 20, point: inside))
        }
        let wide = Map3DShapes.frustum(camera: c, yaw: 0.7, pitchDeg: -20, hfovDeg: 100, vfovDeg: 70, far: 6)[2]
        XCTAssertFalse(CameraFrustum.sees(camera: c, yaw: 0.7, pitchDeg: -20, hfovDeg: 90, vfovDeg: 60, far: 20, point: wide))
        XCTAssertEqual(Map3DShapes.frustumEdges.count, 8)
    }

    func testTerrainMesh() {
        var g = [Float](repeating: 1, count: 4 * 3)
        g[5] = .nan                                                    // one hole → its 4 quads gone
        let m = Map3DShapes.terrain(origin: [10, 20], res: 0.5, w: 4, h: 3, ground: g)
        XCTAssertEqual(m.positions.count, 11 * 3)
        XCTAssertEqual(m.indices.count / 6, 6 - 4)
        XCTAssertEqual(m.positions[0], 10.25); XCTAssertEqual(m.positions[1], 20.25)
        // CCW from above (+z normal)
        let i = m.indices.prefix(3).map { Int($0) * 3 }
        let a = (m.positions[i[1]] - m.positions[i[0]], m.positions[i[1] + 1] - m.positions[i[0] + 1])
        let b = (m.positions[i[2]] - m.positions[i[0]], m.positions[i[2] + 1] - m.positions[i[0] + 1])
        XCTAssertGreaterThan(a.0 * b.1 - a.1 * b.0, 0)
        XCTAssertEqual(Map3DShapes.terrainStep(w: 101, h: 101, maxTriangles: 20_000), 1)
        XCTAssertEqual(Map3DShapes.terrainStep(w: 401, h: 401, maxTriangles: 40_000), 3)
        XCTAssertTrue(Map3DShapes.terrain(origin: [0, 0], res: 1, w: 1, h: 1, ground: [0]).indices.isEmpty)
    }

    func testQualityAndFps() {
        XCTAssertEqual(Map3DQuality.adjust(k: 1.5, fps: 18), 1.275, accuracy: 1e-9)
        XCTAssertEqual(Map3DQuality.adjust(k: 1.5, fps: 30), 1.5)
        XCTAssertEqual(Map3DQuality.adjust(k: 2.4, fps: 60), 2.5)
        XCTAssertEqual(Map3DQuality.adjust(k: 0.6, fps: 10), 0.6)
        XCTAssertEqual(Map3DQuality.budget(availableMB: nil), Map3DTiles.BUDGET)
        XCTAssertEqual(Map3DQuality.budget(availableMB: 450), Map3DTiles.BUDGET / 2)
        XCTAssertEqual(Map3DQuality.budget(availableMB: 200), Map3DTiles.BUDGET / 3)
        var f = Map3DFps(window: 1)
        XCTAssertNil(f.frame(t: 0))
        var got: Double?
        for i in 1...30 { got = f.frame(t: Double(i) / 30) ?? got }
        XCTAssertEqual(got!, 30, accuracy: 1e-6)
        XCTAssertEqual(Map3DVec.yUp(map: [1, 2, 3]), Map3DVec(1, 3, -2))
        XCTAssertEqual(Map3DVec(1, 3, -2).map, [1, 2, 3])
    }
}
