import XCTest
@testable import SnailSightCore

/// A room of axis-aligned walls + box obstacles (ground frame, metres). Stands in for the LiDAR scene mesh.
struct BoxWorld: SimWorld {
    var minX = 0.0, minY = 0.0, maxX = 6.0, maxY = 4.0
    var boxes: [(V2, V2)] = []           // (min corner, max corner)

    func clearance(_ p: V2) -> Double {
        var c = min(p.x - minX, maxX - p.x, p.y - minY, maxY - p.y)
        for (lo, hi) in boxes {
            let dx = max(lo.x - p.x, 0, p.x - hi.x), dy = max(lo.y - p.y, 0, p.y - hi.y)
            let inside = p.x > lo.x && p.x < hi.x && p.y > lo.y && p.y < hi.y
            c = min(c, inside ? -1 : (dx * dx + dy * dy).squareRoot())
        }
        return c
    }

    func isFree(from a: V2, to b: V2, radius: Double) -> Bool {
        let n = max(1, Int((SimMath.length(b - a) / 0.05).rounded(.up)))
        for i in 0...n {
            let p = a + (b - a) * (Double(i) / Double(n))
            if clearance(p) < radius { return false }
        }
        return true
    }
}

final class SimMathTests: XCTestCase {
    func testWrapAndTurn() {
        XCTAssertEqual(SimMath.wrap(3 * .pi), .pi, accuracy: 1e-9)
        XCTAssertEqual(SimMath.wrap(-3 * .pi / 2), .pi / 2, accuracy: 1e-9)
        // shortest way round: from 170° toward −170° turns +20°, capped at 10°
        let h = SimMath.turnToward(170 * .pi / 180, -170 * .pi / 180, maxStep: 10 * .pi / 180)
        XCTAssertEqual(h, 180 * .pi / 180, accuracy: 1e-9)
    }

    func testRngDeterministicAndInRange() {
        var a = SplitMix64(seed: 7), b = SplitMix64(seed: 7)
        for _ in 0..<100 {
            let x = a.uniform(2...5)
            XCTAssertEqual(x, b.uniform(2...5))
            XCTAssert(x >= 2 && x <= 5)
        }
    }

    func testSlideAlongWall() {
        let s = SimCollide.slide(V2(1, 1), normal: V2(-1, 0))      // driving into a wall on the right (+x)
        XCTAssertEqual(s.x, 0, accuracy: 1e-12)
        XCTAssertEqual(s.y, 1, accuracy: 1e-12)
        XCTAssertEqual(SimCollide.slide(V2(-1, 0.5), normal: V2(-1, 0)), V2(-1, 0.5))   // moving away: untouched
    }

    func testAgentBlocked() {
        let others = [(pos: V2(1, 0), radius: 0.3)]
        XCTAssertTrue(SimCollide.agentBlocked(from: V2(0, 0), to: V2(0.5, 0), radius: 0.3, others: others))
        XCTAssertFalse(SimCollide.agentBlocked(from: V2(0.5, 0), to: V2(0.4, 0), radius: 0.3, others: others))  // backing off
        XCTAssertFalse(SimCollide.agentBlocked(from: V2(0, 0), to: V2(0.2, 0), radius: 0.3, others: others))   // still clear
    }

    func testStepCheck() {
        func c(_ f: Double?) -> StepCheck { StepCheck.classify(currentFloor: 0, newFloor: f, maxStep: 0.06, maxDrop: 0.10) }
        XCTAssertEqual(c(0.02), .ok)
        XCTAssertEqual(c(0.08), .wall)        // a stair riser
        XCTAssertEqual(c(-0.2), .cliff)       // top of the basement stairs
        XCTAssertEqual(c(nil), .noFloor)      // never invent a floor
    }
}

final class DiffDriveTests: XCTestCase {
    let p = RobotProfile.robosnailbob
    let dt = 1.0 / 60

    private func run(_ d: inout DiffDrive, _ c: DriveCommand, seconds: Double, refresh: Bool = true) {
        var t = 0.0
        while t < seconds - 1e-9 {
            if refresh { d.setCommand(c) }
            d.updateVelocities(dt: dt)
            d.commit(d.propose(dt: dt))
            t += dt
        }
    }

    func testRealRobotNumbers() {
        // the real Q6 Edge 2.0 base (snailserve/robot/hardware.yml) + nav2_params.yaml, not the 1.6 m/s game twin
        XCTAssertEqual(p.length, 0.82); XCTAssertEqual(p.width, 0.62); XCTAssertEqual(p.height, 0.61)
        XCTAssertEqual(p.trackWidth, 0.55); XCTAssertEqual(p.wheelRadius, 0.178)
        XCTAssertEqual(p.navSpeed, 0.30)
        XCTAssertLessThanOrEqual(p.maxSpeed, 0.4)
        XCTAssertEqual(p.maxYawRate, 1.2)
    }

    func testStickShaping() {
        let s = StickShaper()
        XCTAssertEqual(s.command(V2(0.05, 0.08), profile: p), .stop)                // inside the deadzone
        XCTAssertEqual(s.command(V2(0, 1), profile: p).v, p.maxSpeed, accuracy: 1e-9)
        XCTAssertEqual(s.command(V2(0, -1), profile: p).v, -p.maxSpeed * p.reverseScale, accuracy: 1e-9)
        XCTAssertEqual(s.command(V2(1, 0), profile: p).omega, -p.maxYawRate, accuracy: 1e-9)   // right = clockwise
        XCTAssertEqual(s.command(V2(0, 3), profile: p).v, p.maxSpeed, accuracy: 1e-9)          // clamped to the disc
        let half = s.command(V2(0, 0.5), profile: p).v
        XCTAssert(half > 0 && half < 0.5 * p.maxSpeed)                                       // expo: finer near centre
    }

    func testAccelerationLimit() {
        var d = DiffDrive(pose: DrivePose(x: 0, y: 0, theta: 0))
        run(&d, DriveCommand(v: 0.4, omega: 0), seconds: 0.1)
        XCTAssertEqual(d.v, 0.05, accuracy: 0.01)                                   // 0.5 m/s² × 0.1 s
        run(&d, DriveCommand(v: 0.4, omega: 0), seconds: 1.0)
        XCTAssertEqual(d.v, 0.4, accuracy: 1e-9)
    }

    func testStraightLineDistance() {
        var d = DiffDrive(pose: DrivePose(x: 0, y: 0, theta: 0))
        run(&d, DriveCommand(v: 0.4, omega: 0), seconds: 5)
        XCTAssertEqual(d.pose.x, 0.4 * 5 - 0.4 * 0.4 / (2 * 0.5), accuracy: 0.02)    // ramp then cruise
        XCTAssertEqual(d.pose.y, 0, accuracy: 1e-9)
    }

    func testSpinInPlaceRespectsYawLimits() {
        var d = DiffDrive(pose: DrivePose(x: 0, y: 0, theta: 0))
        run(&d, DriveCommand(v: 0, omega: 1.2), seconds: 1.5)
        XCTAssertLessThan(d.pose.theta, .pi / 2)                                    // 90° needs ≥ 1.6 s at these limits
        XCTAssertGreaterThan(d.pose.theta, 1.2)
        XCTAssertEqual(d.pose.x, 0, accuracy: 1e-9); XCTAssertEqual(d.pose.y, 0, accuracy: 1e-9)
    }

    func testWheelSpeedLimitScalesTurnAtSpeed() {
        var d = DiffDrive(pose: DrivePose(x: 0, y: 0, theta: 0))
        run(&d, DriveCommand(v: 0.4, omega: 1.2), seconds: 3)
        let w = d.wheelSpeeds
        XCTAssertLessThanOrEqual(max(abs(w.left), abs(w.right)), p.maxWheelSpeed + 1e-9)
        XCTAssertEqual(d.omega / d.v, 1.2 / 0.4, accuracy: 1e-6)                    // same curvature, slower
    }

    func testArcIntegrationIsExact() {
        var pose = DrivePose(x: 0, y: 0, theta: 0)
        let v = 0.3, w = 0.5, n = 400
        let step = 2 * .pi / w / Double(n)
        for _ in 0..<n { pose = DiffDrive.integrate(pose, v: v, omega: w, dt: step) }
        XCTAssertEqual(pose.x, 0, accuracy: 1e-9); XCTAssertEqual(pose.y, 0, accuracy: 1e-9)
        let quarter = DiffDrive.integrate(DrivePose(x: 0, y: 0, theta: 0), v: v, omega: w, dt: .pi / 2 / w)
        XCTAssertEqual(quarter.x, v / w, accuracy: 1e-9); XCTAssertEqual(quarter.y, v / w, accuracy: 1e-9)   // left turn
    }

    func testDeadmanStops() {
        var d = DiffDrive(pose: DrivePose(x: 0, y: 0, theta: 0))
        d.setCommand(DriveCommand(v: 0.4, omega: 0))
        run(&d, .stop, seconds: 2, refresh: false)                                  // no fresh commands
        XCTAssertEqual(d.v, 0)
        XCTAssertLessThan(d.pose.x, 0.2)
    }

    func testBumpStopsTranslationOnly() {
        var d = DiffDrive(pose: DrivePose(x: 0, y: 0, theta: 0))
        run(&d, DriveCommand(v: 0.3, omega: 0.5), seconds: 2)
        d.bump()
        XCTAssertEqual(d.v, 0)
        XCTAssertGreaterThan(d.omega, 0)
    }
}

final class AnimalBrainTests: XCTestCase {
    let dt = 1.0 / 30

    private func steps(_ seconds: Double) -> Int { Int(seconds / dt) }

    func testDeerGrazesAndStaysInTheRoom() {
        let w = BoxWorld()
        var b = AnimalBrain(profile: .deer, pos: V2(3, 2), heading: 0, seed: 1)
        var grazing = 0, path = 0.0, last = b.state.pos
        for _ in 0..<steps(300) {
            b.step(dt: dt, world: w, threats: [])
            XCTAssertGreaterThan(w.clearance(b.state.pos), 0.5 * SpeciesProfile.deer.radius)
            if b.state.gait == .graze { grazing += 1 }
            path += SimMath.length(b.state.pos - last); last = b.state.pos
        }
        XCTAssertGreaterThan(Double(grazing) / Double(steps(300)), 0.4)    // mostly head-down
        XCTAssertGreaterThan(path, 2)                                       // but it does wander
        XCTAssertLessThan(path, 300 * 0.5)                                  // never faster than its walk on average
    }

    func testDeerBoltsFromRobotThenSettlesAndResumes() {
        let w = BoxWorld()
        var b = AnimalBrain(profile: .deer, pos: V2(3, 2), heading: 0, seed: 2)
        let robot = Threat(pos: V2(2.0, 2.0), kind: .robot)                 // 1 m away: inside 1.8 m
        b.step(dt: dt, world: w, threats: [robot])
        XCTAssertEqual(b.state.phase, .dash)
        var peak = 0.0, ran = false, n = 0
        while b.state.phase == .dash && n < steps(5) {
            b.step(dt: dt, world: w, threats: [robot])
            peak = max(peak, b.state.speed); ran = ran || b.state.gait == .run; n += 1
        }
        XCTAssertEqual(b.state.phase, .settle)
        XCTAssertGreaterThan(SimMath.length(b.state.pos - robot.pos), 1.0 + 1.5)   // bolted away
        XCTAssertGreaterThan(peak, SpeciesProfile.deer.runAbove)
        XCTAssertTrue(ran)
        // settle: stands and turns to watch the robot
        for _ in 0..<steps(2) { b.step(dt: dt, world: w, threats: []) }
        XCTAssertEqual(b.state.phase, .settle)
        XCTAssertLessThan(b.state.speed, 0.05)
        // robot gone → resumes calm behaviour after the settle time
        for _ in 0..<steps(2) { b.step(dt: dt, world: w, threats: []) }
        XCTAssert(b.state.phase == .dwell || b.state.phase == .move, "phase \(b.state.phase)")
    }

    func testSettleWatchesTheThreat() {
        let w = BoxWorld()
        var b = AnimalBrain(profile: .deer, pos: V2(3, 2), heading: 0, seed: 3)
        let robot = Threat(pos: V2(2.2, 2.0), kind: .robot)
        var n = 0
        while b.state.phase != .settle && n < steps(5) { b.step(dt: dt, world: w, threats: [robot]); n += 1 }
        let far = Threat(pos: robot.pos, kind: .robot)
        for _ in 0..<steps(2) { b.step(dt: dt, world: w, threats: [far]) }
        let toRobot = SimMath.heading(robot.pos - b.state.pos)
        XCTAssertLessThan(abs(SimMath.wrap(toRobot - b.state.heading)), 30 * .pi / 180)
    }

    func testPersonHasSmallerScareRadiusThanRobot() {
        let b = AnimalBrain(profile: .deer, pos: V2(3, 2), heading: 0, seed: 4)
        XCTAssertNil(b.trigger([Threat(pos: V2(1.5, 2), kind: .person)]))           // 1.5 m > 1.2 m
        XCTAssertNotNil(b.trigger([Threat(pos: V2(1.5, 2), kind: .robot)]))         // 1.5 m < 1.8 m
        XCTAssertNotNil(b.trigger([Threat(pos: V2(2.1, 2), kind: .person)]))
    }

    func testNeverEntersObstaclesOrWalls() {
        var w = BoxWorld()
        w.boxes = [(V2(1, 1), V2(2, 2)), (V2(4, 2.5), V2(5, 3.5))]            // a crate and a table
        for seed in UInt64(10)..<UInt64(18) {
            for profile in SpeciesProfile.all {
                var b = AnimalBrain(profile: profile, pos: V2(3, 1), heading: 0, seed: seed)
                var t = 0.0
                for _ in 0..<steps(90) {
                    t += dt
                    let robot = Threat(pos: V2(3 + 1.5 * cos(t * 0.4), 2 + 1.2 * sin(t * 0.4)), kind: .robot)
                    b.step(dt: dt, world: w, threats: [robot, Threat(pos: V2(0.5, 3.5), kind: .person)])
                    XCTAssertGreaterThan(w.clearance(b.state.pos), 0.4 * profile.radius,
                                         "\(profile.name) seed \(seed) at \(b.state.pos)")
                }
            }
        }
    }

    func testKeepsClearOfOtherAgents() {
        let w = BoxWorld()
        var a = AnimalBrain(profile: .deer, pos: V2(2, 2), heading: 0, seed: 20)
        var b = AnimalBrain(profile: .deer, pos: V2(3.2, 2), heading: .pi, seed: 21)
        for _ in 0..<steps(120) {
            a.step(dt: dt, world: w, threats: [], others: [(b.state.pos, 0.35)])
            b.step(dt: dt, world: w, threats: [], others: [(a.state.pos, 0.35)])
            XCTAssertGreaterThan(SimMath.length(a.state.pos - b.state.pos), 0.6)
        }
    }

    func testDeterministicPerSeed() {
        let w = BoxWorld()
        var a = AnimalBrain(profile: .fox, pos: V2(3, 2), heading: 0, seed: 99)
        var b = AnimalBrain(profile: .fox, pos: V2(3, 2), heading: 0, seed: 99)
        for _ in 0..<steps(60) {
            a.step(dt: dt, world: w, threats: [])
            b.step(dt: dt, world: w, threats: [])
        }
        XCTAssertEqual(a.state, b.state)
    }

    func testFoxStopGoMostlyStands() {
        let w = BoxWorld()
        var b = AnimalBrain(profile: .fox, pos: V2(3, 2), heading: 0, seed: 5)
        var still = 0, hops = 0, prev = b.state.phase
        for _ in 0..<steps(180) {
            b.step(dt: dt, world: w, threats: [])
            if b.state.gait == .still { still += 1 }
            if prev == .stand && b.state.phase == .walk { hops += 1 }
            prev = b.state.phase
        }
        XCTAssertGreaterThan(Double(still) / Double(steps(180)), 0.5)
        XCTAssertGreaterThanOrEqual(hops, 5)
    }

    func testBoxedInEndsTheDashWithoutMoving() {
        let w = BoxWorld(minX: 0, minY: 0, maxX: 0.8, maxY: 0.8)
        var b = AnimalBrain(profile: .deer, pos: V2(0.4, 0.4), heading: 0, seed: 6)
        for _ in 0..<steps(1) { b.step(dt: dt, world: w, threats: [Threat(pos: V2(0.4, 1.2), kind: .robot)]) }
        XCTAssertEqual(b.state.phase, .settle)
        XCTAssertEqual(b.state.pos, V2(0.4, 0.4))
    }

    func testClipFallbacks() {
        let fox: Set<String> = ["static", "idle", "walk", "run"]                     // the fox pack has no eat clip
        XCTAssertEqual(SimClips.pick(.graze, available: fox), "idle")
        XCTAssertEqual(SimClips.pick(.run, available: ["static", "walk"]), "walk")
        XCTAssertEqual(SimClips.pick(.walk, available: ["static"]), "static")
        XCTAssertNil(SimClips.pick(.alert, available: []))
        XCTAssertEqual(SimClips.fileName(species: "deer", clip: "eat"), "deer_eat")
        XCTAssertEqual(SimClips.fileName(species: "deer", clip: "static"), "deer")
    }
}
