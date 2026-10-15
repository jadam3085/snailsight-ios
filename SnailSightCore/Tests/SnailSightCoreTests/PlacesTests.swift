import XCTest
@testable import SnailSightCore

/// P2a persistent places: anchor/state serialization, the place container, naming, candidate ordering, the relaunch
/// state machine, room bounds from the floor grid and animals that stay in / pace their room.
final class PlacesTests: XCTestCase {
    // MARK: serialization

    func sampleRecord() -> SimEntityRecord {
        let home = HomeArea.relative([V2(1, 1), V2(4, 1), V2(4, 3), V2(1, 3)], source: .mesh, name: "Basement",
                                     anchor: V2(2, 2), yaw: 0)
        return SimEntityRecord(id: "A1B2", kind: "deer", behaviour: "pace", heading: 0.5, anchor: [2, -1.2, -2],
                               home: home, paceLoop: [V2(-0.5, -0.5), V2(1.5, -0.5), V2(1.5, 0.5)], room: "Basement")
    }

    func testRecordRoundTripAndAnchorName() throws {
        let r = sampleRecord()
        XCTAssertEqual(r.anchorName, "sim.A1B2")
        XCTAssertEqual(SimEntityRecord.id(fromAnchorName: "sim.A1B2"), "A1B2")
        XCTAssertNil(SimEntityRecord.id(fromAnchorName: "cube.3"))
        XCTAssertNil(SimEntityRecord.id(fromAnchorName: "sim."))
        XCTAssertNil(SimEntityRecord.id(fromAnchorName: nil))
        let d = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(SimEntityRecord.self, from: d), r)
    }

    func testManifestRoundTripThroughContainer() throws {
        var m = PlaceManifest(id: PlaceManifest.newID(), name: "Basement", now: 1000)
        m.saved(now: 1010, mapBytes: 5, entities: [sampleRecord()])
        m.hints = PlaceHints(ssid: "eero")
        let map = Data([1, 2, 3, 4, 5])
        let blob = try PlaceCodec.encode(manifest: m, map: map)
        XCTAssertEqual(blob.prefix(4), Data("SSWM".utf8))
        let (m2, map2) = try PlaceCodec.decode(blob)
        XCTAssertEqual(m2, m)
        XCTAssertEqual(map2, map)
        XCTAssertEqual(m2.version, 1)
        XCTAssertTrue(PlaceManifest.isValidID(m.id))
        XCTAssertTrue(m.id.hasPrefix("place-") && m.id.count == 14)
        XCTAssertFalse(PlaceManifest.isValidID("../etc"))
    }

    func testContainerRejectsJunk() {
        XCTAssertThrowsError(try PlaceCodec.decode(Data("hello world".utf8))) { e in
            XCTAssertEqual(e as? PlaceCodec.CodecError, .notAPlace)
        }
        var bad = Data("SSWM".utf8); bad.append(contentsOf: [1, 0, 0, 1, 0])     // says 256 bytes of manifest
        XCTAssertThrowsError(try PlaceCodec.decode(bad)) { e in XCTAssertEqual(e as? PlaceCodec.CodecError, .truncated) }
        var v2 = Data("SSWM".utf8); v2.append(contentsOf: [2, 0, 0, 0, 0])
        XCTAssertThrowsError(try PlaceCodec.decode(v2)) { e in XCTAssertEqual(e as? PlaceCodec.CodecError, .badVersion(2)) }
    }

    func testHomeAreaFollowsTheAnchor() {
        let world = [V2(1, 1), V2(4, 1), V2(4, 3), V2(1, 3)]
        let h = HomeArea.relative(world, source: .mesh, anchor: V2(2, 2), yaw: 0.3)
        let back = h.world(anchor: V2(2, 2), yaw: 0.3)
        for (a, b) in zip(world, back) { XCTAssertEqual(SimMath.length(a - b), 0, accuracy: 1e-9) }
        // the anchor came back 0.5 m east after relocalization: the room moves with it
        let moved = h.world(anchor: V2(2.5, 2), yaw: 0.3)
        XCTAssertEqual(moved[0].x, 1.5, accuracy: 1e-9)
        XCTAssertEqual(h.area, 6, accuracy: 1e-9)
    }

    func testRestoredOrders() {
        var r = sampleRecord()
        XCTAssertEqual(r.order(worldLoop: [V2(0, 0), V2(1, 0)]), .pace([V2(0, 0), V2(1, 0)]))
        XCTAssertEqual(r.order(worldLoop: nil), .roam)
        r.behaviour = "stay"
        XCTAssertEqual(r.order(worldLoop: nil), .stay)
        r.behaviour = "bogus"; r.home = nil
        XCTAssertEqual(r.order(worldLoop: nil), .wander)
        XCTAssertEqual(SimEntityRecord.behaviour(of: .goTo([V2(1, 1)])), "roam")
        XCTAssertEqual(SimEntityRecord.behaviour(of: .pace([])), "pace")
        XCTAssertEqual(SimEntityRecord.behaviour(of: .graze), "graze")
    }

    // MARK: naming + ranking

    func testAreaNaming() {
        XCTAssertEqual(PlaceNaming.nextAreaName(existing: []), "Area 1")
        XCTAssertEqual(PlaceNaming.nextAreaName(existing: ["Area 1", "Basement", "Area 3"]), "Area 2")
        XCTAssertEqual(PlaceNaming.clean("  Family Room \n"), "Family Room")
        XCTAssertNil(PlaceNaming.clean("   "))
    }

    func place(_ id: String, used: Double, fails: Int = 0, bytes: Int = 10, ssid: String? = nil) -> PlaceManifest {
        var p = PlaceManifest(id: id, name: id, now: 0)
        p.lastUsed = used; p.failStreak = fails; p.mapBytes = bytes
        if let s = ssid { p.hints = PlaceHints(ssid: s) }
        return p
    }

    func testCandidateOrdering() {
        let ps = [place("old", used: 10), place("new", used: 30), place("mid", used: 20), place("empty", used: 99, bytes: 0)]
        XCTAssertEqual(PlaceRanking.order(ps), ["new", "mid", "old"])            // last used first; no map = skipped
        // a place that timed out 3 times in a row goes after the others
        let ps2 = [place("new", used: 30, fails: 3), place("mid", used: 20), place("old", used: 10)]
        XCTAssertEqual(PlaceRanking.order(ps2), ["mid", "old", "new"])
        // a hint match beats recency
        let ps3 = [place("new", used: 30, ssid: "upstairs"), place("old", used: 10, ssid: "basement")]
        XCTAssertEqual(PlaceRanking.order(ps3, hint: PlaceHints(ssid: "basement")), ["old", "new"])
        XCTAssertEqual(PlaceRanking.order([]), [])
    }

    // MARK: relaunch state machine

    func testRelocalizesFirstCandidate() {
        var t = RelocTracker()
        XCTAssertEqual(t.begin(candidates: ["a", "b"], now: 100), "a")
        XCTAssertTrue(t.isRelocalizing)
        XCTAssertEqual(t.tracking("limited:initializing", now: 100.2), .none)
        XCTAssertEqual(t.tracking("limited:relocalizing", now: 101), .none)
        XCTAssertTrue(t.sawRelocalizing)
        XCTAssertEqual(t.tick(now: 105), .none)
        XCTAssertEqual(t.tracking("normal", now: 104.5), .localized(place: "a", seconds: 4.5))
        XCTAssertTrue(t.isLocalized)
        XCTAssertEqual(t.current, "a")
        XCTAssertEqual(t.tick(now: 200), .none)                                  // localized: never switches
        XCTAssertEqual(t.tracking("limited:excessiveMotion", now: 201), .none)
    }

    func testClockStartsWhenTheRunStarts() {
        var t = RelocTracker()
        _ = t.begin(candidates: ["a", "b"], now: 0)
        t.runStarted(now: 3)                                                     // the map took 3 s to load
        XCTAssertEqual(t.tick(now: 21), .none)
        XCTAssertEqual(t.tracking("normal", now: 7), .localized(place: "a", seconds: 4))
    }

    func testTimeoutTriesNextAndCycles() {
        var t = RelocTracker()
        _ = t.begin(candidates: ["a", "b", "c"], now: 0)
        XCTAssertEqual(t.tick(now: 19.9), .none)
        XCTAssertEqual(t.tick(now: 20), .tryNext(place: "b", failed: "a"))
        XCTAssertEqual(t.elapsed(now: 25), 5, accuracy: 1e-9)
        XCTAssertEqual(t.tick(now: 40), .tryNext(place: "c", failed: "b"))
        XCTAssertEqual(t.tick(now: 60), .tryNext(place: "a", failed: "c"))      // wraps: keeps trying
        XCTAssertEqual(t.rounds, 1)
        XCTAssertEqual(t.tracking("normal", now: 63), .localized(place: "a", seconds: 3))
    }

    func testEarlyNormalIgnoredAndPinnedNeverSwitches() {
        var t = RelocTracker()
        _ = t.begin(candidates: ["a", "b"], now: 0)
        XCTAssertEqual(t.tracking("normal", now: 0.2), .none)                    // too early to trust
        t.pick("b", now: 1)
        XCTAssertEqual(t.current, "b")
        XCTAssertEqual(t.tick(now: 100), .none)                                  // user picked it: stay on it
        t.startFresh()
        XCTAssertEqual(t.phase, .fresh)
        XCTAssertEqual(t.tracking("normal", now: 101), .none)
        var e = RelocTracker()
        XCTAssertNil(e.begin(candidates: [], now: 0))
        XCTAssertEqual(e.phase, .fresh)
    }

    func testManifestLocalizeBookkeeping() {
        var m = PlaceManifest(id: "place-1", name: "x", now: 0)
        m.timedOut(); m.timedOut()
        XCTAssertEqual(m.failStreak, 2)
        m.localized(now: 50, seconds: 3.2)
        XCTAssertEqual(m.failStreak, 0)
        XCTAssertEqual(m.localizeCount, 1)
        XCTAssertEqual(m.lastUsed, 50)
        XCTAssertEqual(m.lastLocalizeSeconds, 3.2)
    }

    // MARK: polygons + room bounds

    func testPolygonBasics() {
        let sq = [V2(0, 0), V2(2, 0), V2(2, 2), V2(0, 2)]
        XCTAssertTrue(Poly.contains(sq, V2(1, 1)))
        XCTAssertFalse(Poly.contains(sq, V2(3, 1)))
        XCTAssertEqual(Poly.area(sq), 4, accuracy: 1e-12)
        XCTAssertEqual(Poly.centroid(sq), V2(1, 1))
        let hull = Poly.convexHull(sq + [V2(1, 1), V2(0.5, 1.5), V2(2, 0)])
        XCTAssertEqual(hull.count, 4)
        XCTAssertGreaterThan(Poly.signedArea(hull), 0)                           // CCW
        XCTAssertEqual(Poly.resample(sq, count: 8).count, 8)
        XCTAssertEqual(Poly.edgeDistance(sq, V2(1, 0.25)), 0.25, accuracy: 1e-12)
    }

    /// Two rooms joined by an 0.8 m door, as the LiDAR floor grid would show them.
    func twoRoomGrid() -> NavGrid {
        let spec = GridSpec(origin: V2(-1, -1), cell: 0.1, nx: 120, ny: 60)      // x -1…11, y -1…5
        var b = NavGridBuilder(spec: spec, refFloor: 0, maxStep: 0.12, maxDrop: 0.15, bodyHeight: 1.0)
        for j in 0..<spec.ny {
            for i in 0..<spec.nx {
                let c = spec.center(i, j)
                let inRoomA = c.x > 0 && c.x < 4.9 && c.y > 0 && c.y < 4
                let inRoomB = c.x > 5.1 && c.x < 10 && c.y > 0 && c.y < 4
                let door = c.x >= 4.9 && c.x <= 5.1 && c.y > 1.6 && c.y < 2.4      // 0.8 m wide
                if inRoomA || inRoomB || door { b.add(c, h: 0) }                    // floor
                else { b.add(c, h: 0); b.add(c, h: 0.5) }                            // wall: something in the body band
            }
        }
        return b.build(inflate: RoomBounds.doorClose, clearAround: V2(2, 2), clearRadius: 0.3)
    }

    func testRoomBoundsStayInTheRoom() throws {
        let g = twoRoomGrid()
        let poly = try XCTUnwrap(RoomBounds.fromGrid(g, spawn: V2(2, 2)))
        XCTAssertTrue(Poly.contains(poly, V2(2, 2)))
        for p in poly { XCTAssertLessThan(p.x, 4.9, "the fill leaked through the door: \(p)") }
        XCTAssertGreaterThan(Poly.area(poly), 4)
        let (home, src) = RoomBounds.home(grid: g, spawn: V2(2, 2))
        XCTAssertEqual(src, .mesh)
        XCTAssertTrue(Poly.contains(home, V2(2, 2)))
    }

    func testRoomBoundsFallbackWithoutFloor() {
        let spec = GridSpec(center: V2(0, 0), half: 3, cell: 0.1)
        let empty = NavGridBuilder(spec: spec, refFloor: 0, maxStep: 0.12, maxDrop: 0.15, bodyHeight: 1).build(inflate: 0.46)
        XCTAssertNil(RoomBounds.fromGrid(empty, spawn: .zero))
        let (home, src) = RoomBounds.home(grid: empty, spawn: V2(0.3, 0.2))
        XCTAssertEqual(src, .radius)
        XCTAssertTrue(Poly.contains(home, V2(0.3, 0.2)))
        XCTAssertEqual(Poly.edgeDistance(home, V2(0.3, 0.2)), RoomBounds.fallbackRadius, accuracy: 0.05)
        XCTAssertEqual(RoomBounds.home(grid: nil, spawn: .zero).source, .radius)
    }

    func testPaceLoopInsideTheRoom() {
        let room = [V2(0, 0), V2(5, 0), V2(5, 4), V2(0, 4)]
        let loop = RoomPatrol.loop(home: room, from: V2(4.5, 0.5), count: 6)
        XCTAssertEqual(loop.count, 6)
        for p in loop { XCTAssertTrue(Poly.contains(room, p)); XCTAssertGreaterThan(Poly.edgeDistance(room, p), 0.5) }
        // starts at the corner nearest the animal
        let nearest = loop.min { SimMath.length($0 - V2(4.5, 0.5)) < SimMath.length($1 - V2(4.5, 0.5)) }!
        XCTAssertEqual(loop[0], nearest)
        XCTAssertEqual(RoomPatrol.loop(home: [V2(0, 0), V2(1, 0)], from: .zero), [])
    }

    // MARK: animals in their room

    func testRoamingAnimalStaysHome() {
        // a big open space, but the deer's home is the 3 × 2.5 m west end: it must never walk out of it
        let world = BoxWorld(minX: 0, minY: 0, maxX: 12, maxY: 6)
        let home = [V2(0.5, 0.5), V2(3.5, 0.5), V2(3.5, 3), V2(0.5, 3)]
        for seed in [1, 2, 3, 4, 5] as [UInt64] {
            var b = AnimalBrain(profile: .deer, pos: V2(2, 1.7), heading: 0, seed: seed)
            b.setHome(home)
            b.setOrder(.roam)
            XCTAssertTrue(b.homeBound)
            var moved = 0.0
            var last = b.state.pos
            for _ in 0..<(30 * 180) {                                           // 3 simulated minutes at 30 Hz
                b.step(dt: 1 / 30, world: world, threats: [Threat(pos: V2(11, 5), kind: .person)])
                moved += SimMath.length(b.state.pos - last)
                last = b.state.pos
                XCTAssertTrue(Poly.contains(home, b.state.pos), "seed \(seed) left home at \(b.state.pos)")
            }
            XCTAssertGreaterThan(moved, 2, "seed \(seed): a roaming deer should move around (\(moved) m)")
        }
    }

    func testPacingAnimalCirclesItsLoop() {
        let world = BoxWorld(minX: 0, minY: 0, maxX: 6, maxY: 5)
        let home = [V2(0.3, 0.3), V2(5.7, 0.3), V2(5.7, 4.7), V2(0.3, 4.7)]
        var b = AnimalBrain(profile: .fox, pos: V2(1, 1), heading: 0, seed: 9)
        b.setHome(home)
        let loop = RoomPatrol.loop(home: home, from: b.state.pos, count: 5)
        b.setOrder(.pace(loop))
        var visited = Set<Int>()
        var lastIdx = b.paceIndex
        for _ in 0..<(30 * 120) {
            b.step(dt: 1 / 30, world: world, threats: [])
            if b.paceIndex != lastIdx { visited.insert(lastIdx); lastIdx = b.paceIndex }
            XCTAssertTrue(Poly.contains(home, b.state.pos))
        }
        XCTAssertEqual(visited.count, 5, "it should reach every corner of the loop in 2 min (visited \(visited.sorted()))")
        if case .pace = b.order {} else { XCTFail("still pacing") }
    }

    func testPacingSkipsAnUnreachableCorner() {
        // a box sits right on corner 1: the animal gives up on it after a few seconds and walks on
        let world = BoxWorld(minX: 0, minY: 0, maxX: 6, maxY: 5, boxes: [(V2(3.6, 0.6), V2(4.4, 1.4))])
        var b = AnimalBrain(profile: .rabbit, pos: V2(1, 1), heading: 0, seed: 3)
        b.setHome([V2(0.2, 0.2), V2(5.8, 0.2), V2(5.8, 4.8), V2(0.2, 4.8)])
        b.setOrder(.pace([V2(1, 1), V2(4, 1), V2(4, 4), V2(1, 4)]))
        var reachedThird = false
        for _ in 0..<(30 * 90) {
            b.step(dt: 1 / 30, world: world, threats: [])
            if b.paceIndex >= 2 { reachedThird = true }
        }
        XCTAssertTrue(reachedThird)
    }

    func testScaredAnimalComesHome() {
        let world = BoxWorld(minX: 0, minY: 0, maxX: 12, maxY: 6)
        let home = [V2(4, 1), V2(8, 1), V2(8, 5), V2(4, 5)]
        var b = AnimalBrain(profile: .deer, pos: V2(4.4, 3), heading: 0, seed: 11)
        b.setHome(home)
        b.setOrder(.roam)
        // a person right beside it, on the inside: it bolts out of the west side
        for _ in 0..<30 { b.step(dt: 1 / 30, world: world, threats: [Threat(pos: V2(5.2, 3), kind: .person)]) }
        for _ in 0..<(30 * 6) { b.step(dt: 1 / 30, world: world, threats: [Threat(pos: V2(5.2, 3), kind: .person)]) }
        let wasOut = !Poly.contains(home, b.state.pos)
        // the person leaves; within a minute and a half it is back inside
        var back = false
        for _ in 0..<(30 * 90) {
            b.step(dt: 1 / 30, world: world, threats: [Threat(pos: V2(11.5, 5.5), kind: .person)])
            if Poly.contains(home, b.state.pos) { back = true; break }
        }
        XCTAssertTrue(wasOut, "the scare should have chased it out (at \(b.state.pos))")
        XCTAssertTrue(back, "it should walk back into its room (at \(b.state.pos))")
    }
}
