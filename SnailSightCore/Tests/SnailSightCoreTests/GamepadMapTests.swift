import XCTest
@testable import SnailSightCore

/// 12.7 gamepad: the HUD's function map + presets, press-to-bind rules, edges, holds, the quick wheel.
final class GamepadMapTests: XCTestCase {
    func testDefaultPresetIsTheHudScheme() {
        let c = GamepadConfig()
        XCTAssertEqual(c.deadzone, 0.15)
        XCTAssertEqual(c.layout, .standard)
        XCTAssertEqual(c.function(for: .a), .select)
        XCTAssertEqual(c.function(for: .b), .estop)
        XCTAssertEqual(c.function(for: .l2), .wheel)
        XCTAssertEqual(c.function(for: .r2), .turbo)
        XCTAssertEqual(c.function(for: .l3), .driveMode)
        XCTAssertEqual(c.function(for: .r3), .turretCentre)
        XCTAssertEqual(c.function(for: .select), .controllerMode)
        XCTAssertEqual(c.function(for: .start), .menu)
        XCTAssertEqual(c.presetLabel, "DEFAULT")
        // every function has at most one button and every button at most one function
        XCTAssertEqual(Set(c.map.values).count, c.map.count)
    }

    func testPresets() {
        var c = GamepadConfig()
        c.apply(.southpaw); XCTAssertEqual(c.layout, .southpaw); XCTAssertEqual(c.function(for: .r2), .turbo)
        c.apply(.triggers); XCTAssertEqual(c.layout, .triggers)
        XCTAssertEqual(c.button(for: .turbo), .l1); XCTAssertEqual(c.button(for: .wheel), .r1)
        XCTAssertNil(c.function(for: .l2)); XCTAssertNil(c.function(for: .r2))
        c.apply(.dpadcam); XCTAssertEqual(c.function(for: .dUp), .viewNext); XCTAssertEqual(c.function(for: .l1), .yawLeft)
        for p in GamepadPreset.allCases {
            c.apply(p)
            XCTAssertEqual(Set(c.map.values).count, c.map.count, "\(p)")
            XCTAssertEqual(c.function(for: .a), .select); XCTAssertEqual(c.function(for: .b), .estop)
        }
        XCTAssertEqual(GamepadPreset.dpadcam.next, .standard)
    }

    func testBindAndPersist() throws {
        var c = GamepadConfig()
        XCTAssertFalse(c.bind(.viewNext, to: .a))                 // A / B reserved
        XCTAssertFalse(c.bind(.estop, to: .x))
        XCTAssertTrue(c.bind(.follow, to: .x))                    // X was viewNext: one button, one function
        XCTAssertEqual(c.function(for: .x), .follow); XCTAssertNil(c.button(for: .viewNext))
        XCTAssertEqual(c.presetLabel, "CUSTOM")
        c.controllerMode = true; c.deadzone = 0.2
        let back = GamepadConfig.decode(c.encoded())
        XCTAssertEqual(back, c)
        XCTAssertEqual(GamepadConfig.decode(nil), GamepadConfig())
        XCTAssertEqual(GamepadConfig.decode(Data("junk".utf8)), GamepadConfig())
        XCTAssertNil(GamepadConfig().controllerMode)              // auto-on at the first pairing
    }

    func testRouterEdgesHoldsAndAxes() {
        var r = GamepadRouter()
        let c = GamepadConfig()
        var o = r.step(GamepadFrame(left: V2(0, 0.1), right: V2(1, 0), pressed: [.x], r2: 0.8), config: c)
        XCTAssertEqual(o.fired, [.viewNext]); XCTAssertTrue(o.turbo); XCTAssertFalse(o.wheelHeld)
        XCTAssertEqual(o.axes.drive, .zero)                        // 0.1 < deadzone 0.15
        XCTAssertEqual(o.axes.turret.x, 1, accuracy: 1e-12)
        o = r.step(GamepadFrame(pressed: [.x], l2: 0.9), config: c)  // still held: no second fire
        XCTAssertEqual(o.fired, []); XCTAssertTrue(o.wheelHeld); XCTAssertFalse(o.turbo)
        o = r.step(GamepadFrame(pressed: [.b, .r3]), config: c)
        XCTAssertEqual(o.fired, [.estop, .turretCentre])
        // triggers layout: R2 − L2 throttle, R2 / L2 never fire functions; turbo is L1
        var t = GamepadConfig(); t.apply(.triggers)
        var rt = GamepadRouter()
        let ot = rt.step(GamepadFrame(left: V2(0.5, 0), pressed: [.l1], l2: 0.1, r2: 1.0), config: t)
        XCTAssertTrue(ot.turbo); XCTAssertFalse(ot.wheelHeld); XCTAssertEqual(ot.fired, [])
        XCTAssertEqual(ot.axes.drive.y, 0.85 / 0.95, accuracy: 1e-9)  // (0.9 − 0.05) / 0.95: trigger deadzone 0.05
    }

    func testQuickWheel() {
        XCTAssertNil(QuickWheel.pick(V2(0.2, 0.2), count: 8))      // centred = cancel
        XCTAssertEqual(QuickWheel.pick(V2(0, 1), count: 8), 0)     // up = first
        XCTAssertEqual(QuickWheel.pick(V2(1, 0), count: 8), 2)     // right = clockwise quarter
        XCTAssertEqual(QuickWheel.pick(V2(0, -1), count: 8), 4)
        XCTAssertEqual(QuickWheel.pick(V2(-1, 0.05), count: 8), 6)
        XCTAssertEqual(QuickWheel.pick(V2(-0.1, 1), count: 8), 0)  // just left of up wraps to 0
        let o = QuickWheel.offset(2, count: 8)
        XCTAssertEqual(o.x, 1, accuracy: 1e-12); XCTAssertEqual(o.y, 0, accuracy: 1e-12)
        XCTAssertEqual(QuickWheel.offset(0, count: 8).y, -1, accuracy: 1e-12)   // screen y down: top
    }
}
