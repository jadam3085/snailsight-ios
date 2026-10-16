import XCTest
@testable import SnailSightCore

/// 10.6.x: a timeout must never end the search; background -> foreground resumes it at once.
final class LocRetryTests: XCTestCase {
    func testTimeoutThenBackoffNeverStops() {
        var r = LocRetry()
        XCTAssertEqual(r.requestTimeout, 30)                       // the first request: a cold server may warm a map
        r.sent()
        XCTAssertEqual(r.requestTimeout, 15)
        var t = 100.0
        let (d1, w1) = r.failed(status: 0, error: "The request timed out.", now: t)
        XCTAssertEqual(d1, 2); XCTAssertEqual(w1, "server slow")
        XCTAssertFalse(r.due(now: t + 1)); XCTAssertTrue(r.due(now: t + 2))
        XCTAssertEqual(r.note, "retrying (server slow)")
        var delays: [Double] = []
        for _ in 0..<6 { t += 20; r.sent(); delays.append(r.failed(status: 0, error: "The request timed out.", now: t).delay) }
        XCTAssertEqual(delays, [4, 8, 10, 10, 10, 10])               // capped, and it keeps going
        XCTAssertTrue(r.due(now: t + 10))
        r.succeeded()
        XCTAssertNil(r.note); XCTAssertTrue(r.due(now: t))
    }

    func testBackgroundForegroundResumesAtOnce() {
        var r = LocRetry()
        r.sent()
        r.failed(status: 0, error: "The request timed out.", now: 10)
        r.sent()
        r.failed(status: 0, error: "The request timed out.", now: 13)   // waiting until 17
        XCTAssertFalse(r.due(now: 14))
        XCTAssertTrue(r.resume(now: 14))                              // foreground
        XCTAssertTrue(r.due(now: 14))
        XCTAssertEqual(r.failed(status: 0, error: "x", now: 15).delay, 2)   // the backoff starts over
        XCTAssertEqual(LocRetry.why(status: 504, error: nil), "server warming")
        XCTAssertEqual(LocRetry.why(status: 0, error: "The Internet connection appears to be offline."), "offline")
    }

    func testPillShowsRetryAndPause() {
        let base = LocPillInput(online: true, phase: .searching, searchSeconds: 12, attempts: 2)
        var i = base
        i.retry = "retrying (server slow)"
        XCTAssertTrue(LocPill.make(i).text.hasSuffix("· retrying (server slow)"), LocPill.make(i).text)
        i.paused = "Scans open"
        XCTAssertEqual(LocPill.make(i).text, "FINDING YOU · paused (Scans open)")
        XCTAssertEqual(LocPill.make(LocPillInput(online: false, phase: .searching)).text, "OFFLINE")
        XCTAssertTrue(LocPill.make(base).text.hasPrefix("FINDING YOU…"))
    }
}
