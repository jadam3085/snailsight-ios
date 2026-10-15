import XCTest
@testable import SnailSightCore

/// 9.1.61 crash-safety: segments, checkpoint, recovery of a killed capture, adaptive policy.
final class RecoveryTests: XCTestCase {
    private func jpeg(_ n: Int = 300) -> Data { Data([0xFF, 0xD8]) + Data(repeating: 0x11, count: n) + Data([0xFF, 0xD9]) }

    private func png(w: Int = 256, h: Int = 192) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        d += Data([UInt8(w >> 24), UInt8(w >> 16 & 255), UInt8(w >> 8 & 255), UInt8(w & 255),
                   UInt8(h >> 24), UInt8(h >> 16 & 255), UInt8(h >> 8 & 255), UInt8(h & 255)])
        d += Data(repeating: 0x22, count: 200)
        d += Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        return d
    }

    private func odoLine(_ i: Int) -> String {
        CaptureFormat.odometryLine(timestamp: 100 + Double(i) * 0.1, frame: i, position: [Double(i) * 0.01, 0, 0],
                                   rotationRows: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
    }

    /// A folder as a killed 9.1.60/9.1.61 recorder leaves it: frames 0..<n complete, the last frame's JPEG truncated,
    /// one frame written but its odometry row not yet, a half-written odometry + imu line, no capture.json.
    private func makeKilledCapture(n: Int, checkpoint: CaptureCheckpoint?) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ss-rec-\(UUID().uuidString)")
            .appendingPathComponent("cap-20261012-035412")
        for s in ["rgb", "depth", "confidence"] {
            try fm.createDirectory(at: dir.appendingPathComponent(s), withIntermediateDirectories: true)
        }
        var odo = CaptureFormat.odometryHeader
        for i in 0..<n {
            let stem = CaptureNaming.frameStem(i)
            try (i == n - 1 ? jpeg().prefix(100) : jpeg()).write(to: dir.appendingPathComponent("rgb/\(stem).jpg"))
            try png().write(to: dir.appendingPathComponent("depth/\(stem).png"))
            try png().write(to: dir.appendingPathComponent("confidence/\(stem).png"))
            odo += odoLine(i)
        }
        // frame n: files written, odometry row never written (killed between the two)
        let stem = CaptureNaming.frameStem(n)
        try jpeg().write(to: dir.appendingPathComponent("rgb/\(stem).jpg"))
        try png().write(to: dir.appendingPathComponent("depth/\(stem).png"))
        odo += "100.9, 9"                                                   // half-written row
        try Data(odo.utf8).write(to: dir.appendingPathComponent("odometry.csv"))
        var imu = CaptureFormat.imuHeader
        for i in 0..<50 { imu += CaptureFormat.imuLine(timestamp: 100 + Double(i) * 0.01, accelG: [0, -1, 0], gyro: [0, 0, 0]) }
        imu += "100.5, 0.1"
        try Data(imu.utf8).write(to: dir.appendingPathComponent("imu.csv"))
        try Data(CaptureFormat.cameraMatrix(fx: 1400, fy: 1400, cx: 960, cy: 720).utf8)
            .write(to: dir.appendingPathComponent("camera_matrix.csv"))
        if let cp = checkpoint { try cp.encoded().write(to: dir.appendingPathComponent(CaptureCheckpoint.fileName)) }
        // keyframes on frames 0, 4, 8 (+ n-1 truncated, + n which has no odometry row); rows for 0, 4 and a stray 99
        try fm.createDirectory(at: dir.appendingPathComponent("keyframes"), withIntermediateDirectories: true)
        var kf = CaptureFormat.keyframesHeader
        for i in Set([0, 4, 8, n - 1, n]) where i <= n {
            try (i == n - 1 ? jpeg(3000).prefix(500) : jpeg(3000))
                .write(to: dir.appendingPathComponent("keyframes/\(CaptureNaming.frameStem(i)).jpg"))
        }
        for i in [0, 4, n - 1, 99] {
            kf += CaptureFormat.keyframeLine(frame: i, timestamp: 100 + Double(i) * 0.1, width: 1920, height: 1440,
                                             fx: 1400, fy: 1400, cx: 960, cy: 720, sharpness: 512.5, blurPx: 0.8,
                                             exposureS: 0.004, iso: 640, candidates: 4)
        }
        try Data(kf.utf8).write(to: dir.appendingPathComponent("keyframes.csv"))
        return dir
    }

    func testNeedsRecovery() {
        XCTAssertTrue(CaptureRecovery.needsRecovery(fileNames: ["odometry.csv", "rgb", "imu.csv"]))
        XCTAssertFalse(CaptureRecovery.needsRecovery(fileNames: ["odometry.csv", "capture.json"]))
        XCTAssertFalse(CaptureRecovery.needsRecovery(fileNames: ["rgb"]))
    }

    func testRepairCSVDropsPartialAndMalformedLines() {
        let t = "h1, h2\n1, 2\n3, x\n4, 5, 6\n7, 8\n9,"
        let (out, dropped) = CaptureRecovery.repairCSV(t, columns: 2)
        XCTAssertEqual(out, "h1, h2\n1, 2\n7, 8\n")
        XCTAssertEqual(dropped, 3)
        XCTAssertEqual(CaptureRecovery.repairCSV("h\n1\n2\n", columns: 1).1, 0)
        XCTAssertEqual(CaptureRecovery.repairCSV("", columns: 3).0, "")
    }

    func testCompletenessAndPNGSize() {
        XCTAssertTrue(CaptureRecovery.isComplete(jpeg(), ext: "jpg"))
        XCTAssertFalse(CaptureRecovery.isComplete(jpeg().prefix(50), ext: "jpg"))
        XCTAssertTrue(CaptureRecovery.isComplete(png(), ext: "png"))
        XCTAssertFalse(CaptureRecovery.isComplete(png().prefix(100), ext: "png"))
        XCTAssertFalse(CaptureRecovery.isComplete(Data(), ext: "png"))
        XCTAssertEqual(CaptureRecovery.pngSize(png(w: 256, h: 192)).map { [$0.0, $0.1] }, [256, 192])
        XCTAssertNil(CaptureRecovery.pngSize(Data([1, 2, 3])))
    }

    func testStartFromName() {
        XCTAssertEqual(CaptureRecovery.startFromName("cap-20261012-035412"), 1791777252)
        XCTAssertNil(CaptureRecovery.startFromName("x-20261012-035412"))
    }

    func testRecoverLegacyFolderWithoutCheckpoint() throws {
        let dir = try makeKilledCapture(n: 10, checkpoint: nil)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = try CaptureRecovery.recover(dir: dir, fallbackMeta: ["agent_id": "phone-x", "app_version": "9.1.61"],
                                            now: 1_791_800_000)
        XCTAssertFalse(r.discarded)
        XCTAssertFalse(r.checkpoint)
        XCTAssertEqual(r.frames, 9)                         // frame 9 truncated jpg → row dropped; frame 10 had no row
        XCTAssertEqual(r.rowsDropped, 2)                    // half-written line + row of the truncated frame
        XCTAssertEqual(r.imuLinesDropped, 1)
        let odo = try String(contentsOf: dir.appendingPathComponent("odometry.csv"), encoding: .utf8)
        XCTAssertEqual(CaptureRecovery.odometryFrames(odo), Array(0..<9))
        XCTAssertTrue(odo.hasSuffix("\n"))
        let fm = FileManager.default
        for s in ["rgb", "depth", "confidence"] {      // no orphans: every frame file has its row
            let names = try fm.contentsOfDirectory(atPath: dir.appendingPathComponent(s).path).sorted()
            XCTAssertEqual(names, (0..<9).map { "\(CaptureNaming.frameStem($0)).\(s == "rgb" ? "jpg" : "png")" }, s)
        }
        let imu = try String(contentsOf: dir.appendingPathComponent("imu.csv"), encoding: .utf8)
        XCTAssertEqual(imu.split(separator: "\n").count, 51)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("capture.json")))
                                    as? [String: Any])
        XCTAssertEqual(meta["recovered"] as? Bool, true)
        XCTAssertEqual(meta["partial"] as? Bool, true)
        XCTAssertEqual(meta["stop_reason"] as? String, "app_killed")
        XCTAssertEqual(meta["frames"] as? Int, 9)
        XCTAssertEqual(meta["agent_id"] as? String, "phone-x")
        XCTAssertEqual(meta["started"] as? Double, 1791777252)
        XCTAssertEqual(meta["depth_size"] as? [Int], [256, 192])
        XCTAssertEqual(meta["schema"] as? String, CaptureFormat.schema)
        XCTAssertGreaterThan(r.bytes, 0)
        // keyframes: 0 and 4 kept (rows + complete files); 8 had no row, 9 truncated, 10 no odometry, 99 no file
        XCTAssertEqual(r.keyframes, 2)
        XCTAssertEqual(meta["keyframes"] as? Int, 2)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("keyframes").path).sorted(),
                       ["000000.jpg", "000004.jpg"])
        let kf = try String(contentsOf: dir.appendingPathComponent("keyframes.csv"), encoding: .utf8)
        XCTAssertEqual(CaptureRecovery.odometryFrames("x\n" + kf.split(separator: "\n").dropFirst()
                        .map { "0, " + $0.split(separator: ",")[0] }.joined(separator: "\n")), [0, 4])
        // a second pass is a no-op: the folder is now a normal capture
        let names = Set(try fm.contentsOfDirectory(atPath: dir.path))
        XCTAssertFalse(CaptureRecovery.needsRecovery(fileNames: names))
    }

    func testRecoverWithCheckpointUsesItsMeta() throws {
        var cp = CaptureCheckpoint(clientSessionID: "cap-20261012-035412", started: 1_791_777_252.8,
                                   meta: ["agent_id": "phone-4e358c8a", "device": "iPhone16,2"])
        cp.fullSize = [1920, 1440]; cp.depthSize = [256, 192]; cp.rateHz = 5; cp.dropped = 2
        cp.segments = [CaptureSegment(index: 0, firstFrame: 0, lastFrame: 5, t0: 100, t1: 100.5)]
        let dir = try makeKilledCapture(n: 8, checkpoint: cp)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = try CaptureRecovery.recover(dir: dir, fallbackMeta: ["agent_id": "ignored"])
        XCTAssertTrue(r.checkpoint)
        XCTAssertEqual(r.segments, 1)
        XCTAssertEqual(r.frames, 7)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("capture.json")))
                                    as? [String: Any])
        XCTAssertEqual(meta["agent_id"] as? String, "phone-4e358c8a")
        XCTAssertEqual(meta["rate_hz"] as? Double, 5)
        XCTAssertEqual(meta["dropped"] as? Int, 2)
        XCTAssertEqual(meta["started"] as? Double, 1_791_777_252.8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(CaptureCheckpoint.fileName).path))
    }

    func testRecoverDiscardsEmptyCapture() throws {
        let dir = try makeKilledCapture(n: 1, checkpoint: nil)       // only frame 0, and its jpg is truncated
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = try CaptureRecovery.recover(dir: dir)
        XCTAssertTrue(r.discarded)
        XCTAssertEqual(r.frames, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCheckpointRoundTripAndTolerantDecode() throws {
        var cp = CaptureCheckpoint(clientSessionID: "cap-1", started: 5, meta: ["a": "b"])
        cp.segments = [CaptureSegment(index: 0, firstFrame: 0, lastFrame: 99, t0: 1, t1: 11)]
        let back = try JSONDecoder().decode(CaptureCheckpoint.self, from: cp.encoded())
        XCTAssertEqual(back, cp)
        let minimal = try JSONDecoder().decode(CaptureCheckpoint.self, from: Data(#"{"client_session_id":"cap-2"}"#.utf8))
        XCTAssertEqual(minimal.clientSessionID, "cap-2")
        XCTAssertEqual(minimal.segments, [])
        XCTAssertTrue(String(decoding: cp.encoded(), as: UTF8.self).contains("\"first_frame\":0"))
    }

    func testSegmentTracker() {
        var s = SegmentTracker(seconds: 10)
        var closedAt: [Int] = []
        for i in 0..<250 {                         // 10 Hz for 25 s → segments close at ~10 s and ~20 s
            if let c = s.frameWritten(index: i, t: Double(i) * 0.1) { closedAt.append(c.lastFrame) }
        }
        XCTAssertEqual(closedAt, [100, 201])
        XCTAssertEqual(s.closed.map(\.firstFrame), [0, 101])
        s.finish()
        XCTAssertEqual(s.closed.count, 3)
        XCTAssertEqual(s.closed.last?.lastFrame, 249)
        XCTAssertEqual(s.closed.map(\.index), [0, 1, 2])
    }

    func testMeshCapAndHUDText() {
        // mesh memory cap: freezes the mesh, keeps the rate, neutral note instead of a warning
        let c = AdaptiveCapture.decide(thermal: .nominal, availableMB: 3000, meshVertices: AdaptiveCapture.meshVertexCap + 1)
        XCTAssertEqual(c.meshMode, .frozen); XCTAssertEqual(c.rateHz, 10); XCTAssertNil(c.warning); XCTAssertNotNil(c.note)
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .nominal, availableMB: 3000, meshVertices: 10).meshMode, .live)
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .fair, availableMB: 3000, meshVertices: 10).meshMode, .throttled)
        XCTAssertTrue(MeshMode.live < MeshMode.throttled && MeshMode.throttled < MeshMode.frozen)
        XCTAssertEqual(AdaptiveCapture.rateLine(arFPS: 59.6, recording: false, recRateHz: 10), "AR 60 fps")
        XCTAssertEqual(AdaptiveCapture.rateLine(arFPS: 60, recording: true, recRateHz: 5), "AR 60 fps · REC 5 fps")
        XCTAssertEqual(AdaptiveCapture.rateLine(arFPS: 60, recording: true, recRateHz: 0), "AR 60 fps · REC stopped")
        XCTAssertEqual(AdaptiveCapture.meshLabel(.frozen, recording: true), "frozen")
        XCTAssertEqual(AdaptiveCapture.meshRebuildInterval(.throttled), 8)
        XCTAssertEqual(AdaptiveCapture.meshRebuildInterval(.live), 4)
    }

    func testAdaptivePolicy() {
        let n = AdaptiveCapture.decide(thermal: .nominal, availableMB: 2500)
        XCTAssertEqual(n.rateHz, 10); XCTAssertFalse(n.shedMesh); XCTAssertNil(n.stopReason); XCTAssertNil(n.warning)
        XCTAssertEqual(n.meshMode, .live)
        // 9.6: fair with plenty of memory keeps 10 Hz and the mesh (updates throttled), no orange warning
        let f = AdaptiveCapture.decide(thermal: .fair, availableMB: 2500)
        XCTAssertEqual(f.rateHz, 10); XCTAssertFalse(f.shedMesh); XCTAssertEqual(f.meshMode, .throttled)
        XCTAssertEqual(f.level, "warm"); XCTAssertNil(f.warning); XCTAssertNil(f.stopReason)
        // fair + low memory → reduced, mesh frozen (kept visible), says so
        let fl = AdaptiveCapture.decide(thermal: .fair, availableMB: 1000)
        XCTAssertEqual(fl.rateHz, 5); XCTAssertEqual(fl.meshMode, .frozen); XCTAssertEqual(fl.level, "reduced")
        XCTAssertTrue(fl.warning?.contains("mesh frozen") == true)
        XCTAssertTrue(fl.warning?.contains("REC 5 fps") == true)
        // 9.8: serious with memory fine eases off quietly (5 Hz, mesh throttled, no banner); with memory low → 2 Hz
        let s = AdaptiveCapture.decide(thermal: .serious, availableMB: nil)
        XCTAssertEqual(s.rateHz, 5); XCTAssertLessThan(s.jpegQuality, n.jpegQuality); XCTAssertNil(s.warning)
        XCTAssertEqual(s.meshMode, .throttled); XCTAssertEqual(s.level, "hot")
        let sl = AdaptiveCapture.decide(thermal: .serious, availableMB: 1000)
        XCTAssertEqual(sl.rateHz, 2); XCTAssertEqual(sl.meshMode, .frozen); XCTAssertNotNil(sl.warning)
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .critical, availableMB: 3000).stopReason, "thermal_critical")
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .nominal, availableMB: 300).stopReason, "memory_low")
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .nominal, availableMB: 1000).level, "reduced")
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .nominal, availableMB: 600).level, "minimal")
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .nominal, availableMB: 3000, memoryWarnings: 1).level, "reduced")
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .nominal, availableMB: 3000, memoryWarnings: 2).level, "minimal")
        XCTAssertTrue(sl.warning?.contains("REC 2 fps") == true)
        XCTAssertEqual(ThermalLevel(label: "SERIOUS"), .serious)
        XCTAssertEqual(ThermalLevel(label: "?"), .nominal)
    }

    func testKeyframeGateAndLine() {
        XCTAssertTrue(AdaptiveCapture.isKeyframe(translationM: nil, rotationDeg: nil, sinceLastS: nil))     // first
        XCTAssertFalse(AdaptiveCapture.isKeyframe(translationM: 1, rotationDeg: 0, sinceLastS: 1.0))         // too soon
        XCTAssertTrue(AdaptiveCapture.isKeyframe(translationM: 0.45, rotationDeg: 0, sinceLastS: 2))
        XCTAssertTrue(AdaptiveCapture.isKeyframe(translationM: 0.1, rotationDeg: 16, sinceLastS: 2))
        XCTAssertFalse(AdaptiveCapture.isKeyframe(translationM: 0.3, rotationDeg: 10, sinceLastS: 5))
        XCTAssertFalse(AdaptiveCapture.isKeyframe(translationM: 0.45, rotationDeg: 0, sinceLastS: 4, scale: 2))
        XCTAssertFalse(AdaptiveCapture.isKeyframe(translationM: nil, rotationDeg: nil, sinceLastS: nil, scale: 0))
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .serious, availableMB: 800).keyframeScale, 2)
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .serious, availableMB: nil).keyframeScale, 1)
        XCTAssertEqual(AdaptiveCapture.decide(thermal: .nominal, availableMB: nil).keyframeScale, 1)
        XCTAssertEqual(CaptureFormat.keyframeLine(frame: 7, timestamp: 1.5, width: 1920, height: 1440,
                                                  fx: 1400.25, fy: 1400, cx: 960, cy: 720.5),
                       "7, 1.500000, 1920, 1440, 1400.2500, 1400.0000, 960.0000, 720.5000\n")
    }

    func testMotionGate() {
        XCTAssertFalse(AdaptiveCapture.moved(translationM: 0.005, rotationDeg: 0.5, sinceLastS: 0.2))
        XCTAssertTrue(AdaptiveCapture.moved(translationM: 0.03, rotationDeg: 0, sinceLastS: 0.1))
        XCTAssertTrue(AdaptiveCapture.moved(translationM: 0, rotationDeg: 3, sinceLastS: 0.1))
        XCTAssertTrue(AdaptiveCapture.moved(translationM: 0, rotationDeg: 0, sinceLastS: 1.0))
        let a = CaptureFormat.Quat(x: 0, y: 0, z: 0, w: 1)
        let b = CaptureFormat.Quat(x: 0, y: sin(5 * .pi / 360), z: 0, w: cos(5 * .pi / 360))   // 5° about y
        XCTAssertEqual(AdaptiveCapture.rotationDegrees(a, b), 5, accuracy: 1e-6)
        XCTAssertEqual(AdaptiveCapture.rotationDegrees(a, a), 0, accuracy: 1e-6)
    }
}
