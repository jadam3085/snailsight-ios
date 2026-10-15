import XCTest
@testable import SnailSightCore

/// 9.4 (owner feedback on 9.3.65): robot scale, support physics on mesh changes, selection, commands, path planning.

final class SimScaleTests: XCTestCase {
    /// Owner: "RobosnailBob spawns in sim about double its actual size". The drawn robot is generated from these parts,
    /// so its spawned bounding box must be the real robot (hardware.yml Q6 Edge 2.0: 32.23 × 24.4 in, lidar top ≈ 0.61 m).
    func testSpawnedBoundingBoxIsRealSize() {
        let b = RobotModel.bounds(RobotModel.parts())
        let real = SIMD3(0.82, 0.61, 0.62)                 // length, height, width
        for k in 0..<3 {
            XCTAssertEqual(b.extents[k], real[k], accuracy: 0.03, "axis \(k): \(b.extents[k]) m")
            XCTAssertLessThan(b.extents[k], real[k] * 1.1, "never oversized (axis \(k))")
        }
        XCTAssertEqual(b.min.y, 0, accuracy: 1e-9)          // feet on the floor
        XCTAssertEqual(b.center.x, 0, accuracy: 0.01)       // centred on the spawn point
        XCTAssertEqual(b.center.z, 0, accuracy: 1e-9)
    }

    func testWheelIsRadiusNotDiameter() {
        let p = RobotProfile.robosnailbob
        let wheel = RobotModel.parts().first { $0.name == "wheel.left" }!
        XCTAssertEqual(wheel.radius, p.wheelRadius, accuracy: 1e-12)          // drawn with radius = size / 2
        XCTAssertEqual(wheel.size.y, 2 * p.wheelRadius, accuracy: 1e-12)      // touches the floor, no more
        XCTAssertEqual(wheel.center.y - wheel.radius, 0, accuracy: 1e-12)
        XCTAssertEqual(abs(wheel.center.z) * 2, p.trackWidth, accuracy: 1e-12)
        XCTAssertLessThan(wheel.center.z, 0)                                   // left = +URDF y = −z
    }

    func testCollisionFootprintMatchesDrawing() {
        let p = RobotProfile.robosnailbob
        let e = SimKind.robot.size
        XCTAssertEqual(e.x, p.length, accuracy: 0.01)
        XCTAssertEqual(e.z, p.width, accuracy: 0.01)
        XCTAssertEqual(e.y, p.height, accuracy: 0.01)
    }

    func testBoundsMaths() {
        let a = Bounds3(center: SIMD3(0, 0, 0), size: SIMD3(2, 2, 2))
        XCTAssertEqual(a.min, SIMD3(-1, -1, -1))              // size = full extent (RealityKit generateBox semantics)
        XCTAssertTrue(a.intersects(Bounds3(center: SIMD3(1.5, 0, 0), size: SIMD3(1.2, 1, 1))))
        XCTAssertFalse(a.intersects(Bounds3(center: SIMD3(2.5, 0, 0), size: SIMD3(0.8, 1, 1))))
    }
}

final class SupportPhysicsTests: XCTestCase {
    let dt = 1.0 / 30

    func testRestsWhenSupported() {
        var s = SupportState(bottom: 0.5)
        for _ in 0..<30 { XCTAssertEqual(SupportPhysics.step(&s, support: 0.495, dt: dt, popUp: 0.05), .none) }
        XCTAssertEqual(s.bottom, 0.5)
        XCTAssertFalse(s.falling)
    }

    /// The owner's case: a block on a box; the box is moved away and the mesh now shows the floor 0.5 m lower.
    func testFallsWhenSupportRemovedAndLandsOnFloor() {
        var s = SupportState(bottom: 0.5)
        XCTAssertEqual(SupportPhysics.step(&s, support: 0.0, dt: dt, popUp: 0.05), .startedFalling)
        var landed: Double?
        var t = dt
        for _ in 0..<60 {
            t += dt
            if case .landed(let d) = SupportPhysics.step(&s, support: 0.0, dt: dt, popUp: 0.05) { landed = d; break }
        }
        XCTAssertEqual(landed ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.bottom, 0)
        XCTAssertEqual(t, (2 * 0.5 / 9.81).squareRoot(), accuracy: 0.08)      // free fall time, ±a couple of frames
        XCTAssertEqual(SupportPhysics.step(&s, support: 0.0, dt: dt, popUp: 0.05), .none)   // settled
    }

    func testNeverInventsAFloor() {
        var s = SupportState(bottom: 0.5)
        XCTAssertEqual(SupportPhysics.step(&s, support: nil, dt: dt, popUp: 0.05), .unsupported)
        XCTAssertEqual(s.bottom, 0.5)                       // holds until the mesh shows what is below
        XCTAssertTrue(s.unsupported)
        XCTAssertEqual(SupportPhysics.step(&s, support: nil, dt: dt, popUp: 0.05), .none)
        XCTAssertEqual(SupportPhysics.step(&s, support: 0.1, dt: dt, popUp: 0.05), .startedFalling)
    }

    func testPopsOntoARisingSurfaceButNotThroughAWall() {
        var s = SupportState(bottom: 0)
        guard case .poppedUp(let r) = SupportPhysics.step(&s, support: 0.04, dt: dt, popUp: 0.06) else {
            return XCTFail("expected pop up")
        }
        XCTAssertEqual(r, 0.04, accuracy: 1e-12)
        XCTAssertEqual(s.bottom, 0.04)
        XCTAssertEqual(SupportPhysics.step(&s, support: 0.5, dt: dt, popUp: 0.06), .none)   // not lifted 46 cm
        XCTAssertEqual(s.bottom, 0.04)
    }

    func testProbeFanAgreement() {
        // centre over the table: on the table
        XCTAssertEqual(SupportPhysics.supportHeight(hits: [0.75, 0.75, 0.0, 0.0, 0.0]), 0.75)
        // centre off the edge but two corners on it: still held (hangs over the edge)
        XCTAssertEqual(SupportPhysics.supportHeight(hits: [0.0, 0.75, 0.75, 0.0, 0.0]), 0.75)
        // one corner on a lip only: falls to the floor
        XCTAssertEqual(SupportPhysics.supportHeight(hits: [0.0, 0.3, 0.0, 0.0, 0.0]), 0.0)
        XCTAssertNil(SupportPhysics.supportHeight(hits: [nil, nil, nil]))
        XCTAssertEqual(SupportPhysics.supportHeight(hits: [nil, 0.2, nil, nil, 0.2]), 0.2)
    }

    func testWakeOnlyBodiesOverTheChangedMesh() {
        let cols = [
            SupportWake.column(center: SIMD3(0, 0.5, 0), halfXZ: 0.1, bottom: 0.5, top: 0.7),
            SupportWake.column(center: SIMD3(3, 0.0, 0), halfXZ: 0.1, bottom: 0.0, top: 0.2),
        ]
        let boxMoved = Bounds3(min: SIMD3(-0.3, 0, -0.3), max: SIMD3(0.3, 0.5, 0.3))
        XCTAssertEqual(SupportWake.affected(columns: cols, regions: [boxMoved]), [0])
        let ceiling = Bounds3(min: SIMD3(-1, 2.3, -1), max: SIMD3(4, 2.5, 1))          // above everyone: nobody
        XCTAssertEqual(SupportWake.affected(columns: cols, regions: [ceiling]), [])
        XCTAssertEqual(SupportWake.affected(columns: cols, regions: []), [])
    }

    func testMeshChangeQueueThrottlesAndMerges() {
        var q = MeshChangeQueue(interval: 0.25, settleDelay: 0.2)
        let a = Bounds3(center: SIMD3(0, 0, 0), size: SIMD3(1, 1, 1))
        q.mark(a, now: 0)
        q.mark(Bounds3(center: SIMD3(0.4, 0, 0), size: SIMD3(1, 1, 1)), now: 0.05)       // overlaps: merged
        q.mark(Bounds3(center: SIMD3(5, 0, 0), size: SIMD3(1, 1, 1)), now: 0.06)
        XCTAssertEqual(q.pending.count, 2)
        XCTAssertEqual(q.take(now: 0.1), [])                 // still settling (RealityKit rebuilds collision)
        let got = q.take(now: 0.21)
        XCTAssertEqual(got.count, 2)
        XCTAssertTrue(q.isEmpty)
        q.mark(a, now: 0.3)
        XCTAssertEqual(q.take(now: 0.31), [])                // settle delay
        XCTAssertEqual(q.take(now: 0.45), [])                // throttle: < 0.25 s since the last pass
        XCTAssertEqual(q.take(now: 0.5).count, 1)
    }
}

final class SimPickTests: XCTestCase {
    func testPicksNearestAlongRay() {
        let bodies = [
            PickBody(id: 1, center: SIMD3(0, 0.3, -2), size: SIMD3(0.82, 0.61, 0.62), yaw: 0),
            PickBody(id: 2, center: SIMD3(0, 0.3, -4), size: SIMD3(1.5, 1.4, 0.45), yaw: 0),
        ]
        let cam = SIMD3(0.0, 1.2, 0.0)
        let toRobot = SIMD3(0.0, 0.3, -2) - cam
        XCTAssertEqual(SimPick.pick(origin: cam, dir: toRobot / (toRobot * toRobot).sum().squareRoot(), bodies: bodies), 1)
        let up = SIMD3(0.0, 1, 0)
        XCTAssertNil(SimPick.pick(origin: cam, dir: up, bodies: bodies))
    }

    func testYawIsRespected() {
        // a 1.5 m long, 0.3 m wide body facing +x (θ = 0): a ray 0.6 m to its side along −z misses when θ = 0 …
        let along = PickBody(id: 1, center: SIMD3(0, 0, 0), size: SIMD3(1.5, 0.4, 0.3), yaw: 0)
        let origin = SIMD3(0.6, 0.0, 3.0), dir = SIMD3(0.0, 0, -1)
        XCTAssertNotNil(SimPick.rayBox(origin: origin, dir: dir, body: along))         // x = 0.6 is inside 0.75
        // … and hits nothing once it is turned 90° (now long along ground y = −z, narrow in x)
        var turned = along
        turned.yaw = .pi / 2
        XCTAssertNil(SimPick.rayBox(origin: origin, dir: dir, body: turned))
        // forward axis convention: θ = 90° faces ground +y = world −z
        let f = SimPick.forward(yaw: .pi / 2)
        XCTAssertEqual(f.x, 0, accuracy: 1e-12); XCTAssertEqual(f.z, -1, accuracy: 1e-12)
    }

    func testSmallBodiesGetAFingerSizedTarget() {
        let rabbit = PickBody(id: 7, center: SIMD3(0, 0.1, -1), size: SIMD3(0.1, 0.1, 0.1), yaw: 0)
        // 11 cm to the side of a 10 cm box: missed by geometry, hit thanks to the 25 cm minimum pick size
        XCTAssertEqual(SimPick.pick(origin: SIMD3(0.11, 0.1, 0), dir: SIMD3(0, 0, -1), bodies: [rabbit]), 7)
        XCTAssertNil(SimPick.pick(origin: SIMD3(0.2, 0.1, 0), dir: SIMD3(0, 0, -1), bodies: [rabbit]))
    }

    func testBehindTheCameraIsNotPicked() {
        let b = PickBody(id: 1, center: SIMD3(0, 0, 2), size: SIMD3(1, 1, 1), yaw: 0)
        XCTAssertNil(SimPick.pick(origin: .zero, dir: SIMD3(0, 0, -1), bodies: [b]))
    }
}

final class SimCommandSetTests: XCTestCase {
    func testCommandsPerKind() {
        let robot = SimCommand.available(for: .robot)
        XCTAssertTrue(robot.contains(.goTo) && robot.contains(.follow) && robot.contains(.stop) && robot.contains(.patrol))
        XCTAssertFalse(robot.contains(.flee) || robot.contains(.graze))
        for k in [SimKind.deer, .fox, .rabbit] {
            let a = SimCommand.available(for: k)
            for c in [SimCommand.goTo, .follow, .flee, .graze, .stay, .wander, .move, .rotateLeft, .duplicate, .delete] {
                XCTAssertTrue(a.contains(c), "\(k) \(c)")
            }
        }
        XCTAssertEqual(SimCommand.available(for: .block), [.move, .rotateLeft, .rotateRight, .duplicate, .delete])
        XCTAssertTrue(SimCommand.goTo.needsPoint && SimCommand.move.needsPoint && SimCommand.patrol.needsPoint)
        XCTAssertFalse(SimCommand.follow.needsPoint)
    }

    func testRobotAgendaTransitions() {
        var a = RobotAgenda()
        XCTAssertEqual(a.task, .manual)
        XCTAssertFalse(a.isAutonomous)
        a.goTo(V2(2, 1))
        XCTAssertEqual(a.goal(phone: .zero), V2(2, 1))
        a.arrived()
        XCTAssertEqual(a.task, .stopped)
        a.patrol([V2(0, 0), V2(3, 0), V2(3, 2)])
        XCTAssertEqual(a.goal(phone: .zero), V2(0, 0))
        a.arrived(); a.arrived()
        XCTAssertEqual(a.goal(phone: .zero), V2(3, 2))
        a.arrived()
        XCTAssertEqual(a.goal(phone: .zero), V2(0, 0))          // wraps
        a.follow()
        XCTAssertEqual(a.goal(phone: V2(5, 5)), V2(5, 5))
        XCTAssertEqual(a.stopDistance, RobotAgenda.followDistance)
        a.arrived()
        XCTAssertEqual(a.task, .follow)                          // keeps following
        a.stickMoved()
        XCTAssertEqual(a.task, .manual)                          // the joystick always wins
        a.patrol([V2(1, 1)])
        XCTAssertEqual(a.task, .goTo(V2(1, 1)))                  // one point = Go to
        a.stop()
        XCTAssertNil(a.goal(phone: .zero))
    }
}

/// Synthetic scene meshes → NavGrid → A*.
final class SimNavTests: XCTestCase {
    let p = RobotProfile.robosnailbob

    /// Floor quad + optional extra triangles, as world triangles (ground point, height).
    private func builder(_ spec: GridSpec, floorH: Double = 0, extra: [((V2, Double), (V2, Double), (V2, Double))] = [],
                         floorHole: (V2, V2)? = nil) -> NavGridBuilder {
        var b = NavGridBuilder(spec: spec, refFloor: 0, maxStep: p.maxStep, maxDrop: p.maxDrop, bodyHeight: p.height)
        // floor as 0.25 m tiles (LiDAR floors are big triangles; the builder must fill cells between vertices)
        let lo = spec.origin
        let ni = Int(Double(spec.nx) * spec.cell / 0.25), nj = Int(Double(spec.ny) * spec.cell / 0.25)
        for i in 0..<ni {
            for j in 0..<nj {
                let a = lo + V2(Double(i), Double(j)) * 0.25, c = a + V2(0.25, 0.25)
                if let (h0, h1) = floorHole, a.x >= h0.x - 1e-9, c.x <= h1.x + 1e-9, a.y >= h0.y - 1e-9, c.y <= h1.y + 1e-9 { continue }
                let bq = V2(c.x, a.y), d = V2(a.x, c.y)
                b.addTriangle((a, floorH), (bq, floorH), (c, floorH))
                b.addTriangle((a, floorH), (c, floorH), (d, floorH))
            }
        }
        for t in extra { b.addTriangle(t.0, t.1, t.2) }
        return b
    }

    /// A vertical wall from a to b, 1 m tall, as two triangles.
    private func wall(_ a: V2, _ b: V2, h: Double = 1.0) -> [((V2, Double), (V2, Double), (V2, Double))] {
        [((a, 0), (b, 0), (b, h)), ((a, 0), (b, h), (a, h))]
    }

    func testStraightPathInAnEmptyRoom() {
        let spec = GridSpec(origin: V2(0, 0), cell: 0.08, nx: 75, ny: 50)     // 6 × 4 m
        let g = builder(spec).build(inflate: p.agentRadius)
        guard case .success(let path) = AStar.plan(g, from: V2(1, 2), to: V2(5, 2)) else { return XCTFail("no path") }
        XCTAssertEqual(path.count, 2)                                          // smoothed to one straight segment
        XCTAssertEqual(AStar.length(path), 4, accuracy: 0.01)
    }

    func testPlansAroundAWallGap() {
        // wall across x = 3 with a 1.2 m door at y ∈ [2.8, 4.0] … the robot (0.62 m wide) fits through
        let spec = GridSpec(origin: V2(0, 0), cell: 0.08, nx: 75, ny: 63)     // 6 × 5 m
        let g = builder(spec, extra: wall(V2(3, 0), V2(3, 2.8))).build(inflate: p.agentRadius)
        guard case .success(let path) = AStar.plan(g, from: V2(1, 1), to: V2(5, 1)) else { return XCTFail("no path") }
        XCTAssertGreaterThan(AStar.length(path), 4 + 2)                         // detours through the door
        for (a, b) in zip(path, path.dropFirst()) {                             // never crosses the wall
            let n = 50
            for k in 0...n {
                let q = a + (b - a) * (Double(k) / Double(n))
                if abs(q.x - 3) < 0.05 { XCTAssertGreaterThan(q.y, 2.8 + 0.2, "crossed at \(q)") }
            }
        }
    }

    func testNarrowGapIsRefusedForTheRobotButNotARabbit() {
        // wall with a 0.5 m slot: too narrow for the 0.62 m robot, fine for a rabbit (r 0.15; cells quantise ±5 cm)
        let spec = GridSpec(origin: V2(0, 0), cell: 0.05, nx: 120, ny: 60)    // 6 × 3 m
        let walls = wall(V2(3, 0), V2(3, 1.25)) + wall(V2(3, 1.75), V2(3, 3))
        let robotGrid = builder(spec, extra: walls).build(inflate: p.agentRadius)
        XCTAssertEqual(AStar.plan(robotGrid, from: V2(1, 1.5), to: V2(5, 1.5)), .failure(.noPath))
        let rabbitGrid = builder(spec, extra: walls).build(inflate: SpeciesProfile.rabbit.radius)
        guard case .success = AStar.plan(rabbitGrid, from: V2(1, 1.5), to: V2(5, 1.5)) else { return XCTFail("rabbit") }
    }

    func testStepAndDropLimits() {
        let spec = GridSpec(origin: V2(0, 0), cell: 0.08, nx: 75, ny: 38)     // 6 × 3 m
        // a 15 cm platform (too high to climb) across the room at x ∈ [2.5, 3.5]
        var platform: [((V2, Double), (V2, Double), (V2, Double))] = []
        platform.append(((V2(2.5, 0), 0.15), (V2(3.5, 0), 0.15), (V2(3.5, 3), 0.15)))
        platform.append(((V2(2.5, 0), 0.15), (V2(3.5, 3), 0.15), (V2(2.5, 3), 0.15)))
        platform += wall(V2(2.5, 0), V2(2.5, 3), h: 0.15) + wall(V2(3.5, 0), V2(3.5, 3), h: 0.15)
        var b = builder(spec, floorHole: (V2(2.5, 0), V2(3.5, 3)))
        for t in platform { b.addTriangle(t.0, t.1, t.2) }
        let g = b.build(inflate: p.agentRadius)
        XCTAssertEqual(AStar.plan(g, from: V2(1, 1.5), to: V2(5, 1.5)), .failure(.noPath))
        // a 3 cm threshold is fine
        let low = builder(spec, extra: [((V2(2.9, 0), 0.03), (V2(3.1, 0), 0.03), (V2(3.1, 3), 0.03)),
                                         ((V2(2.9, 0), 0.03), (V2(3.1, 3), 0.03), (V2(2.9, 3), 0.03))])
        guard case .success = AStar.plan(low.build(inflate: p.agentRadius), from: V2(1, 1.5), to: V2(5, 1.5)) else {
            return XCTFail("threshold")
        }
        // a stairwell (floor 1 m lower) is a cliff
        let stairs = builder(spec, floorHole: (V2(2.5, 0), V2(3.5, 3)))
        var sb = stairs
        sb.addTriangle((V2(2.5, 0), -1), (V2(3.5, 0), -1), (V2(3.5, 3), -1))
        sb.addTriangle((V2(2.5, 0), -1), (V2(3.5, 3), -1), (V2(2.5, 3), -1))
        XCTAssertEqual(AStar.plan(sb.build(inflate: p.agentRadius), from: V2(1, 1.5), to: V2(5, 1.5)), .failure(.noPath))
    }

    func testUnscannedFloorIsNotInvented() {
        let spec = GridSpec(origin: V2(0, 0), cell: 0.08, nx: 75, ny: 38)
        let g = builder(spec, floorHole: (V2(2.5, 0), V2(3.5, 3))).build(inflate: p.agentRadius)
        XCTAssertEqual(AStar.plan(g, from: V2(1, 1.5), to: V2(5, 1.5)), .failure(.noPath))
    }

    func testDrivesUnderATable() {
        // table top at 0.75 m (above the 0.61 m robot) with four legs: passable between the legs
        let spec = GridSpec(origin: V2(0, 0), cell: 0.05, nx: 120, ny: 60)
        var extra: [((V2, Double), (V2, Double), (V2, Double))] = [
            ((V2(2, 0.5), 0.75), (V2(4, 0.5), 0.75), (V2(4, 2.5), 0.75)),
            ((V2(2, 0.5), 0.75), (V2(4, 2.5), 0.75), (V2(2, 2.5), 0.75)),
        ]
        for c in [V2(2, 0.5), V2(4, 0.5), V2(2, 2.5), V2(4, 2.5)] { extra += wall(c, c + V2(0.04, 0), h: 0.75) }
        // walls above and below the table so the only way is under it
        extra += wall(V2(3, 0), V2(3, 0.45)) + wall(V2(3, 2.55), V2(3, 3))
        let g = builder(spec, extra: extra).build(inflate: p.agentRadius)
        guard case .success(let path) = AStar.plan(g, from: V2(1, 1.5), to: V2(5, 1.5)) else { return XCTFail("table") }
        XCTAssertEqual(AStar.length(path), 4, accuracy: 0.1)
    }

    func testGoalOnAWallSnapsOrFails() {
        let spec = GridSpec(origin: V2(0, 0), cell: 0.08, nx: 75, ny: 50)
        let g = builder(spec, extra: wall(V2(4, 0), V2(4, 4))).build(inflate: p.agentRadius)
        guard case .success(let path) = AStar.plan(g, from: V2(1, 2), to: V2(4.0, 2)) else { return XCTFail("snap") }
        XCTAssertLessThan(path.last!.x, 4)                    // stopped on our side of the wall
        XCTAssertEqual(AStar.plan(g, from: V2(1, 2), to: V2(9, 2)), .failure(.goalOutside))
    }

    func testFollowerDrivesThePath() {
        var d = DiffDrive(pose: DrivePose(x: 0, y: 0, theta: .pi))           // facing away: must turn first
        var f = PathFollower(path: [V2(0, 0), V2(2, 0), V2(2, 1.5)])
        var arrived = false
        for _ in 0..<(60 * 40) {
            guard let c = f.command(pose: d.pose, profile: p) else { arrived = true; break }
            XCTAssertLessThanOrEqual(c.v, p.navSpeed + 1e-9)
            d.setCommand(c)
            d.updateVelocities(dt: 1.0 / 60)
            d.commit(d.propose(dt: 1.0 / 60))
        }
        XCTAssertTrue(arrived)
        XCTAssertLessThan(SimMath.length(d.pose.position - V2(2, 1.5)), f.goalTolerance + 0.05)
    }

    func testFollowerKeepsItsDistance() {
        var d = DiffDrive(pose: DrivePose(x: 0, y: 0, theta: 0))
        var f = PathFollower(path: [V2(0, 0), V2(3, 0)], stopDistance: RobotAgenda.followDistance)
        for _ in 0..<(60 * 30) {
            guard let c = f.command(pose: d.pose, profile: p) else { break }
            d.setCommand(c); d.updateVelocities(dt: 1.0 / 60); d.commit(d.propose(dt: 1.0 / 60))
        }
        let gap = 3 - d.pose.x
        XCTAssertGreaterThan(gap, RobotAgenda.followDistance - 0.05)
        XCTAssertLessThan(gap, RobotAgenda.followDistance + 0.3)
    }
}

final class AnimalOrderTests: XCTestCase {
    let dt = 1.0 / 30
    private func steps(_ s: Double) -> Int { Int(s / dt) }

    func testGoToWalksThePathThenGrazes() {
        let w = BoxWorld()
        var b = AnimalBrain(profile: .deer, pos: V2(1, 1), heading: 0, seed: 30)
        b.setOrder(.goTo([V2(1, 1), V2(4, 1), V2(4, 3)]))
        XCTAssertEqual(b.state.phase, .go)
        var n = 0
        while b.order != .graze && n < steps(40) { b.step(dt: dt, world: w, threats: []); n += 1 }
        XCTAssertEqual(b.order, .graze)
        XCTAssertLessThan(SimMath.length(b.state.pos - V2(4, 3)), AnimalBrain.waypointReach + 0.05)
        // and stays there grazing
        let there = b.state.pos
        for _ in 0..<steps(30) { b.step(dt: dt, world: w, threats: []) }
        XCTAssertLessThan(SimMath.length(b.state.pos - there), 0.3)
    }

    func testFollowKeepsAboutAMetreAndIsNotScaredOfYou() {
        let w = BoxWorld()
        var b = AnimalBrain(profile: .fox, pos: V2(1, 2), heading: 0, seed: 31)
        b.setOrder(.follow)
        let me = V2(4.5, 2)
        for _ in 0..<steps(20) {
            b.step(dt: dt, world: w, threats: [Threat(pos: me, kind: .person)], leader: me)
            XCTAssertNotEqual(b.state.phase, .dash)
        }
        let d = SimMath.length(me - b.state.pos)
        XCTAssertLessThan(d, AnimalBrain.followDistance + 0.3)
        XCTAssertGreaterThan(d, AnimalBrain.followDistance - 0.4)
        // the robot still scares it
        b.step(dt: dt, world: w, threats: [Threat(pos: b.state.pos + V2(0.5, 0), kind: .robot)], leader: me)
        XCTAssertEqual(b.state.phase, .dash)
    }

    func testFleeBoltsFromYouThenWanders() {
        let w = BoxWorld()
        var b = AnimalBrain(profile: .rabbit, pos: V2(3, 2), heading: 0, seed: 32)
        let me = V2(2.5, 2)
        b.setOrder(.flee, person: me)
        XCTAssertEqual(b.state.phase, .dash)
        for _ in 0..<steps(8) { b.step(dt: dt, world: w, threats: []) }
        XCTAssertGreaterThan(SimMath.length(b.state.pos - me), 1.5)
        XCTAssertEqual(b.order, .wander)
        XCTAssert([.dwell, .move].contains(b.state.phase), "\(b.state.phase)")
    }

    func testStayIgnoresThreatsAndDoesNotMove() {
        let w = BoxWorld()
        var b = AnimalBrain(profile: .deer, pos: V2(3, 2), heading: 0, seed: 33)
        b.setOrder(.stay)
        for _ in 0..<steps(10) { b.step(dt: dt, world: w, threats: [Threat(pos: V2(2.5, 2), kind: .robot)]) }
        XCTAssertEqual(b.state.phase, .hold)
        XCTAssertEqual(b.state.pos, V2(3, 2))
        XCTAssertEqual(b.state.gait, .still)
    }

    func testGrazeStaysPutAndWanderResumes() {
        let w = BoxWorld()
        for profile in [SpeciesProfile.deer, .fox] {
            var b = AnimalBrain(profile: profile, pos: V2(3, 2), heading: 0, seed: 34)
            b.setOrder(.graze)
            for _ in 0..<steps(60) { b.step(dt: dt, world: w, threats: []) }
            XCTAssertLessThan(SimMath.length(b.state.pos - V2(3, 2)), 0.05, profile.name)
            b.setOrder(.wander)
            var moved = 0.0, last = b.state.pos
            for _ in 0..<steps(90) {
                b.step(dt: dt, world: w, threats: [])
                moved += SimMath.length(b.state.pos - last); last = b.state.pos
            }
            XCTAssertGreaterThan(moved, 0.5, profile.name)
        }
    }
}
