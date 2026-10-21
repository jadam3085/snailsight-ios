import XCTest
@testable import SnailSightCore

final class TapToolTests: XCTestCase {
    func testLaunchDefaultIsSelectNeverCube() {
        let s = TapToolState()
        XCTAssertEqual(s.tool, .select)
        XCTAssertEqual(TapToolState.launchDefault, .select)
        XCTAssertFalse(s.tapPlacesCube)
        XCTAssertEqual(TapToolState(saved: "cube").tool, .select)        // a saved Cube never comes back
        XCTAssertNil(s.persisted)
    }

    func testExplicitCubePickPlacesCubesUntilRelaunch() {
        var s = TapToolState()
        XCTAssertTrue(s.pick(.cube))
        XCTAssertTrue(s.tapPlacesCube)
        XCTAssertFalse(s.pick(.cube))
        XCTAssertNil(s.persisted)                                         // nothing to restore next launch
        let relaunch = TapToolState(saved: s.tool.rawValue)
        XCTAssertEqual(relaunch.tool, .select)
        XCTAssertFalse(relaunch.tapPlacesCube)
        s.reset()
        XCTAssertEqual(s.tool, .select)
        XCTAssertFalse(s.tapPlacesCube)
        s.pick(.measure)
        XCTAssertFalse(s.tapPlacesCube)
        XCTAssertEqual(TapToolKind.allCases.first, .select)
    }

    func testMeasurePointReadoutPairAndFade() {
        var m = MeasurePoints()
        let a = m.tap(at: [3, 4, 1.2], phone: [0, 0, 1.2], floor: 0.45, level: "Main floor", now: 0)
        XCTAssertEqual(a.distanceFromPhone, 5, accuracy: 1e-9)
        XCTAssertEqual(a.heightAboveFloor ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(m.readout, "5.00 m away · 75 cm above floor · Main floor")
        XCTAssertEqual(m.opacity(now: 1), 1)
        m.tap(at: [3, 6, 1.2], phone: [0, 0, 1.2], floor: nil, level: nil, now: 2)
        XCTAssertEqual(m.pairDistance ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(m.readout, "A→B 2.00 m")
        XCTAssertEqual(m.opacity(now: 11.25), 0.5, accuracy: 1e-9)        // fading over the last 1.5 s
        m.expire(now: 11.9)
        XCTAssertEqual(m.points.count, 2)
        m.expire(now: 12)                                                // 10 s after the newest tap
        XCTAssertTrue(m.points.isEmpty)
        XCTAssertNil(m.readout)
        XCTAssertEqual(m.opacity(now: 12), 0)
        // a third tap starts a new pair
        m.tap(at: [0, 0, 0], phone: [0, 0, 1], floor: 0, level: nil, now: 20)
        m.tap(at: [1, 0, 0], phone: [0, 0, 1], floor: 0, level: nil, now: 21)
        m.tap(at: [2, 0, 0], phone: [0, 0, 1], floor: 0, level: nil, now: 22)
        XCTAssertEqual(m.points.count, 1)
        // ARKit world frame (y up)
        var w = MeasurePoints()
        let p = w.tap(at: [0, 1.0, -2], phone: [0, 1.4, 0], floor: 0.2, level: nil, upAxis: 1, now: 0)
        XCTAssertEqual(p.heightAboveFloor ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(MeasurePoints.metres(0.123), "12 cm")
    }
}
