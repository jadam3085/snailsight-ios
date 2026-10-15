import XCTest
@testable import SnailSightCore

/// 9.8 "Slow down" hint retune (owner: "any movement at all shows me a turtle").
final class MotionHintTests: XCTestCase {
    func testSlowDownHint() {
        // 9.8: ordinary walking (≤ 6 px predicted) never shows it; sustained 12 px must last 0.7 s; hides at once
        var h = MotionHint()
        var t = 0.0
        for _ in 0..<30 { h.update(blurPx: 5, at: t); t += 0.1 }
        XCTAssertFalse(h.active)
        for _ in 0..<5 { h.update(blurPx: 12, at: t); t += 0.1 }
        XCTAssertFalse(h.active)                                     // a short sweep: not yet
        for _ in 0..<8 { h.update(blurPx: 12, at: t); t += 0.1 }
        XCTAssertTrue(h.active)
        h.update(blurPx: 7, at: t); t += 0.1                         // hysteresis: stays on between off and on
        XCTAssertTrue(h.active)
        for _ in 0..<4 { h.update(blurPx: 0.5, at: t); t += 0.1 }
        XCTAssertFalse(h.active)
        // cooldown: fast again right away does not re-show it for 3 s
        for _ in 0..<15 { h.update(blurPx: 15, at: t); t += 0.1 }
        XCTAssertFalse(h.active)
        for _ in 0..<20 { h.update(blurPx: 15, at: t); t += 0.1 }
        XCTAssertTrue(h.active)
    }

    func testSlowDownHintConfirmedBySharpness() {
        var h = MotionHint()
        for s in [100.0, 110, 90, 105, 95] { h.keyframe(sharpness: s) }
        XCTAssertTrue(h.lastKeyframeSharp)                           // the newest keyframe is as sharp as usual
        var t = 0.0
        for _ in 0..<20 { h.update(blurPx: 15, at: t); t += 0.1 }
        XCTAssertFalse(h.active)                                     // predicted blur, but frames are sharp
        h.keyframe(sharpness: 30)                                    // real blur measured
        XCTAssertFalse(h.lastKeyframeSharp)
        for _ in 0..<10 { h.update(blurPx: 15, at: t); t += 0.1 }
        XCTAssertTrue(h.active)
        h.keyframe(sharpness: 100)                                   // sharp again: hide
        h.update(blurPx: 15, at: t)
        XCTAssertFalse(h.active)
    }
}
