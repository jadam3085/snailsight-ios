import XCTest
@testable import SnailSightCore

/// 9.8 pushing, sleeping, throwing, heat budget and HUD wording.
final class SimPhysicsTests: XCTestCase {
    func robot(at x: Double = 0, v: V2 = V2(0.4, 0)) -> PushAgent {
        PushAgent(center: V2(x, 0), yaw: 0, halfLength: 0.41, halfWidth: 0.31, bottom: 0, height: 0.61,
                  velocity: v, massKg: 60, kinematic: true)
    }
    func box(at p: V2, r: Double = 0.15, mass: Double = 2, bottom: Double = 0, v: V2 = .zero) -> PushObject {
        PushObject(center: p, radius: r, bottom: bottom, top: bottom + 0.3, velocity: v, massKg: mass)
    }

    func testRobotPushesABoxAhead() throws {
        let r = try XCTUnwrap(SimPush.resolve(agent: robot(), object: box(at: V2(0.5, 0))))
        XCTAssertEqual(r.normal.x, 1, accuracy: 1e-9)
        XCTAssertEqual(r.offset.x, 0.15 - 0.09 + 0.002, accuracy: 1e-9)       // out of the overlap
        XCTAssertGreaterThan(r.velocity.x, 0.4)                                // at least the robot's speed, + bounce
        XCTAssertEqual(r.velocity.x, 0.4 * (1 + SimPush.restitution), accuracy: 1e-9)
        XCTAssertFalse(r.blocksAgent)
    }

    func testNoContactWhenApartAboveOrBehindTheBox() {
        XCTAssertNil(SimPush.resolve(agent: robot(), object: box(at: V2(0.7, 0))))
        XCTAssertNil(SimPush.resolve(agent: robot(), object: box(at: V2(0.5, 0), bottom: 0.75)))   // on a table above
        // a standing robot touching a box only separates it, no launch
        let still = SimPush.resolve(agent: robot(v: .zero), object: box(at: V2(0.5, 0)))
        XCTAssertEqual(still?.velocity, .zero)
    }

    func testYawedAgentPushesSideways() throws {
        var a = robot(v: V2(0, 0.3))
        a.yaw = .pi / 2                                                        // facing +y
        let r = try XCTUnwrap(SimPush.resolve(agent: a, object: box(at: V2(0, 0.5))))
        XCTAssertEqual(r.normal.y, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(r.velocity.y, 0.3)
    }

    func testCentreInsideLeavesByNearestFace() throws {
        let r = try XCTUnwrap(SimPush.resolve(agent: robot(v: .zero), object: box(at: V2(0.1, 0.25), r: 0.05)))
        XCTAssertEqual(r.normal.y, 1, accuracy: 1e-9)
        XCTAssertEqual(r.offset.y, 0.06 + 0.05 + 0.002, accuracy: 1e-9)
    }

    func testAnimalPushesLightThingsButIsBlockedByHeavy() throws {
        let rabbit = PushAgent(center: .zero, yaw: 0, halfLength: 0.09, halfWidth: 0.05, bottom: 0, height: 0.15,
                               velocity: V2(0.3, 0), massKg: 1.3, kinematic: false)
        let ball = try XCTUnwrap(SimPush.resolve(agent: rabbit, object: box(at: V2(0.12, 0), r: 0.05, mass: 0.35)))
        XCTAssertFalse(ball.blocksAgent)
        XCTAssertGreaterThan(ball.velocity.x, 0.3)
        let crate = try XCTUnwrap(SimPush.resolve(agent: rabbit, object: box(at: V2(0.2, 0), r: 0.15, mass: 2)))
        XCTAssertTrue(crate.blocksAgent)
        XCTAssertEqual(crate.offset, .zero)
    }

    func testPushSpeedIsCapped() throws {
        let r = try XCTUnwrap(SimPush.resolve(agent: robot(v: V2(5, 0)), object: box(at: V2(0.5, 0))))
        XCTAssertEqual(SimMath.length(r.velocity), SimPush.maxPushSpeed, accuracy: 1e-9)
    }

    func testThrownBallBouncesOffAStandingAgent() throws {
        let r = try XCTUnwrap(SimPush.bounce(object: box(at: V2(0.5, 0), r: 0.1, mass: 0.3, v: V2(-3, 0)), off: robot(v: .zero)))
        XCTAssertGreaterThan(r.velocity.x, 0)                                  // reflected
        XCTAssertEqual(r.impactSpeed, 3, accuracy: 1e-9)
        XCTAssertNil(SimPush.bounce(object: box(at: V2(0.5, 0), r: 0.1, v: V2(2, 0)), off: robot(v: .zero)))  // leaving
    }

    // MARK: sleep

    func testRestingBodiesSleepAfterRestTime() {
        var b = [BodyActivity(id: 1, speed: 0.01), BodyActivity(id: 2, speed: 0.5)]
        let p = SleepPolicy(maxActive: 10)
        XCTAssertEqual(SimSleep.update(&b, dt: 0.5, policy: p), [])
        XCTAssertEqual(SimSleep.update(&b, dt: 0.6, policy: p), [1])
        XCTAssertTrue(b[0].asleep)
        XCTAssertFalse(b[1].asleep)
        b[1].speed = 0.0; b[1].held = true                                     // held by the user: never sleeps
        XCTAssertEqual(SimSleep.update(&b, dt: 5, policy: p), [])
    }

    func testActiveCapSleepsSlowestNotFlying() {
        var b = (1...5).map { BodyActivity(id: $0, speed: Double($0) * 0.05) } + [BodyActivity(id: 9, speed: 3)]
        let slept = SimSleep.update(&b, dt: 0.01, policy: SleepPolicy(maxActive: 3))
        XCTAssertEqual(slept, [1, 2, 3])                                       // 0.05, 0.10, 0.15 m/s
        XCTAssertFalse(b.first { $0.id == 9 }!.asleep)                        // the thrown one keeps flying
        var fast = (1...5).map { BodyActivity(id: $0, speed: 2) }
        XCTAssertEqual(SimSleep.update(&fast, dt: 0.01, policy: SleepPolicy(maxActive: 2)), [])   // never mid-air
    }

    func testNeighboursWake() {
        let w = SimSleep.neighboursToWake(moving: [(SIMD3(0, 0, 0), 0.1)],
                                          sleeping: [(1, SIMD3(0.2, 0, 0), 0.06), (2, SIMD3(1, 0, 0), 0.1)])
        XCTAssertEqual(w, [1])
    }

    // MARK: throw / poke

    func testThrowVelocityFromRecentSamples() {
        var t = ThrowTracker()
        for k in 0...10 { t.add(SIMD3(Double(k) * 0.02, 1, 0), at: Double(k) * 0.01) }   // 2 m/s along x
        let v = t.releaseVelocity(at: 0.1)
        XCTAssertEqual(v.x, 2, accuracy: 1e-6)
        XCTAssertEqual(v.y, ThrowTracker.lift, accuracy: 1e-6)
        var still = ThrowTracker()
        for k in 0...10 { still.add(SIMD3(0.001 * Double(k), 1, 0), at: Double(k) * 0.01) }
        XCTAssertEqual(still.releaseVelocity(at: 0.1), .zero)                  // a drop, not a throw
        var wild = ThrowTracker()
        wild.add(SIMD3(0, 0, 0), at: 0); wild.add(SIMD3(1, 0, 0), at: 0.01)
        let wv = wild.releaseVelocity(at: 0.01)
        XCTAssertEqual((wv.x * wv.x + (wv.y - ThrowTracker.lift) * (wv.y - ThrowTracker.lift)).squareRoot(),
                       ThrowTracker.maxSpeed, accuracy: 1e-6)
    }

    func testPokeIsAwayFromTheCamera() {
        let d = Poke.velocityChange(cameraToObject: SIMD3(0, -1, -2))
        XCTAssertEqual(d.z, -Poke.speed, accuracy: 1e-9)
        XCTAssertEqual(d.y, Poke.hop)
        XCTAssertEqual(Poke.velocityChange(cameraToObject: SIMD3(0, -1, 0)), SIMD3(0, Poke.hop, 0))
    }

    // MARK: heat budget + wording

    func testBudgetTiers() {
        XCTAssertEqual(SimBudgets.budget(mode: .auto, thermal: .nominal).tier, .full)
        XCTAssertEqual(SimBudgets.budget(mode: .auto, thermal: .fair).tier, .light)
        let s = SimBudgets.budget(mode: .auto, thermal: .serious)
        XCTAssertEqual(s.tier, .eco)
        XCTAssertTrue(s.running)                                               // 9.8: serious no longer freezes the sim
        XCTAssertEqual(s.arFPS, 30)
        XCTAssertFalse(s.groundingShadows)
        XCTAssertFalse(SimBudgets.budget(mode: .full, thermal: .critical).running)
        XCTAssertEqual(SimBudgets.budget(mode: .eco, thermal: .nominal).tier, .eco)
        XCTAssertEqual(SimBudgets.budget(mode: .full, thermal: .serious).tier, .full)
        XCTAssertNil(SimBudgets.budget(mode: .auto, thermal: .nominal).note)
        XCTAssertFalse(SimBudgets.budget(mode: .auto, thermal: .fair).groundingShadows)
        XCTAssertEqual(SimBudgets.budget(mode: .auto, thermal: .fair).arFPS, 60)
    }

    func testFpsAndThermalWording() {
        XCTAssertEqual(StatusText.fpsTone(fps: 29.99, target: 30), .normal)   // the 9.7 red "AR 30 fps" in eco
        XCTAssertEqual(StatusText.fpsTone(fps: 29.99, target: 60), .warn)
        XCTAssertEqual(StatusText.fpsTone(fps: 0, target: 60), .normal)
        XCTAssertTrue(StatusText.fpsExplain(fps: 30, target: 60, thermal: .serious).contains("chip is hot"))
        XCTAssertTrue(StatusText.fpsExplain(fps: 30, target: 30, thermal: .serious).contains("expected"))
        XCTAssertTrue(StatusText.fpsExplain(fps: 60, target: 60, thermal: .nominal).contains("smooth"))
        XCTAssertNil(StatusText.thermalChip(.fair, recording: true, recRateHz: 10))   // no alarm at fair
        let c = StatusText.thermalChip(.serious, recording: true, recRateHz: 5)
        XCTAssertEqual(c?.label, "Warm")
        XCTAssertEqual(c?.detail, "iOS reports the chip is hot — recording slowed to 5 fps")
        XCTAssertEqual(StatusText.thermalChip(.critical, recording: false, recRateHz: 0)?.label, "Hot")
    }

    func testThermalHistory() {
        var h = ThermalHistory(state: .nominal, at: 0)
        XCTAssertNil(h.change(to: .nominal, at: 5))
        let a = h.change(to: .serious, at: 10)
        XCTAssertEqual(a?.from, .nominal); XCTAssertEqual(a?.lasted, 10)
        let b = h.change(to: .fair, at: 70)
        XCTAssertEqual(b?.lasted, 60)
        _ = h.change(to: .serious, at: 80)
        XCTAssertEqual(h.total(.serious, at: 100), 80)
        XCTAssertEqual(h.entries[.serious], 2)
    }
}

/// 9.8 animal reactions to objects and to a new Sim scale.
final class AnimalStartleTests: XCTestCase {
    struct Open: SimWorld { func isFree(from a: V2, to b: V2, radius: Double) -> Bool { true } }

    func testStartleBoltsAwayAndKeepsTheOrder() {
        var b = AnimalBrain(profile: .rabbit, pos: .zero, heading: 0, seed: 7)
        b.setHome([V2(-3, -3), V2(3, -3), V2(3, 3), V2(-3, 3)])
        b.setOrder(.roam)
        b.startle(from: V2(-0.2, 0))
        XCTAssertEqual(b.state.phase, .dash)
        for _ in 0..<30 { b.step(dt: 1.0 / 30, world: Open(), threats: []) }
        XCTAssertGreaterThan(b.state.pos.x, 0.2)                              // ran away from the hit
        XCTAssertEqual(b.order, .roam)                                         // still roaming its room
        var s = AnimalBrain(profile: .rabbit, pos: .zero, heading: 0, seed: 7)
        s.setOrder(.stay)
        s.startle(from: V2(-0.2, 0))
        XCTAssertEqual(s.state.phase, .hold)
    }

    func testSetProfileRescalesWithoutResettingTheOrder() {
        var b = AnimalBrain(profile: .deer, pos: .zero, heading: 0, seed: 3)
        b.setOrder(.graze)
        b.setProfile(SpeciesProfile.deer.scaled(0.5))
        XCTAssertEqual(b.profile.walkSpeed, 0.25, accuracy: 1e-9)
        XCTAssertEqual(b.order, .graze)
    }
}
