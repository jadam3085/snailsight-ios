import XCTest
import simd
@testable import SnailSightCore

final class MeasureTests: XCTestCase {
    func testTwoPointCycle() {
        var m = TwoPointMeasure()
        XCTAssertNil(m.distance)
        XCTAssertEqual(m.add(SIMD3(0, 0, 0)), .first(SIMD3(0, 0, 0)))
        guard case .second(_, _, let d) = m.add(SIMD3(0, 0, -1)) else { return XCTFail("expected second") }
        XCTAssertEqual(d, 1, accuracy: 1e-6)
        XCTAssertEqual(m.distance!, 1, accuracy: 1e-6)
        XCTAssertEqual(m.add(SIMD3(5, 0, 0)), .first(SIMD3(5, 0, 0)))   // third tap restarts
        XCTAssertNil(m.distance)
        m.reset()
        XCTAssertNil(m.a)
    }
}

final class FPSMeterTests: XCTestCase {
    func testSixtyHz() {
        var f = FPSMeter(window: 1.0)
        for i in 0..<180 { f.tick(Double(i) / 60.0) }
        XCTAssertEqual(f.fps, 60, accuracy: 0.5)
    }

    func testThirtyHzAfterDrop() {
        var f = FPSMeter(window: 1.0)
        for i in 0..<120 { f.tick(Double(i) / 60.0) }
        let t0 = 2.0
        for i in 0..<90 { f.tick(t0 + Double(i) / 30.0) }
        XCTAssertEqual(f.fps, 30, accuracy: 0.5)
    }

    func testResetOnClockGoingBack() {
        var f = FPSMeter()
        f.tick(10); f.tick(10.5)
        f.tick(1.0)
        XCTAssertEqual(f.fps, 0)
    }
}

final class TrackingStatusTests: XCTestCase {
    func testLabelsAndSeverity() {
        XCTAssertEqual(TrackingStatus.normal.label, "TRACKING NORMAL")
        XCTAssertEqual(TrackingStatus.normal.severity, .ok)
        XCTAssertNil(TrackingStatus.normal.hint)
        XCTAssertEqual(TrackingStatus.limited(.excessiveMotion).label, "TRACKING LIMITED · too fast")
        XCTAssertEqual(TrackingStatus.limited(.excessiveMotion).hint, "Slow down")
        XCTAssertEqual(TrackingStatus.limited(.insufficientFeatures).severity, .warn)
        XCTAssertEqual(TrackingStatus.notAvailable.severity, .bad)
        XCTAssertEqual(TrackingStatus.limited(.relocalizing).code, "limited:relocalizing")
    }
}

final class SessionLogTests: XCTestCase {
    func testLineIsSingleJSONObjectWithNewline() throws {
        let e = LogEvent(t: 1791766273.5, ev: "measure",
                         data: ["cm": .double(100.2), "ok": .bool(true), "n": .int(2), "a": .doubles([1, 2, 3]), "s": .string("x/y")])
        let d = LogFormat.line(e)
        XCTAssertEqual(d.last, 0x0A)
        XCTAssertEqual(d.filter { $0 == 0x0A }.count, 1)
        let back = try JSONDecoder().decode(LogEvent.self, from: d.dropLast())
        XCTAssertEqual(back, e)
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("\"s\":\"x/y\""))
    }

    func testNonFiniteBecomesZero() throws {
        let d = LogFormat.line(LogEvent(t: 0, ev: "fps", data: ["fps": .double(.nan)]))
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("\"fps\":0"))
    }

    func testFileNameUTC() {
        XCTAssertEqual(LogFormat.fileName(start: Date(timeIntervalSince1970: 0)), "session-19700101-000000.jsonl")
    }

    func testPruneKeepsNewest() {
        let names = ["session-20261011-100000.jsonl", "session-20261009-100000.jsonl", "notes.txt",
                     "session-20261010-100000.jsonl"]
        XCTAssertEqual(LogFormat.filesToPrune(names, keep: 2), ["session-20261009-100000.jsonl"])
        XCTAssertEqual(LogFormat.filesToPrune(names, keep: 5), [])
    }
}
