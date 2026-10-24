import XCTest
@testable import SnailSightCore

final class LiveKeyframeTests: XCTestCase {
    private func header(seq: Int = 7) -> LiveKeyframeHeader {
        LiveKeyframeHeader(seq: seq, streamID: "ar-1a2b3c4d", t: 1234.5, wall: 1_760_000_000.25,
                           T: [1, 0, 0, 0.5, 0, 1, 0, 1.2, 0, 0, 1, -0.3, 0, 0, 0, 1],
                           K: [1400, 1400, 960, 720], imageSize: [1920, 1440])
    }

    func testFrameLayoutMatchesContract() throws {
        let depth = Data([1, 2, 3, 4]), rgb = Data([9, 9, 9]), conf = Data([5])
        let d = try XCTUnwrap(LiveKeyframe.encode(header(), blobs: [("depth_png", depth), ("rgb_jpg", rgb), ("conf_png", conf)]))
        XCTAssertEqual(Array(d.prefix(4)), Array("SSKF".utf8))
        let b = [UInt8](d)
        let n = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])     // big-endian
        XCTAssertEqual(d.count, 8 + n + 4 + 3 + 1)
        XCTAssertEqual(Array(b.suffix(8)), [1, 2, 3, 4, 9, 9, 9, 5])               // blobs in the listed order
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(b[8..<(8 + n)])) as? [String: Any])
        XCTAssertEqual(obj["seq"] as? Int, 7)
        XCTAssertEqual(obj["stream_id"] as? String, "ar-1a2b3c4d")
        XCTAssertEqual(obj["tracking"] as? String, "normal")
        XCTAssertEqual((obj["T_arkit_cam"] as? [Double])?.count, 16)
        XCTAssertEqual(obj["K"] as? [Double], [1400, 1400, 960, 720])
        XCTAssertEqual(obj["image_size"] as? [Int], [1920, 1440])
        XCTAssertEqual(obj["wall"] as? Double, 1_760_000_000.25)
        let blobs = try XCTUnwrap(obj["blobs"] as? [[Any]])
        XCTAssertEqual(blobs.map { $0[0] as? String }, ["depth_png", "rgb_jpg", "conf_png"])
        XCTAssertEqual(blobs.map { ($0[1] as? NSNumber)?.intValue }, [4, 3, 1])
    }

    func testParseRoundTrip() throws {
        let d = try XCTUnwrap(LiveKeyframe.encode(header(seq: 3), blobs: [("depth_png", Data(repeating: 7, count: 100)),
                                                                          ("rgb_jpg", Data(repeating: 1, count: 50))]))
        let p = try XCTUnwrap(LiveKeyframe.parse(d))
        XCTAssertEqual(p.header["seq"] as? Int, 3)
        XCTAssertEqual(p.blobs.map { $0.name }, ["depth_png", "rgb_jpg"])
        XCTAssertEqual(p.blobs[0].data.count, 100)
        XCTAssertEqual(p.blobs[1].data, Data(repeating: 1, count: 50))
        XCTAssertNil(LiveKeyframe.parse(d.dropLast()))                              // truncated
        XCTAssertNil(LiveKeyframe.parse(Data("XXXX".utf8) + d.dropFirst(4)))         // bad magic
    }

    func testNonFiniteNumbersDoNotTrap() throws {
        var h = header()
        h.T[0] = .nan
        h.t = .infinity
        let d = try XCTUnwrap(LiveKeyframe.encode(h, blobs: [("depth_png", Data([0]))]))
        let p = try XCTUnwrap(LiveKeyframe.parse(d))
        XCTAssertEqual((p.header["T_arkit_cam"] as? [Double])?.first, 0)
        XCTAssertEqual(p.header["t"] as? Double, 0)
    }

    func testRowMajorFromColumns() {
        // translation lives in column 3 → row-major indices 3, 7, 11
        let cols: [[Double]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [4, 5, 6, 1]]
        let m = LiveKeyframe.rowMajor(columns: cols)
        XCTAssertEqual([m[3], m[7], m[11], m[15]], [4, 5, 6, 1])
        XCTAssertEqual(m[12], 0)
    }

    func testStreamIDs() {
        XCTAssertEqual(LiveStreamID.make(random: 0x1a2b3c4d), "ar-1a2b3c4d")
        XCTAssertTrue(LiveStreamID.isValid(LiveStreamID.make()))
        XCTAssertFalse(LiveStreamID.isValid("ar-XYZ"))
        XCTAssertFalse(LiveStreamID.isValid("phone-1a2b3c4d"))
    }
}

final class LiveGateTests: XCTestCase {
    private func pose(x: Double = 0, yawDeg: Double = 0) -> [Double] {
        let a = yawDeg * .pi / 180
        return [cos(a), 0, sin(a), x, 0, 1, 0, 0, -sin(a), 0, cos(a), 0, 0, 0, 0, 1]
    }

    func testRateAndStillness() {
        var g = LiveGate(rateHz: 2)
        XCTAssertEqual(g.check(t: 0, T: pose()), .capture)                 // first keyframe
        g.commit(t: 0, T: pose())
        XCTAssertEqual(g.check(t: 0.2, T: pose(x: 1)), .tooSoon)           // 2 Hz → 0.5 s
        XCTAssertEqual(g.check(t: 0.6, T: pose(x: 0.01)), .still)          // 1 cm, 0°
        XCTAssertEqual(g.check(t: 0.6, T: pose(x: 0.025)), .capture)       // 2.5 cm
        XCTAssertEqual(g.check(t: 0.6, T: pose(yawDeg: 1.5)), .still)
        XCTAssertEqual(g.check(t: 0.6, T: pose(yawDeg: 2.5)), .capture)    // 2.5°
        XCTAssertEqual(g.check(t: 30, T: pose()), .still)                  // no keep-alive for a still phone
        XCTAssertEqual(g.check(t: 0.497, T: pose(x: 1)), .capture)         // 60 fps frame just before the grid
        g.rateHz = 1
        XCTAssertEqual(g.check(t: 0.7, T: pose(x: 1)), .tooSoon)
        g.reset()
        XCTAssertEqual(g.check(t: 0.7, T: pose()), .capture)
    }

    func testBlurHold() {
        var g = LiveGate(rateHz: 2)
        XCTAssertEqual(g.decide(t: 0, T: pose(), blurPx: nil), .capture)          // unknown blur: at once
        g.commit(t: 0, T: pose())
        XCTAssertEqual(g.decide(t: 0.5, T: pose(x: 1), blurPx: 1.5), .capture)    // sharp: at once
        g.commit(t: 0.5, T: pose(x: 1))
        XCTAssertNil(g.dueSince)
        XCTAssertEqual(g.decide(t: 1.0, T: pose(x: 2), blurPx: 9), .blurry)       // smeared turn: wait
        XCTAssertEqual(g.dueSince, 1.0)
        XCTAssertEqual(g.decide(t: 1.1, T: pose(x: 2), blurPx: 5), .blurry)       // ≤ 6 px, but < 0.2 s
        XCTAssertEqual(g.decide(t: 1.15, T: pose(x: 2), blurPx: 1.9), .capture)   // sharp one arrives
        g.commit(t: 1.15, T: pose(x: 2))
        XCTAssertEqual(g.decide(t: 1.7, T: pose(x: 3), blurPx: 9), .blurry)
        XCTAssertEqual(g.decide(t: 1.95, T: pose(x: 3), blurPx: 5), .capture)     // ≤ 6 px after 0.2 s
        g.commit(t: 1.95, T: pose(x: 3))
        XCTAssertEqual(g.decide(t: 2.5, T: pose(x: 4), blurPx: 20), .blurry)
        XCTAssertEqual(g.decide(t: 2.85, T: pose(x: 4), blurPx: 20), .blurry)
        XCTAssertEqual(g.decide(t: 2.95, T: pose(x: 4), blurPx: 20), .capture)    // ≥ 0.4 s: take it anyway
        g.commit(t: 2.95, T: pose(x: 4))
        XCTAssertEqual(g.decide(t: 3.5, T: pose(x: 5), blurPx: 9), .blurry)
        XCTAssertEqual(g.decide(t: 3.6, T: pose(x: 4.01), blurPx: 9), .still)     // back where it was: no keyframe
        XCTAssertNil(g.dueSince)                                                    // ... and the hold restarts
        XCTAssertEqual(g.decide(t: 3.7, T: pose(x: 5), blurPx: 9), .blurry)
        XCTAssertEqual(g.dueSince, 3.7)
    }

    func testHeaderQualityKeys() {
        let T = [Double](repeating: 0, count: 16)
        var h = LiveKeyframeHeader(seq: 1, streamID: "ar-00000001", t: 1, wall: 2, T: T, K: [1, 1, 0, 0], imageSize: [4, 3])
        var o = LiveKeyframe.headerObject(h, blobs: [])
        XCTAssertNil(o["blur_px"])
        XCTAssertNil(o["exposure_s"])
        h.blurPx = 1.25
        h.exposureS = .nan
        o = LiveKeyframe.headerObject(h, blobs: [])
        XCTAssertEqual(o["blur_px"] as? Double, 1.25)
        XCTAssertEqual(o["exposure_s"] as? Double, 0)                               // non-finite -> 0, never NaN
        let data = LiveKeyframe.encode(h, blobs: [(name: "rgb_jpg", data: Data([1, 2]))])
        XCTAssertEqual(LiveKeyframe.parse(data!)?.header["blur_px"] as? Double, 1.25)
    }

    func testPersonMaskBinarize() {
        XCTAssertNil(LiveMask.binarize([]))
        XCTAssertNil(LiveMask.binarize([UInt8](repeating: 200, count: 1) + [UInt8](repeating: 0, count: 999)))  // 0.1 %
        var conf = [UInt8](repeating: 10, count: 1000)
        for i in 0..<10 { conf[i] = 128 }                                   // 1 %
        conf[10] = 127
        let m = LiveMask.binarize(conf)
        XCTAssertEqual(m?.count, 1000)
        XCTAssertEqual(m?.filter { $0 == 255 }.count, 10)
        XCTAssertEqual(m?[10], 0)
        XCTAssertEqual(LiveMask.blobName, "mask_png")
    }

    func testRateClamp() {
        XCTAssertEqual(LiveGate.clampRate(0.3), 1)
        XCTAssertEqual(LiveGate.clampRate(1), 1)
        XCTAssertEqual(LiveGate.clampRate(2), 2)
        XCTAssertEqual(LiveGate.clampRate(10), 2)
    }
}

final class LiveSpoolTests: XCTestCase {
    func testFileNames() {
        XCTAssertEqual(LiveSpool.fileName(42), "00000042.kf")
        XCTAssertEqual(LiveSpool.seq(fromFile: "00000042.kf"), 42)
        XCTAssertNil(LiveSpool.seq(fromFile: "stream.json"))
        XCTAssertNil(LiveSpool.seq(fromFile: "x.kf"))
    }

    func testWelcomeResume() {
        let r = LiveSpool.afterWelcome(spooled: [5, 3, 4, 9, 6], lastSeq: 4)
        XCTAssertEqual(r.drop, [3, 4])
        XCTAssertEqual(r.resend, [5, 6, 9])
        let fresh = LiveSpool.afterWelcome(spooled: [0, 1], lastSeq: -1)        // server has nothing
        XCTAssertEqual(fresh.drop, [])
        XCTAssertEqual(fresh.resend, [0, 1])
    }

    func testCapEvictsOldestStreamFirst() {
        var keys: [LiveSpoolKey] = []
        for s in 0..<3 { keys.append(LiveSpoolKey(stream: "ar-new", order: 200, seq: s)) }
        for s in 10..<13 { keys.append(LiveSpoolKey(stream: "ar-old", order: 100, seq: s)) }
        let out = LiveSpool.evictions(keys, cap: 4)
        XCTAssertEqual(out.map { $0.stream }, ["ar-old", "ar-old"])
        XCTAssertEqual(out.map { $0.seq }, [10, 11])
        XCTAssertEqual(LiveSpool.evictions(keys, cap: 6), [])
    }
}

final class LiveWindowTests: XCTestCase {
    func testWindowLimitAndAcks() {
        var w = LiveWindow(limit: 3)
        w.reset([4, 2, 3, 5, 6])
        XCTAssertEqual(w.next(now: 0), 2)
        XCTAssertEqual(w.next(now: 0), 3)
        XCTAssertEqual(w.next(now: 0), 4)
        XCTAssertNil(w.next(now: 0))                                   // 3 unacked
        XCTAssertEqual(w.acked(3, contiguous: 1), [3])                 // out-of-order ack
        XCTAssertEqual(w.next(now: 1), 5)
        XCTAssertEqual(w.acked(4, contiguous: 4), [2, 4])              // contiguous settles 2 as well
        XCTAssertEqual(w.pending, 2)                                   // 5 in flight, 6 queued
        w.add(7); w.add(6)                                             // duplicate add ignored
        XCTAssertEqual(w.queued, [6, 7])
    }

    func testExpireAndRequeue() {
        var w = LiveWindow(limit: 8)
        w.reset([0, 1, 2])
        _ = w.next(now: 0); _ = w.next(now: 5)
        XCTAssertEqual(w.expire(now: 12, timeout: 10), [0])
        XCTAssertEqual(w.queued, [0, 2])
        XCTAssertEqual(w.resends[0], 1)
        XCTAssertEqual(w.requeueOldest(), 1)
        XCTAssertEqual(w.queued, [0, 1, 2])
        _ = w.next(now: 20)
        w.requeueAll()
        XCTAssertEqual(w.queued, [0, 1, 2])
        XCTAssertTrue(w.inFlight.isEmpty)
        w.remove(1)
        XCTAssertEqual(w.queued, [0, 2])
        w.add(1)
        XCTAssertEqual(w.queued, [0, 1, 2])                            // sorted insert
    }
}

final class LiveTransportTests: XCTestCase {
    func testBackoff() {
        XCTAssertEqual((0..<7).map { LiveBackoff.delay(attempt: $0) }, [1, 2, 4, 8, 10, 10, 10])
    }

    func testHTTPFallbackAfterThreeFailures() {
        var c = LiveTransportChoice()
        XCTAssertFalse(c.wsFailed(now: 0))
        XCTAssertFalse(c.wsFailed(now: 1))
        XCTAssertTrue(c.wsFailed(now: 3))
        XCTAssertTrue(c.useHTTP)
        XCTAssertFalse(c.shouldRetryWS(now: 30))
        XCTAssertTrue(c.shouldRetryWS(now: 64))
        XCTAssertFalse(c.useHTTP)
        c.wsConnected()
        XCTAssertEqual(c.wsFailures, 0)
    }

    func testHUDLine() {
        XCTAssertEqual(LiveText.line(online: true, rateHz: 2, sent: 120, acked: 118, queue: 2, lagMs: 180,
                                     placed: true, via: "anchors"),
                       "LIVE 2 Hz · sent 120 · acked 118 · queue 2 · lag 180 ms · placed via anchors")
        XCTAssertEqual(LiveText.line(online: false, rateHz: 2, sent: 0, acked: 0, queue: 37, lagMs: nil,
                                     placed: nil, via: nil),
                       "LIVE offline · queue 37 (resuming)")
        XCTAssertEqual(LiveText.line(online: true, rateHz: 1, sent: 3, acked: 3, queue: 0, lagMs: nil,
                                     placed: false, via: nil, paused: "recording"),
                       "LIVE paused (recording) · sent 3 · acked 3 · queue 0 · unplaced")
        XCTAssertEqual(LiveText.median([300, 100, 200]), 200)
        XCTAssertEqual(LiveText.median([100, 200]), 150)
        XCTAssertNil(LiveText.median([]))
    }
}
