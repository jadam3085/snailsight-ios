import XCTest
@testable import SnailSightCore

/// 12.7 twin sticks with RoboSnailBob HUD parity: deadzone, layouts, turbo ratio, decel ramp, one message for both.
final class TeleopMapTests: XCTestCase {
    func testHudDeadzone() {
        XCTAssertEqual(StickDeadzone.apply(0.1, 0.15), 0)
        XCTAssertEqual(StickDeadzone.apply(0.15, 0.15), 0, accuracy: 1e-12)
        XCTAssertEqual(StickDeadzone.apply(1, 0.15), 1, accuracy: 1e-12)
        XCTAssertEqual(StickDeadzone.apply(-0.575, 0.15), -0.5, accuracy: 1e-12)    // (0.575 − 0.15) / 0.85
        XCTAssertEqual(StickDeadzone.apply(2, 0.15), 1, accuracy: 1e-12)            // clamped first
    }

    func testLayouts() {
        let i = TwinStickInput(left: V2(0.5, 1), right: V2(-1, 0.3), l2: 0.2, r2: 0.9)
        let d = TwinStick.resolve(i, layout: .standard, deadzone: 0)
        XCTAssertEqual(d.drive, V2(0.5, 1)); XCTAssertEqual(d.turret, V2(-1, 0.3))
        let s = TwinStick.resolve(i, layout: .southpaw, deadzone: 0)
        XCTAssertEqual(s.drive, V2(-1, 0.3)); XCTAssertEqual(s.turret, V2(0.5, 1))
        let t = TwinStick.resolve(i, layout: .triggers, deadzone: 0)
        XCTAssertEqual(t.drive.x, 0.5); XCTAssertEqual(t.drive.y, 0.7, accuracy: 1e-12)   // R2 − L2
        XCTAssertEqual(t.turret, V2(-1, 0.3))
    }

    func testTurboRatioMatchesHud() {
        // HUD: 0.5 normal / 0.75 turbo (+50 %) → fractions 0.667 / 1.0 of the server's full drive
        XCTAssertEqual(TeleopFeel.normalFraction, 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(TeleopFeel.fraction(turbo: true) / TeleopFeel.fraction(turbo: false), 1.5, accuracy: 1e-12)
        let n = TwinStick.drive(V2(0, 1), turbo: false, tank: false)
        XCTAssertEqual(n.throttle, 2.0 / 3.0, accuracy: 1e-3); XCTAssertEqual(n.steer, 0)
        let tb = TwinStick.drive(V2(1, 0), turbo: true, tank: true)
        XCTAssertEqual(tb.steer, 1, accuracy: 1e-12); XCTAssertTrue(tb.tank)
        let diag = TwinStick.drive(V2(1, 1), turbo: true, tank: false)              // unit disc
        XCTAssertEqual(diag.throttle, 1 / 2.0.squareRoot(), accuracy: 1e-9)
        // turret: stick right = turn right (yaw −), stick up = pitch up
        XCTAssertEqual(TwinStick.turret(V2(0.5, -0.25)), .rate(yaw: -0.5, pitch: -0.25))
    }

    func testDecelRamp() {
        var r = DecelRamp()
        r.start(from: DriveInput(throttle: 0.667, steer: -0.3), now: 0)
        XCTAssertEqual(r.value(now: 0.01)!.throttle, 0.667, accuracy: 1e-3)
        XCTAssertEqual(r.value(now: 0.051)!.throttle, 0.667 * 0.6, accuracy: 1e-3)
        XCTAssertEqual(r.value(now: 0.101)!.steer, -0.3 * 0.36, accuracy: 1e-3)
        XCTAssertNil(r.value(now: 1.0))                   // decayed below 0.03
        XCTAssertFalse(r.isActive)
        XCTAssertEqual(DecelRamp.steps(from: 1), 7)        // 0.6^7 = 0.028: 350 ms from full stick (HUD ~400 ms)
        var z = DecelRamp(); z.start(from: .zero, now: 0); XCTAssertFalse(z.isActive)
    }

    func testOneMessageCarriesBothAndEachZeroOnce() {
        var s = TeleopFrameSender()
        // nothing held, nothing sent
        XCTAssertNil(s.next(drive: .zero, turret: .rate(yaw: 0, pitch: 0), now: 0))
        // both sticks: ONE message with both
        let d = DriveInput(throttle: 0.5, steer: 0.1)
        let m = s.next(drive: d, turret: .rate(yaw: -0.3, pitch: 0), now: 0.0)
        XCTAssertEqual(m?.drive, d); XCTAssertEqual(m?.turret, .rate(yaw: -0.3, pitch: 0)); XCTAssertEqual(m?.ttl, 0.5)
        // 10 Hz
        XCTAssertNil(s.next(drive: d, turret: .rate(yaw: -0.3, pitch: 0), now: 0.05))
        XCTAssertNotNil(s.next(drive: d, turret: .rate(yaw: -0.3, pitch: 0), now: 0.1))
        // turret released: its one zero at once, the drive goes on in the same message
        let z = s.next(drive: d, turret: .rate(yaw: 0, pitch: 0), now: 0.12)
        XCTAssertEqual(z?.turret, .rate(yaw: 0, pitch: 0)); XCTAssertEqual(z?.drive, d)
        // next 10 Hz tick: drive only
        let n = s.next(drive: d, turret: .rate(yaw: 0, pitch: 0), now: 0.25)
        XCTAssertNil(n?.turret); XCTAssertEqual(n?.drive, d)
        // drive released: one zero, then silence
        XCTAssertEqual(s.next(drive: .zero, turret: .rate(yaw: 0, pitch: 0), now: 0.27)?.drive, .zero)
        XCTAssertNil(s.next(drive: .zero, turret: .rate(yaw: 0, pitch: 0), now: 0.5))
        XCTAssertTrue(s.idle)
        // a turret-less body (rc_car): drive only, never a turret field
        var c = TeleopFrameSender()
        XCTAssertNil(c.next(drive: d, turret: nil, now: 0)?.turret)
    }

    func testDoubleTapAndSpeed() {
        var t = DoubleTapDetector()
        XCTAssertFalse(t.touchDown(at: 1.0))
        XCTAssertTrue(t.touchDown(at: 1.2))
        XCTAssertFalse(t.touchDown(at: 1.3))            // a third tap starts over
        XCTAssertFalse(t.touchDown(at: 2.0))
        XCTAssertEqual(SpeedReadout.speed(v: -0.2, vx: 1, vy: 1), 0.2)
        XCTAssertEqual(SpeedReadout.speed(v: nil, vx: 0.3, vy: 0.4), 0.5, accuracy: 1e-12)
        XCTAssertEqual(SpeedReadout.text(speed: 0.213, throttle: 0.667, turbo: false), "0.21 m/s · 67%")
        XCTAssertEqual(SpeedReadout.text(speed: 0, throttle: 0, turbo: true), "0.00 m/s · TURBO")
    }
}
