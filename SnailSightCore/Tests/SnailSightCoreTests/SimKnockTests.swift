import XCTest
@testable import SnailSightCore

/// 9.9: knocked / kicked animals, surfaces from normals, elevated nav edges, robot-on-table, cube deletion + undo,
/// Scans fly schemes.
final class SimKnockTests: XCTestCase {

    // MARK: shapes

    func testAnimalShapeCapsuleForCompactUprightBoxForLong() {
        // rabbit 0.232 × 0.35 × 0.226 → capsule; deer 1.5 long × 0.786 wide → box
        guard case .capsule(let r, let h) = AnimalShape.choose(size: SIMD3(0.232, 0.35, 0.226)) else {
            return XCTFail("rabbit should be a capsule")
        }
        XCTAssertEqual(r, 0.45 * 0.232, accuracy: 1e-9)
        XCTAssertEqual(h, 0.35, accuracy: 1e-9)
        guard case .box(let s) = AnimalShape.choose(size: SIMD3(1.5, 1.668, 0.786)) else { return XCTFail("deer box") }
        XCTAssertEqual(s.x, 1.35, accuracy: 1e-9)
        XCTAssertEqual(s.z, 0.786, accuracy: 1e-9)
        // the shape scales with the body (Sim scale): half size → half the capsule
        guard case .capsule(let r2, let h2) = AnimalShape.choose(size: SIMD3(0.116, 0.175, 0.113)) else { return XCTFail() }
        XCTAssertEqual(r2, r / 2, accuracy: 1e-9)
        XCTAssertEqual(h2, h / 2, accuracy: 1e-9)
        // a capsule is never shorter than its two caps
        if case .capsule(let r3, let h3) = AnimalShape.choose(size: SIMD3(0.3, 0.25, 0.3)) { XCTAssertGreaterThanOrEqual(h3, 2 * r3) }
        XCTAssertEqual(AnimalShape.box(SIMD3(1, 0.6, 0.4)).centreHeight, 0.3, accuracy: 1e-9)
    }

    // MARK: impacts

    func testImpactMomentumTransfer() {
        let n = SIMD3<Double>(1, 0, 0)
        // a heavy robot into a light animal: ~(1 + e) × its speed
        let dv = Impact.deltaV(hitterMass: 60, animalMass: 1, closingSpeed: 0.4, normal: n)
        XCTAssertEqual(dv.x, 1.3 * 60 / 61 * 0.4, accuracy: 1e-9)
        XCTAssertTrue(Impact.shouldKnock(dv))
        XCTAssertFalse(Impact.tumbles(dv))
        // a light ball into a deer: barely moves it → startle only
        let small = Impact.deltaV(hitterMass: 0.35, animalMass: 57, closingSpeed: 3, normal: n)
        XCTAssertFalse(Impact.shouldKnock(small))
        // moving apart / no mass: nothing
        XCTAssertEqual(Impact.deltaV(hitterMass: 1, animalMass: 1, closingSpeed: -1, normal: n), .zero)
        // capped
        let huge = Impact.deltaV(hitterMass: 1000, animalMass: 0.1, closingSpeed: 50, normal: SIMD3(0, 0, 2))
        XCTAssertEqual(huge.z, Impact.maxDV, accuracy: 1e-9)
        XCTAssertEqual(Impact.impulse(massKg: 2, dv: SIMD3(3, 0, 4)), 10, accuracy: 1e-9)
        XCTAssertTrue(Impact.tumbles(SIMD3(1.2, 0, 0)))
    }

    func testLiftAndSpin() {
        let l = Impact.withLift(SIMD3(2, 0, 0))
        XCTAssertEqual(l.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(Impact.withLift(SIMD3(2, 1, 0)).y, 1, accuracy: 1e-9)     // already going up: kept
        // hit along +x → roll over about −z (axis = up × dir), rate capped
        let w = Impact.spin(SIMD3(2, 0, 0), height: 0.4)
        XCTAssertEqual(w.x, 0, accuracy: 1e-9)
        XCTAssertLessThan(w.z, 0)
        XCTAssertLessThanOrEqual(abs(w.z), 12 + 1e-9)
        XCTAssertEqual(Impact.spin(SIMD3(0, 3, 0), height: 0.4), .zero)
    }

    func testKickFromAQuickFlick() throws {
        let fwd = SIMD3<Double>(0, -0.3, -1)                        // looking down at the floor ahead (−z)
        // flick straight up the screen → away from you (−z), lifted
        let v = try XCTUnwrap(Kick.velocity(screenVelocity: SIMD2(0, -1500), duration: 0.15, cameraForward: fwd))
        XCTAssertLessThan(v.z, -1)
        XCTAssertEqual(v.x, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(v.y, 0)
        XCTAssertEqual(SimMath.length(V2(v.x, v.z)), 3.3, accuracy: 1e-9)    // 1500 pt/s → 3.3 m/s
        // flick right → camera right (+x when looking along −z)
        let r = try XCTUnwrap(Kick.velocity(screenVelocity: SIMD2(2000, 0), duration: 0.2, cameraForward: fwd))
        XCTAssertGreaterThan(r.x, 0)
        // a slow drag or a long press-and-drag is not a kick
        XCTAssertNil(Kick.velocity(screenVelocity: SIMD2(0, -400), duration: 0.15, cameraForward: fwd))
        XCTAssertNil(Kick.velocity(screenVelocity: SIMD2(0, -1500), duration: 0.8, cameraForward: fwd))
        // very fast flicks are capped
        let fast = try XCTUnwrap(Kick.velocity(screenVelocity: SIMD2(0, -9000), duration: 0.1, cameraForward: fwd))
        XCTAssertEqual(SimMath.length(V2(fast.x, fast.z)), Kick.maxSpeed, accuracy: 1e-9)
    }

    // MARK: knock state machine

    func testKnockAirborneSettleRecover() {
        var s = KnockState()
        XCTAssertEqual(Knock.step(&s, dt: 0.1, speed: 0, spin: 0), .none)        // not knocked: nothing
        XCTAssertEqual(Knock.begin(&s, source: .kick, y: 0.75, tumble: true), .began)
        XCTAssertEqual(s.phase, .airborne)
        // still moving: stays airborne
        for _ in 0..<10 { XCTAssertEqual(Knock.step(&s, dt: 0.05, speed: 1.5, spin: 4), .none) }
        // slow but inside the minimum air time does not count (it is just leaving the ground)
        var t = KnockState()
        Knock.begin(&t, source: .robot, y: 0, tumble: false)
        XCTAssertEqual(Knock.step(&t, dt: 0.1, speed: 0, spin: 0), .none)
        XCTAssertEqual(t.still, 0)
        // at rest long enough → settled → recovering → recovered
        var ev = KnockEvent.none
        for _ in 0..<20 where ev == .none { ev = Knock.step(&s, dt: 0.05, speed: 0.02, spin: 0.1) }
        XCTAssertEqual(ev, .settled(timedOut: false))
        XCTAssertEqual(s.phase, .recovering)
        XCTAssertEqual(Knock.recoverFraction(s), 0, accuracy: 1e-9)
        Knock.step(&s, dt: 0.3, speed: 0, spin: 0)
        XCTAssertEqual(Knock.recoverFraction(s), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Knock.step(&s, dt: 0.31, speed: 0, spin: 0), .recovered)
        XCTAssertEqual(s.phase, .none)
        XCTAssertTrue(s.tumbled)
        XCTAssertEqual(s.startY, 0.75)
    }

    func testKnockTimesOutAndRehitRestarts() {
        var s = KnockState()
        Knock.begin(&s, source: .object, y: 0, tumble: false)
        var ev = KnockEvent.none
        var n = 0
        while ev == .none && n < 200 { ev = Knock.step(&s, dt: 0.1, speed: 0.5, spin: 0); n += 1 }  // jittering forever
        XCTAssertEqual(ev, .settled(timedOut: true))
        XCTAssertEqual(Double(n) * 0.1, KnockParams().maxAirTime, accuracy: 0.11)
        // hit again while standing up: airborne again, first height kept for the drop log? no — a new knock
        Knock.begin(&s, source: .fling, y: 0.4, tumble: false)
        XCTAssertEqual(s.phase, .airborne)
        XCTAssertEqual(s.startY, 0.4)
        // a re-hit in the air keeps the start height and counts hits
        Knock.step(&s, dt: 0.2, speed: 2, spin: 0)
        Knock.begin(&s, source: .animal, y: 0.1, tumble: true)
        XCTAssertEqual(s.startY, 0.4)
        XCTAssertEqual(s.hits, 2)
        XCTAssertEqual(s.t, 0)
        XCTAssertEqual(s.source, .animal)
    }

    func testUprightHeading() {
        XCTAssertEqual(Knock.uprightHeading(forward: SIMD3(1, 0, 0), fallback: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(Knock.uprightHeading(forward: SIMD3(0, 0, -1), fallback: 2), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(Knock.uprightHeading(forward: SIMD3(0.05, 1, 0), fallback: 2), 2)   // on its nose: keep
    }

    // MARK: surfaces

    func testSurfaceClassificationFromNormals() {
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(0, 1, 0), height: 0, floorY: 0), .floor)
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(0.1, 1, 0.05), height: 0.75, floorY: 0), .elevated)
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(0, 2, 0), height: 0.08, floorY: 0), .floor)   // a rug
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(0, 1, 0), height: 0.75, floorY: nil), .floor)  // unknown floor
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(1, 0, 0), height: 1, floorY: 0), .wall)
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(0, -1, 0), height: 2.4, floorY: 0), .ceiling)
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(1, 1, 0), height: 0.3, floorY: 0), .steep)    // 45°
        // 25° boundary
        let a = 24 * Double.pi / 180, b = 26 * Double.pi / 180
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(sin(a), cos(a), 0), height: 0, floorY: 0), .floor)
        XCTAssertEqual(SurfaceClass.classify(normal: SIMD3(sin(b), cos(b), 0), height: 0, floorY: 0), .steep)
        XCTAssertTrue(SurfaceClass.standable(.elevated))
        XCTAssertFalse(SurfaceClass.standable(.wall))
    }

    func testFloorEstimate() {
        var f = FloorEstimate()
        f.note(surfaceY: 0.75, cameraY: 1.5)          // first a table top (0.75 below the phone)
        XCTAssertEqual(f.y, 0.75)
        f.note(surfaceY: 0.0, cameraY: 1.5)           // then the real floor: lower wins
        XCTAssertEqual(f.y, 0)
        f.note(surfaceY: 0.75, cameraY: 1.5)          // tables never raise it
        XCTAssertEqual(f.y, 0)
        f.note(surfaceY: 1.4, cameraY: 1.5)           // right under the phone: not a floor
        f.note(surfaceY: -3, cameraY: 1.5)            // a stairwell far below: ignored
        XCTAssertEqual(f.y, 0)
        f.note(surfaceY: 0.02, cameraY: 1.5)          // noise smooths
        XCTAssertEqual(f.y ?? -1, 0.002, accuracy: 1e-9)
    }

    func testElevatedEdgesAndHopDown() {
        let step = AnimalReach.maxStep(scale: 1), drop = AnimalReach.maxDrop(scale: 1)
        let hop = ElevatedNav.hopDown(height: 0.3, scale: 1)                // a cat
        XCTAssertEqual(hop, 0.75, accuracy: 1e-9)
        XCTAssertEqual(ElevatedNav.hopDown(height: 1.7, scale: 1), 1.2)     // capped
        XCTAssertEqual(ElevatedNav.hopDown(height: 0.01, scale: 0.5), AnimalReach.maxDrop(scale: 0.5))
        func c(_ new: Double?, hop mayHop: Bool) -> EdgeStep {
            ElevatedNav.classify(currentFloor: 0.75, newFloor: new, maxStep: step, maxDrop: drop, hopDown: hop, mayHop: mayHop)
        }
        XCTAssertEqual(c(0.76, hop: false), .ok)            // across the table top
        XCTAssertEqual(c(0.0, hop: false), .edge)           // table edge: a calm animal stays up there
        XCTAssertEqual(c(0.0, hop: true), .hop)             // fleeing: hops down 0.75 m
        XCTAssertEqual(c(-0.5, hop: true), .edge)           // too deep even when fleeing
        XCTAssertEqual(c(nil, hop: true), .edge)            // nothing scanned below: never step into the void
        XCTAssertEqual(c(1.2, hop: true), .wall)            // a shelf above
        XCTAssertTrue(ElevatedNav.passable(.hop))
        XCTAssertFalse(ElevatedNav.passable(.edge))
    }

    // MARK: elevated nav patch (table top) + robot fit

    /// Floor 4 × 4 m at 0, a table top (w × d) at 0.75 m centred on the origin.
    func tableGrid(w: Double, d: Double, inflate: Double) -> NavGrid {
        var b = NavGridBuilder(spec: GridSpec(center: .zero, half: 1.2, cell: 0.05), refFloor: 0.75, maxStep: 0.03,
                               maxDrop: 0.04, bodyHeight: 0.3)
        func quad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ h: Double) {
            b.addTriangle((V2(x0, y0), h), (V2(x1, y0), h), (V2(x1, y1), h))
            b.addTriangle((V2(x0, y0), h), (V2(x1, y1), h), (V2(x0, y1), h))
        }
        quad(-2, -2, 2, 2, 0)
        quad(-w / 2, -d / 2, w / 2, d / 2, 0.75)
        return b.build(inflate: inflate)
    }

    func testElevatedPatchEdges() {
        let g = tableGrid(w: 1.0, d: 0.6, inflate: 0)
        func cell(_ x: Double, _ y: Double) -> NavCell {
            let (i, j) = g.spec.index(V2(x, y))!
            return g.at(i, j)
        }
        XCTAssertNotEqual(cell(0, 0), .hard)                   // on the table
        XCTAssertNotEqual(cell(0.45, 0.25), .hard)             // near the corner, still on it
        XCTAssertEqual(cell(0.6, 0), .hard)                    // off the long edge: a 0.75 m drop
        XCTAssertEqual(cell(0, 0.4), .hard)                    // off the short edge
        XCTAssertEqual(cell(1.0, 1.0), .hard)
        let (ci, cj) = g.spec.index(.zero)!
        XCTAssertEqual(g.floorAt(ci, cj) ?? -1, 0.75, accuracy: 1e-9)
        // A* stays on the table and refuses the floor below
        if case .success(let path) = AStar.plan(g, from: V2(-0.35, 0), to: V2(0.35, 0)) {
            XCTAssertTrue(path.allSatisfy { abs($0.x) <= 0.5 && abs($0.y) <= 0.3 })
        } else { XCTFail("a path across the table") }
        if case .success = AStar.plan(g, from: V2(0, 0), to: V2(1.0, 0), goalSnap: 0.1) { XCTFail("walked off the table") }
    }

    func testRobotOnTables() {
        let r = RobotProfile.robosnailbob.scaled(0.5).agentRadius          // ~0.21 m at 50 %
        XCTAssertTrue(RobotSurface.fits(tableGrid(w: 1.6, d: 0.9, inflate: r), at: .zero))      // dining table
        XCTAssertFalse(RobotSurface.fits(tableGrid(w: 0.3, d: 0.3, inflate: r), at: .zero))     // stool / side table
        XCTAssertFalse(RobotSurface.fits(tableGrid(w: 1.6, d: 0.9, inflate: r), at: V2(0.75, 0)))   // at the edge
        let mass50 = 60 * 0.125, mass100 = 60.0
        XCTAssertEqual(RobotSurface.check(kind: .elevated, robotMassKg: mass50, fits: true), .ok)
        XCTAssertEqual(RobotSurface.check(kind: .elevated, robotMassKg: mass50, fits: false), .tooSmall)
        XCTAssertEqual(RobotSurface.check(kind: .elevated, robotMassKg: mass100, fits: true), .tooHeavy)
        XCTAssertEqual(RobotSurface.check(kind: .floor, robotMassKg: mass100, fits: false), .ok)
        XCTAssertEqual(RobotSurface.check(kind: .wall, robotMassKg: mass50, fits: true), .notStandable)
        XCTAssertNil(RobotSurface.hint(.ok, robotMassKg: 1))
        XCTAssertNotNil(RobotSurface.hint(.tooHeavy, robotMassKg: 60))
    }

    // MARK: cubes + undo

    func item(_ key: String, _ size: [Double], shape: SimPhysicsSpec.Shape = .box, animal: Bool = false) -> SimCatalogItem {
        SimCatalogItem(key: key, label: key, category: animal ? .animal : .object, group: "g", symbol: "cube",
                       sizeM: size, physics: animal ? nil : SimPhysicsSpec(shape: shape, massKg: 1, friction: 0.5, restitution: 0.1))
    }

    func testWhatCountsAsACube() {
        XCTAssertTrue(SimCubes.isCube(item("blocks", [0.06, 0.06, 0.06])))
        XCTAssertTrue(SimCubes.isCube(item("crate", [0.3, 0.3, 0.3])))
        XCTAssertTrue(SimCubes.isCube(item("cardboard", [0.227, 0.3, 0.227])))
        XCTAssertFalse(SimCubes.isCube(item("book", [0.24, 0.125, 0.175])))
        XCTAssertFalse(SimCubes.isCube(item("ball", [0.2, 0.2, 0.2], shape: .sphere)))
        XCTAssertFalse(SimCubes.isCube(item("rabbit", [0.232, 0.35, 0.226], animal: true)))
    }

    func testUndoWindow() {
        var u = UndoBuffer<Int>()
        XCTAssertFalse(u.canUndo(now: 0))
        u.record([], label: "nothing", now: 0)
        XCTAssertFalse(u.canUndo(now: 0))
        u.record([1, 2], label: "Deleted 2 cubes", now: 10)
        XCTAssertTrue(u.canUndo(now: 14.9))
        XCTAssertEqual(u.remaining(now: 12), 3, accuracy: 1e-9)
        XCTAssertEqual(u.undo(now: 14.9), [1, 2])
        XCTAssertEqual(u.undo(now: 14.9), [])                     // once
        u.record([3], label: "Deleted cube #3", now: 20)
        u.record([4], label: "Deleted cube #4", now: 21)          // newer replaces
        XCTAssertEqual(u.label, "Deleted cube #4")
        XCTAssertEqual(u.undo(now: 26.5), [])                     // 5.5 s later: too late
        u.record([5], label: "x", now: 30)
        u.expire(now: 36)
        XCTAssertFalse(u.canUndo(now: 30))
    }

    func testCubeLedgerDeleteUndoClear() {
        var l = CubeLedger<String>()
        let a = l.add(id: "a", item: "A"), b = l.add(id: "b", item: "B"), c = l.add(id: "c", item: "C")
        XCTAssertEqual([a, b, c], [1, 2, 3])
        let gone = l.remove(["b"])
        XCTAssertEqual(gone.map { $0.number }, [2])
        XCTAssertEqual(l.map { $0.id }, ["a", "c"])
        XCTAssertEqual(l.add(id: "d", item: "D"), 4)                // numbers never reused while undo is possible
        // undo with a re-created id: back in order, same number
        var back = gone
        back[0].id = "b2"
        l.restore(back)
        XCTAssertEqual(l.map { $0.number }, [1, 2, 3, 4])
        XCTAssertEqual(l.entry("b2")?.item, "B")
        let all = l.removeAll()
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(l.isEmpty)
        l.restore(all)
        XCTAssertEqual(l.count, 4)
        l.restore(all)                                              // idempotent
        XCTAssertEqual(l.count, 4)
        l.reset()
        XCTAssertEqual(l.add(id: "z", item: "Z"), 1)
    }

    // MARK: Scans fly schemes

    #if canImport(simd)   // FlyControl lives in simd-based ScanDrone.swift (excluded on Linux CI)
    func testFlySchemes() {
        let m = FlyControl.input(.minimal, move: SIMD2(0, 1), look: SIMD2(1, 0), climb: 3)
        XCTAssertEqual(m.look, .zero)                     // minimal: looking is the drag gesture
        XCTAssertEqual(m.move, SIMD2(0, 1))
        XCTAssertEqual(m.climb, 1)
        XCTAssertEqual(FlyControl.input(.advanced, move: .zero, look: SIMD2(1, 0), climb: 0).look, SIMD2(1, 0))
        XCTAssertEqual(FlyControl.nextSpeed(after: 0.5), 1.2)
        XCTAssertEqual(FlyControl.nextSpeed(after: 5), 0.5)          // wraps
        XCTAssertEqual(FlyControl.nextSpeed(after: 0.9), 1.2)
        XCTAssertEqual(FlyScheme.allCases.first, .minimal)           // the default
    }
    #endif
}
