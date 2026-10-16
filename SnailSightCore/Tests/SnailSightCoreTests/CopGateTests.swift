import XCTest
@testable import SnailSightCore

final class CopGateTests: XCTestCase {
    func testWakingAnswer() {
        let b = Data(#"{"cop": "waking", "retry_s": 10, "class": "phone-capture", "detail": "COP is waking up"}"#.utf8)
        let c = CopState.parse(status: 503, body: b)
        XCTAssertEqual(c?.kind, .waking)
        XCTAssertEqual(c?.retryS, 10)
        XCTAssertEqual(c?.label, "COP waking…")
    }

    func testOffAnswerWithFractionalRetry() {
        let b = Data(#"{"cop": "off", "retry_s": 60.5, "detail": "class phone-live may not wake the COP"}"#.utf8)
        let c = CopState.parse(status: 503, body: b)
        XCTAssertEqual(c?.kind, .off)
        XCTAssertEqual(c?.retryS, 60.5)
        XCTAssertEqual(c?.label, "COP off")
    }

    func testNotAGateAnswer() {
        XCTAssertNil(CopState.parse(status: 200, body: Data(#"{"cop": "off"}"#.utf8)))
        XCTAssertNil(CopState.parse(status: 503, body: Data(#"{"detail": "busy"}"#.utf8)))
        XCTAssertNil(CopState.parse(status: 503, body: Data("not json".utf8)))
        XCTAssertNil(CopState.parse(status: 503, body: Data(#"{"cop": "sleeping"}"#.utf8)))
    }

    func testRetryIsClamped() {
        XCTAssertEqual(CopState.parse(status: 503, body: Data(#"{"cop": "waking", "retry_s": 0}"#.utf8))?.retryS, 2)
        XCTAssertEqual(CopState.parse(status: 503, body: Data(#"{"cop": "off", "retry_s": 9999}"#.utf8))?.retryS, 300)
        XCTAssertEqual(CopState.parse(status: 503, body: Data(#"{"cop": "off"}"#.utf8))?.retryS, 10)
    }

    func testPillAndWakeClass() {
        XCTAssertEqual(CopState.pill("COP off", pending: 0), "COP off")
        XCTAssertEqual(CopState.pill("COP off", pending: 2), "COP off · 2 waiting")
        XCTAssertTrue(CopState.isCopLabel("COP waking…"))
        XCTAssertFalse(CopState.isCopLabel("tailnet"))
        XCTAssertEqual(CopWake.wakeClass(pendingUploads: 1), "phone-capture")
        XCTAssertEqual(CopWake.wakeClass(pendingUploads: 0), "phone-live")
    }
}
