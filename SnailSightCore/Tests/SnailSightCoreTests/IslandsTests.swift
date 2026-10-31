import XCTest
@testable import SnailSightCore

/// 12.22 islands in the app (API §6b.13). Synthetic frames and coordinates only.
final class IslandsTests: XCTestCase {

    /// 4-DoF T (frame -> house): yaw about z + translation.
    static func T(_ x: Double, _ y: Double, _ z: Double = 0, yawDeg: Double) -> Mat4 {
        let c = cos(yawDeg * .pi / 180), s = sin(yawDeg * .pi / 180)
        return Mat4([c, -s, 0, x, s, c, 0, y, 0, 0, 1, z, 0, 0, 0, 1])
    }

    static func placement(_ T: Mat4?, exact: Bool, component: String, sigma: Double? = nil,
                          datum: [String: Any]? = nil) -> [String: Any] {
        var p: [String: Any] = ["known": T != nil, "exact": exact, "approx": !exact, "component": component,
                                "component_size": 2]
        if let T { p["T_house_frame"] = T.m }
        if let sigma { p["sigma_m"] = sigma }
        if let datum { p["datum"] = datum; p["geo"] = ["lat": 10.0, "lon": 20.0, "sigma_m": sigma ?? 2.0] }
        return p
    }

    static let houseDatum: [String: Any] = ["lat0": 10.0, "lon0": 20.0, "yaw": 0.2, "t": [5.0, -3.0], "yaw_known": true,
                                            "centroid_map": [0.0, 0.0]]

    /// A world: island A joined to the house (exact), B and C one GPS-placed component (approx), D unplaced.
    static func doc(rev: Int = 4) -> [String: Any] {
        let TA = T(20, 5, yawDeg: 90), TB = T(1500, 800, yawDeg: -30), TC = T(1510, 790, yawDeg: 10)
        // datum of B consistent with TB and the house datum: B -> house -> ENU
        let hy = 0.2, by = hy + (-30 * .pi / 180)
        let tb = [5 + cos(hy) * 1500 - sin(hy) * 800, -3 + sin(hy) * 1500 + cos(hy) * 800]
        let dB: [String: Any] = ["lat0": 10.0, "lon0": 20.0, "yaw": by, "t": tb, "yaw_known": true]
        return [
            "base": "site", "rev": rev, "house": ["datum": houseDatum],
            "islands": [
                ["id": "isl-aaaaaa", "map_id": "site~isl-aaaaaa", "state": "settled", "keyframes": 120,
                 "bbox": [[0.0, 0.0, 0.0], [10.0, 4.0, 1.5]], "placement": placement(TA, exact: true, component: "house")],
                ["id": "isl-bbbbbb", "map_id": "site~isl-bbbbbb", "state": "provisional", "keyframes": 40,
                 "bbox": [[-5.0, -5.0, 0.0], [5.0, 5.0, 1.0]],
                 "placement": placement(TB, exact: false, component: "isl-bbbbbb", sigma: 6.5, datum: dB)],
                ["id": "isl-cccccc", "map_id": "site~isl-cccccc", "state": "provisional", "keyframes": 30,
                 "bbox": [[0.0, 0.0, 0.0], [3.0, 3.0, 1.0]],
                 "placement": placement(TC, exact: false, component: "isl-bbbbbb", sigma: 6.5)],
                ["id": "isl-dddddd", "map_id": "site~isl-dddddd", "state": "provisional", "keyframes": 25,
                 "bbox": [[0.0, 0.0, 0.0], [2.0, 2.0, 1.0]], "placement": ["known": false, "approx": true]],
                ["id": "isl-eeeeee", "map_id": "site~isl-eeeeee", "state": "retired", "keyframes": 3,
                 "bbox": [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]], "placement": placement(T(0, 0, yawDeg: 0), exact: true, component: "house")],
            ],
            "joins": [["id": "j1", "a": "house", "b": "isl-aaaaaa", "state": "active"],
                      ["id": "j2", "a": "isl-bbbbbb", "b": "isl-cccccc", "state": "active"],
                      ["id": "j0", "a": "house", "b": "isl-dddddd", "state": "rolled_back"]],
        ]
    }

    func assertMat(_ a: Mat4?, _ b: Mat4, _ tol: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil matrix", file: file, line: line) }
        for i in 0..<16 { XCTAssertEqual(a.m[i], b.m[i], accuracy: tol, "m[\(i)]", file: file, line: line) }
    }

    // MARK: state

    func testDocMessageAndRevisionOrdering() {
        var w = IslandWorld()
        XCTAssertTrue(w.applyDoc(Self.doc()))
        XCTAssertEqual(w.rev, 4)
        XCTAssertEqual(w.base, "site")
        XCTAssertEqual(w.islands.count, 5)
        XCTAssertEqual(w.joins, 2)                                   // the rolled-back join does not count
        XCTAssertNotNil(w.houseDatum)
        XCTAssertFalse(w.applyDoc(Self.doc()))                       // same doc: no change
        XCTAssertFalse(w.applyMessage(["type": "islands", "rev": 3, "islands": []]))   // older revision ignored
        XCTAssertFalse(w.applyMessage(["type": "islands", "rev": 4, "islands": []]))   // same revision ignored
        // a WS world revision: placement changes (D gets joined), house datum kept (the message has none)
        var m = Self.doc(rev: 5)
        m["type"] = "islands"
        m["house"] = nil
        var list = m["islands"] as! [[String: Any]]
        list[3]["placement"] = Self.placement(Self.T(-8, 2, yawDeg: 45), exact: true, component: "house")
        m["islands"] = list
        w.setPath("isl-aaaaaa", [[0, 0, 0], [1, 1, 0]])
        XCTAssertTrue(w.applyMessage(m))
        XCTAssertEqual(w.rev, 5)
        XCTAssertTrue(w.islands["isl-dddddd"]?.placement.exact ?? false)
        XCTAssertNotNil(w.houseDatum)
        XCTAssertEqual(w.islands["isl-aaaaaa"]?.path?.count, 2)      // a fetched path survives a revision
        XCTAssertFalse(w.applyDoc(Self.doc(rev: 4)))                 // a stale REST answer after the WS one
        XCTAssertEqual(w.rev, 5)
    }

    func testAckDrivesMineAndFetch() {
        var w = IslandWorld()
        w.applyDoc(Self.doc())
        var r = w.applyAck(["seq": 1])
        XCTAssertFalse(r.changed); XCTAssertFalse(r.fetch); XCTAssertNil(w.current)
        r = w.applyAck(["islands": [["island": "isl-bbbbbb", "map_id": "site~isl-bbbbbb", "placed": false, "approx": true, "world_rev": 4]]])
        XCTAssertTrue(r.changed); XCTAssertFalse(r.fetch)
        XCTAssertEqual(w.current?.island, "isl-bbbbbb")
        r = w.applyAck(["islands": [["island": "isl-bbbbbb", "map_id": "site~isl-bbbbbb", "placed": false, "approx": true, "world_rev": 4]]])
        XCTAssertFalse(r.changed)
        r = w.applyAck(["islands": [["island": "isl-ffffff", "map_id": "site~isl-ffffff", "placed": true, "world_rev": 4]]])
        XCTAssertTrue(r.fetch)                                       // unknown island: read the doc
        r = w.applyAck(["islands": [["island": "isl-bbbbbb", "map_id": "site~isl-bbbbbb", "placed": true, "world_rev": 6]]])
        XCTAssertTrue(r.fetch)                                       // newer world revision
        // placed wins over a newer-named unplaced one
        _ = w.applyAck(["islands": [["island": "isl-aaaaaa", "placed": false], ["island": "isl-bbbbbb", "placed": true]]])
        XCTAssertEqual(w.current?.island, "isl-bbbbbb")
        w.clearMine()
        XCTAssertNil(w.current)
    }

    // MARK: pill

    func testPillSaysNewAreaNotFailure() {
        var w = IslandWorld()
        w.applyDoc(Self.doc())
        XCTAssertNil(w.pillNote())
        XCTAssertEqual(w.pillNote(farFromHouseM: 1609)?.text, "NEW AREA · ~1.6 km from the house · mapping")
        _ = w.applyAck(["islands": [["island": "isl-bbbbbb", "placed": false]]])
        XCTAssertEqual(w.pillNote()?.text, "NEW AREA · joining island ‹bbbbbb›")
        _ = w.applyAck(["islands": [["island": "isl-bbbbbb", "placed": true, "approx": true]]])
        XCTAssertEqual(w.pillNote()?.text, "NEW AREA · island ‹bbbbbb› · approx ±7 m")
        _ = w.applyAck(["islands": [["island": "isl-aaaaaa", "placed": true, "exact": true]]])
        XCTAssertEqual(w.pillNote()?.text, "NEW AREA · island ‹aaaaaa› · joined to the house")
        _ = w.applyAck(["islands": [["island": "isl-dddddd", "placed": true]]])
        XCTAssertEqual(w.pillNote()?.text, "NEW AREA · island ‹dddddd› · location unknown")

        // through LocPill: searching + island = a good "new area" state instead of FINDING YOU / NOT IN MAP
        let note = w.pillNote()
        let s = LocPill.make(LocPillInput(online: true, phase: .searching, searchSeconds: 300, attempts: 80, matches: 0,
                                          notInMap: true, island: note))
        XCTAssertEqual(s.tone, .good)
        XCTAssertTrue(s.text.hasPrefix("NEW AREA"))
        XCTAssertTrue(s.rows.contains { $0.contains("overlaps") })
        // a house lock always wins
        let l = LocPill.make(LocPillInput(online: true, phase: .locked, source: "server", island: note))
        XCTAssertTrue(l.text.hasPrefix("LOCALIZED"))
        // joining = working tone
        _ = w.applyAck(["islands": [["island": "isl-bbbbbb", "placed": false]]])
        XCTAssertEqual(LocPill.make(LocPillInput(online: true, phase: .searching, island: w.pillNote())).tone, .working)
        XCTAssertEqual(IslandPillNote.metres(0.3), "1 m")
        XCTAssertEqual(IslandPillNote.metres(142), "140 m")
    }

    // MARK: placement

    func testRelativeAndArPlacementOwnFrameChainedAndHouse() {
        var w = IslandWorld()
        w.applyDoc(Self.doc())
        let TB = Self.T(1500, 800, yawDeg: -30), TC = Self.T(1510, 790, yawDeg: 10), TA = Self.T(20, 5, yawDeg: 90)
        assertMat(w.relative("isl-bbbbbb", "isl-cccccc"), TB.inverse * TC)
        XCTAssertNil(w.relative("isl-aaaaaa", "isl-bbbbbb"))         // different components: no relative transform
        XCTAssertNil(w.relative("isl-dddddd", "isl-aaaaaa"))

        // T_island_arkit as the island feed's correction gives it (an ARKit y-up world -> island z-up)
        let TBarkit = Align4(x: 3, y: -2, z: 0.1, yaw: 0.7).matrix
        let Thouse = Align4(x: -1, y: 4, z: 0, yaw: -1.1).matrix
        // 1. the island the phone is in: its own frame
        assertMat(w.arPlacement("isl-bbbbbb", islandArkit: ["isl-bbbbbb": TBarkit], houseArkit: nil), TBarkit.inverse)
        // 2. same component: chained through it (exact relative even though B/C are only GPS-placed)
        let Tc = w.arPlacement("isl-cccccc", islandArkit: ["isl-bbbbbb": TBarkit], houseArkit: nil)
        assertMat(Tc, TBarkit.inverse * TB.inverse * TC)
        // a point of C drawn in AR = the same ARKit point whether reached through B or directly
        let pC = [1.0, 2.0, 0.5]
        let viaB = TBarkit.inverse.apply((TB.inverse * TC).apply(pC))
        let direct = Tc!.apply(pC)
        for i in 0..<3 { XCTAssertEqual(viaB[i], direct[i], accuracy: 1e-9) }
        // 3. house lock: exact islands via T_house_frame; approximate / unplaced never in AR
        assertMat(w.arPlacement("isl-aaaaaa", islandArkit: [:], houseArkit: Thouse), Thouse.inverse * TA)
        XCTAssertNil(w.arPlacement("isl-bbbbbb", islandArkit: [:], houseArkit: Thouse))
        XCTAssertNil(w.arPlacement("isl-dddddd", islandArkit: [:], houseArkit: Thouse))
        XCTAssertNil(w.arPlacement("isl-aaaaaa", islandArkit: [:], houseArkit: nil))
        XCTAssertNil(w.arPlacement("isl-eeeeee", islandArkit: [:], houseArkit: Thouse))   // retired
        // Map 3D: everything placed, exact first; unplaced and retired left out
        let m3 = w.map3DPlacements()
        XCTAssertEqual(m3.map(\.id), ["isl-aaaaaa", "isl-bbbbbb", "isl-cccccc"])
        XCTAssertEqual(m3.map(\.approx), [false, true, true])
    }

    // MARK: 2D outlines

    func testOutlinesAtLatLonDashedWhenApproxAndConsistentWithTransform() throws {
        var w = IslandWorld()
        w.applyDoc(Self.doc())
        _ = w.applyAck(["islands": [["island": "isl-bbbbbb", "placed": true]]])
        let o = w.outlines()
        XCTAssertEqual(o.map(\.id), ["isl-aaaaaa", "isl-bbbbbb", "isl-cccccc"])     // D unplaced, E retired
        let a = try XCTUnwrap(o.first { $0.id == "isl-aaaaaa" })
        XCTAssertFalse(a.dashed)
        // exact: T_house_frame of the padded box corners
        let TA = Self.T(20, 5, yawDeg: 90)
        let c0 = TA.apply([-1, -1, 0])
        XCTAssertEqual(a.points[0][0], c0[0], accuracy: 1e-9)
        XCTAssertEqual(a.points[0][1], c0[1], accuracy: 1e-9)
        // approx with both datums: through lat/lon; the datum was built consistent with T_house_frame, so both routes agree
        let b = try XCTUnwrap(o.first { $0.id == "isl-bbbbbb" })
        XCTAssertTrue(b.dashed)
        XCTAssertTrue(b.mine)
        XCTAssertEqual(b.label, "island bbbbbb · ±7 m")
        let TB = Self.T(1500, 800, yawDeg: -30)
        for (i, q) in [[-6.0, -6.0], [6.0, -6.0], [6.0, 6.0], [-6.0, 6.0]].enumerated() {
            let r = TB.apply([q[0], q[1], 0])
            XCTAssertEqual(b.points[i][0], r[0], accuracy: 0.05)            // < 5 cm of the transform route at 1.7 km
            XCTAssertEqual(b.points[i][1], r[1], accuracy: 0.05)
        }
        XCTAssertEqual(b.centre[0], 1500, accuracy: 0.05)
        // C has no own datum: T_house_frame route
        let cc = try XCTUnwrap(o.first { $0.id == "isl-cccccc" })
        XCTAssertTrue(cc.dashed)
        // GPS distance from the house through the house datum
        let hd = try XCTUnwrap(GeoDatum(json: Self.houseDatum))
        let far = hd.toLatLon(x: 1200, y: 900)
        XCTAssertEqual(w.distanceFromHouse(lat: far.lat, lon: far.lon) ?? 0, 1500, accuracy: 0.01)
        XCTAssertNil(IslandWorld().distanceFromHouse(lat: 10, lon: 20))
    }

    // MARK: feeds within the memory budget

    func testFeedPlanPrioritisesMineThenNearExactThenMap() {
        var w = IslandWorld()
        w.applyDoc(Self.doc())
        XCTAssertEqual(w.feedPlan(maxMaps: 3, camHouse: nil, radiusM: 40, mapOpen: false), [])
        _ = w.applyAck(["islands": [["island": "isl-dddddd", "placed": true]]])
        XCTAssertEqual(w.feedPlan(maxMaps: 3, camHouse: nil, radiusM: 40, mapOpen: false), ["isl-dddddd"])
        // house-locked near A (A's box spans x 16..20, y 5..15 in the house frame)
        XCTAssertEqual(w.feedPlan(maxMaps: 3, camHouse: [10, 10], radiusM: 40, mapOpen: false), ["isl-dddddd", "isl-aaaaaa"])
        XCTAssertEqual(w.feedPlan(maxMaps: 3, camHouse: [-100, 10], radiusM: 40, mapOpen: false), ["isl-dddddd"])
        // Map open: placed ones (exact first), capped by the budget
        XCTAssertEqual(w.feedPlan(maxMaps: 3, camHouse: [-100, 10], radiusM: 40, mapOpen: true),
                       ["isl-dddddd", "isl-aaaaaa", "isl-bbbbbb"])
        XCTAssertEqual(w.feedPlan(maxMaps: 1, camHouse: [10, 10], radiusM: 40, mapOpen: true), ["isl-dddddd"])
        XCTAssertEqual(w.feedPlan(maxMaps: 0, camHouse: [10, 10], radiusM: 40, mapOpen: true), [])
        // budgets tighten with the memory level
        let ps = MemLevel.allCases.map { MemPlan.plan(level: $0, thermal: .nominal) }
        XCTAssertEqual(ps.map(\.islandMaxMaps), [3, 2, 1, 1])                  // the island you are in survives critical
        XCTAssertTrue(MemPlan.plan(level: .shed, thermal: .nominal).actions.contains("island_tiles_1x16"))
    }
}
