import XCTest
@testable import SnailSightCore

/// 12.26 one-tap walk: phases, plain-word problems, summary, coverage, rate hints, capture guidance, `capture_q`.
final class WalkTests: XCTestCase {
    func inputs(_ t: Double, _ f: (inout WalkInputs) -> Void = { _ in }) -> WalkInputs {
        var i = WalkInputs(now: t)
        i.arRunning = true
        i.server = true
        f(&i)
        return i
    }

    func testPhasesFindingLockedStreaming() {
        var w = WalkSession(now: 100, cause: "test", sentBase: 5, ackedBase: 5)
        var r = w.update(inputs(100) { $0.arRunning = false })
        XCTAssertEqual(r.status.phase, .starting)
        r = w.update(inputs(101))
        XCTAssertEqual(r.status.phase, .finding)
        XCTAssertTrue(r.phaseChanged)
        XCTAssertTrue(r.status.title.hasPrefix("Finding your position"))
        r = w.update(inputs(112) { $0.locked = true; $0.sigmaCm = 2.4 })
        XCTAssertEqual(r.status.phase, .locked)
        XCTAssertEqual(r.status.title, "Locked ±2 cm: starting the live map")
        XCTAssertEqual(w.lockedAt, 112)
        w.ack(gate: "probation", dup: false)
        w.ack(gate: "trusted", dup: false)
        w.ack(gate: "trusted", dup: true)
        r = w.update(inputs(115) { $0.locked = true; $0.liveOnline = true; $0.sent = 9; $0.acked = 8; $0.serverDelayMs = 1800; $0.gate = "trusted" })
        XCTAssertEqual(r.status.phase, .streaming)
        XCTAssertEqual(r.status.title, "Streaming · 4 sent · 3 accepted · 1 trusted")
        XCTAssertTrue(r.status.detail!.hasPrefix("server delay 1.8 s"))
        XCTAssertEqual(r.status.tone, .good)
        XCTAssertNil(r.status.problem)
        XCTAssertEqual(w.acks, 2)
        XCTAssertEqual(w.dups, 1)
        XCTAssertEqual(w.trustedPct, 50)
    }

    func testPlacedWithoutLocalizerLockCountsAsLocked() {
        var w = WalkSession(now: 0, cause: "t")
        let r = w.update(inputs(5) { $0.placed = true })
        XCTAssertEqual(r.status.phase, .locked)
        XCTAssertTrue(w.everPlaced)
    }

    func testProblemsInPlainWords() {
        var w = WalkSession(now: 0, cause: "t")
        _ = w.update(inputs(1))
        XCTAssertEqual(w.problem(inputs(1) { $0.server = false }), "Can't reach the map server: keyframes are kept and sent when it's back")
        XCTAssertEqual(w.problem(inputs(1) { $0.tracking = "limited:excessiveMotion" }), "Moving too fast: slow down")
        XCTAssertEqual(w.problem(inputs(1) { $0.paused = "too hot" }), "Paused: the phone is too hot. Let it cool for a minute")
        XCTAssertEqual(w.problem(inputs(1) { $0.paused = "3D map" }), "Paused while 3D map is open")
        XCTAssertNil(w.problem(inputs(1) { $0.paused = "tracking" }))
        XCTAssertEqual(w.problem(inputs(1) { $0.queue = 40 }), "Upload behind: 40 keyframes waiting")
        XCTAssertEqual(w.problem(inputs(1) { $0.gate = "quarantined"; $0.gateWhy = "jump,structure" }),
                       "The server doesn't trust the position right now (the position keeps jumping): walk back into a mapped room")
        XCTAssertNotNil(w.problem(inputs(50)), "45 s without a lock")
        XCTAssertEqual(WalkSession.gateWords("no_lock"), "waiting for a position lock")
        XCTAssertNil(WalkSession.gateWords("something_new"))
        let s = w.status(inputs(2) { $0.server = false })
        XCTAssertEqual(s.tone, .problem)
    }

    func testSummaryAndNext() {
        var w = WalkSession(now: 0, cause: "t")
        _ = w.update(inputs(10) { $0.locked = true })
        for g in ["probation", "trusted", "trusted", "trusted"] { w.ack(gate: g, dup: false) }
        w.coverage.visit(position: [1, 1, 0.5], yaw: 0, map: true, now: 11)
        w.coverage.visit(position: [5, 1, 0.5], yaw: 1, map: true, now: 20)
        _ = w.update(inputs(130) { $0.locked = true; $0.liveOnline = true; $0.sent = 4; $0.acked = 4 })
        let s = WalkSummary(w, now: 130, queue: 0)
        XCTAssertEqual(s.lines[0], "Walked 2 min 10 s · locked after 10 s")
        XCTAssertEqual(s.lines[1], "Keyframes: 4 sent · 4 accepted · 3 trusted (75 %)")
        XCTAssertEqual(s.lines[2], "2 areas of 4 m covered")
        XCTAssertTrue(s.next.hasPrefix("The server will now improve the map and detect objects"))
        let lost = WalkSummary(WalkSession(now: 0, cause: "t"), now: 30, queue: 3)
        XCTAssertTrue(lost.lines[0].hasSuffix("never locked"))
        XCTAssertTrue(lost.next.contains("new area"))
        XCTAssertTrue(lost.lines.last!.contains("3 keyframes still uploading"))
    }

    func testCoverage() {
        var c = WalkCoverage()
        XCTAssertEqual(WalkCoverage.key(x: -0.1, y: 3.9, z: 2.8), "1/-1/0")
        XCTAssertEqual(WalkCoverage.bin(yaw: 0), 0)
        XCTAssertEqual(WalkCoverage.bin(yaw: -.pi / 2), 9)
        for k in 0..<6 { c.visit(position: [1, 1, 0], yaw: Double(k) * .pi / 6, map: true, now: Double(k)) }
        let h = c.here(now: 30)!
        XCTAssertEqual(h.inAreaS, 30)
        XCTAssertEqual(h.share, 0.5, accuracy: 1e-9)
        c.visit(position: [0, 1.5, 0], yaw: 0, map: false, now: 31)
        XCTAssertEqual(c.cells, 1, "map cells win once there are any")
        XCTAssertTrue(c.inMap)
    }

    func testRateCapObeysDownToFloorAndRecoversSlowly() {
        var r = LiveRateCap()
        XCTAssertNil(LiveRateCap.parse(["seq": 1]))
        let busy = LiveRateCap.parse(["rate": ["max_hz": 0.5, "taken": 0.3, "why": "live_world_load"]])!
        XCTAssertEqual(busy.maxHz, 0.5)
        XCTAssertTrue(r.apply(busy, now: 0))
        XCTAssertEqual(r.capHz, 1, "floor: stored keyframes are auto-improve's evidence")
        XCTAssertEqual(r.effective(user: 2), 1)
        let ok = LiveRateCap.parse(["rate": ["max_hz": NSNull(), "taken": 1.0, "why": "keeping_up"]])!
        XCTAssertNil(ok.maxHz)
        XCTAssertFalse(r.apply(ok, now: 5))
        XCTAssertFalse(r.apply(ok, now: 15))
        XCTAssertTrue(r.apply(ok, now: 26))
        XCTAssertNil(r.capHz)
        XCTAssertEqual(r.effective(user: 2), 2)
        XCTAssertFalse(r.apply(LiveRateCap.Hint(maxHz: 2, taken: 0.7, why: "live_world_load"), now: 30), "a 2 Hz tier is no cap")
        XCTAssertEqual(r.minHz, 0.5)
        XCTAssertEqual(r.hints, 5)
    }

    func testCaptureQualityMeasure() {
        let w = 64, h = 48
        // a wall facing the camera at 1.5 m, high confidence → nothing to say
        var d = [UInt16](repeating: UInt16(1500).littleEndian, count: w * h)
        var c = [UInt8](repeating: 2, count: w * h)
        let K = [1440.0, 1440.0, 960.0, 720.0]                       // 1920 wide image → scaled to 64
        var q = CaptureQuality.measure(depthMM: d, conf: c, width: w, height: h, K: K, imageW: 1920)!
        XCTAssertEqual(q.valid, 1)
        XCTAssertEqual(q.confLow, 0)
        XCTAssertEqual(q.far, 0)
        XCTAssertLessThan(q.graze, 0.05)
        // far + low confidence + a floor seen edge-on (depth grows fast with the row)
        for y in 0..<h { for x in 0..<w { d[y * w + x] = UInt16(3000 + y * 120).littleEndian; c[y * w + x] = 1 } }
        q = CaptureQuality.measure(depthMM: d, conf: c, width: w, height: h, K: K, imageW: 1920)!
        XCTAssertEqual(q.far, 1)
        XCTAssertEqual(q.confLow, 1)
        // glass: no depth
        d = [UInt16](repeating: 0, count: w * h)
        q = CaptureQuality.measure(depthMM: d, conf: nil, width: w, height: h, K: K, imageW: 1920)!
        XCTAssertEqual(q.valid, 0)
        XCTAssertNil(CaptureQuality.measure(depthMM: [], conf: nil, width: w, height: h, K: K, imageW: 1920))
        XCTAssertEqual(q.json["valid"] as? Double, 0)
    }

    func testGrazingFloor() {
        // a floor 1.4 m below the camera, looking level: rays hit it at grazing angles near the horizon rows
        let w = 64, h = 48, fx = 1440.0 * 64 / 1920, cy = 720.0 * 64 / 1920
        var d = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            let dy = (Double(y) - cy) / fx
            if dy > 0.05 { for x in 0..<w { d[y * w + x] = UInt16(min(65000, 1.4 / dy * 1000)).littleEndian } }
        }
        let q = CaptureQuality.measure(depthMM: d, conf: nil, width: w, height: h, K: [1440, 1440, 960, 720], imageW: 1920)!
        XCTAssertGreaterThan(q.graze, 0.5)
    }

    func testGuidanceIsGentle() {
        var g = WalkGuidance()
        let far = CaptureQuality(confLow: 0.1, far: 0.8, graze: 0.1, valid: 0.9)
        let good = CaptureQuality(confLow: 0.1, far: 0.1, graze: 0.1, valid: 0.95)
        func holds(_ q: CaptureQuality, blur: Double? = nil) -> Set<WalkHintKind> {
            WalkGuidance.conditions(q: q, blurPx: blur, turnDegS: nil, moveMS: nil, coverage: nil)
        }
        XCTAssertEqual(holds(far), [.far])
        XCTAssertEqual(holds(good, blur: 9), [.speed])
        XCTAssertEqual(WalkGuidance.conditions(q: CaptureQuality(confLow: 0.9, far: 0.9, graze: 0.9, valid: 0.2), blurPx: nil,
                                               turnDegS: nil, moveMS: nil, coverage: (30, 0.25)), [.nodepth, .coverage])
        var t = 0.0
        var shownAt: Double?
        for _ in 0..<3 { XCTAssertNil(g.step(holds(far), now: t)); t += 0.5 }      // a moment of far: nothing yet
        if let c = g.step(holds(far), now: t) { XCTAssertEqual(c.kind, .far); XCTAssertTrue(c.on); shownAt = t }
        XCTAssertEqual(shownAt, 1.5, "4 of the last 6 samples")
        t += 0.5
        // good again at once: the hint stays its minimum 4 s, then clears
        var cleared: Double?
        while t < 10 { if let c = g.step(holds(good), now: t), !c.on { cleared = t; break }; t += 0.5 }
        XCTAssertEqual(cleared, 5.5)
        // far again soon after: cooled down, nothing for 25 s
        var again: Double?
        t += 0.5
        while t < 40 { if let c = g.step(holds(far), now: t), c.on { again = t; break }; t += 0.5 }
        XCTAssertEqual(again!, 30.5, accuracy: 0.01)
        XCTAssertEqual(g.shownText, "far:2")
        g.keyframe(far); g.keyframe(good)
        XCTAssertEqual(g.means!.far, 0.45, accuracy: 1e-9)
    }

    func testWalkDeepLink() {
        let d = AppDeepLink.parse("snailsight://walk")!
        XCTAssertEqual(d.mode, .ar)
        XCTAssertTrue(d.walk)
        XCTAssertFalse(AppDeepLink.parse("snailsight://ar")!.walk)
    }

    func testHeaderCarriesCaptureQualityAndGateFields() throws {
        let h = LiveKeyframeHeader(seq: 3, streamID: "ar-0000abcd", t: 1, wall: 2, T: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                                   K: [1, 1, 1, 1], imageSize: [1920, 1440], tracking: "normal",
                                   mapLock: LiveMapLock(T_map_arkit: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1], source: "server",
                                                        sigmaCm: 2, ageS: 30),
                                   captureQ: CaptureQuality(confLow: 0.31234, far: 0.1, graze: 0.2, valid: 0.9))
        let data = try XCTUnwrap(LiveKeyframe.encode(h, blobs: [(name: "depth_png", data: Data([1])), (name: "rgb_jpg", data: Data([2])),
                                                                (name: "conf_png", data: Data([3]))]))
        let p = try XCTUnwrap(LiveKeyframe.parse(data))
        // what the server's gate reads (locgate / livefront.map_lock): tracking, T_map_arkit, lock.source / age_s, conf_png
        XCTAssertEqual(p.header["tracking"] as? String, "normal")
        XCTAssertEqual((p.header["T_map_arkit"] as? [Any])?.count, 16)
        let lock = try XCTUnwrap(p.header["lock"] as? [String: Any])
        XCTAssertEqual(lock["source"] as? String, "server")
        XCTAssertEqual(lock["age_s"] as? Double, 30)
        XCTAssertEqual(p.blobs.map(\.name), ["depth_png", "rgb_jpg", "conf_png"])
        let q = try XCTUnwrap(p.header["capture_q"] as? [String: Any])
        XCTAssertEqual(q["conf_low"] as? Double, 0.312)
    }
}
