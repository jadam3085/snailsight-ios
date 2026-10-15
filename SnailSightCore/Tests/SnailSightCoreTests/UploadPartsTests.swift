import XCTest
@testable import SnailSightCore

final class UploadPartsTests: XCTestCase {
    func testCRC32KnownVectors() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        let a = Data("hello ".utf8), b = Data("world".utf8)
        XCTAssertEqual(CRC32.update(CRC32.checksum(a), b), CRC32.checksum(a + b))
    }

    func testPlanIsDeterministicAndBounded() {
        let files = (0..<100).flatMap { i in
            [CaptureFile(path: "rgb/\(CaptureNaming.frameStem(i)).jpg", size: 120_000),
             CaptureFile(path: "depth/\(CaptureNaming.frameStem(i)).png", size: 60_000)]
        } + [CaptureFile(path: "odometry.csv", size: 9_000), CaptureFile(path: "huge.bin", size: 3_000_000)]
        let p = PartPlanner.plan(root: "cap-1", files: files.shuffled(), target: 1_000_000)
        XCTAssertEqual(p, PartPlanner.plan(root: "cap-1", files: files, target: 1_000_000))
        XCTAssertEqual(p.map(\.index), Array(0..<p.count))
        XCTAssertEqual(Set(p.flatMap { $0.files.map(\.path) }).count, files.count)        // every file exactly once
        XCTAssertEqual(p.flatMap(\.files).count, files.count)
        for part in p {
            XCTAssertEqual(part.size, PartPlanner.zipSize(root: "cap-1", files: part.files))
            XCTAssertTrue(part.size <= 1_000_000 || part.files.count == 1, "part \(part.index) too big")
        }
        XCTAssertTrue(p.contains { $0.files.map(\.path) == ["huge.bin"] })
        XCTAssertEqual(PartPlanner.plan(root: "x", files: []), [])
    }

    func testStoreZipMatchesPlanAndLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("rgb"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Data((0..<5000).map { UInt8($0 % 251) })
        try a.write(to: dir.appendingPathComponent("rgb/000000.jpg"))
        try Data("timestamp, frame\n".utf8).write(to: dir.appendingPathComponent("odometry.csv"))
        try Data("hidden".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        let files = try PartPlanner.listFiles(in: dir)
        XCTAssertEqual(files.map(\.path), ["odometry.csv", "rgb/000000.jpg"])
        XCTAssertEqual(files[1].size, 5000)
        let plan = PartPlanner.plan(root: "cap-9", files: files)
        XCTAssertEqual(plan.count, 1)
        let zip = try StoreZip.build(part: plan[0], root: "cap-9", dir: dir)
        XCTAssertEqual(zip.count, plan[0].size)
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Array(zip.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        // the file bytes are stored verbatim right after the header + name
        let name = "cap-9/odometry.csv"
        let body = zip.subdata(in: (30 + name.utf8.count)..<(30 + name.utf8.count + 17))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "timestamp, frame\n")
        XCTAssertThrowsError(try StoreZip.build(part: PartPlan(index: 0, files: [CaptureFile(path: "nope", size: 1)], size: 0),
                                                root: "cap-9", dir: dir))
    }

    /// Upload queue file written by 9.1.59 (no mode/parts keys) must still decode, and migrate to parts.
    func testLegacyQueueDecodesAndMigrates() throws {
        let legacy = """
        [{"clientSessionID":"cap-20261012-030807","frames":1277,"captureBytes":265550000,"bytesTotal":0,"received":0,
          "state":"recorded","attempts":0,"nextAttempt":0,"lastPoll":0,"localDeleted":false,"created":1791774617.6},
         {"clientSessionID":"cap-old","frames":10,"captureBytes":1000,"bytesTotal":900,"received":900,"sessionID":"s-1",
          "state":"processed","attempts":0,"nextAttempt":0,"lastPoll":0,"localDeleted":true,"created":1}]
        """
        var items = try JSONDecoder().decode([UploadItem].self, from: Data(legacy.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].mode, "stream")
        XCTAssertFalse(items[0].serverHasAll)
        XCTAssertTrue(items[0].migrateToParts())
        XCTAssertEqual(items[0].mode, "parts")
        XCTAssertEqual(items[0].state, "recorded")
        XCTAssertNil(items[0].sessionID)
        XCTAssertFalse(items[1].migrateToParts())             // finished items stay as they are
        XCTAssertTrue(items[1].serverHasAll)
        let back = try JSONDecoder().decode([UploadItem].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(back, items)
    }

    func testPartsProgressAndScheduling() {
        var it = UploadItem(clientSessionID: "cap-1", frames: 3, captureBytes: 300)
        XCTAssertEqual(it.mode, "parts")
        it.parts = [PartState(index: 0, size: 100), PartState(index: 1, size: 100), PartState(index: 2, size: 100)]
        it.bytesTotal = 300
        XCTAssertEqual(it.schedulable(now: 0), [])
        for i in 0..<3 { it.parts[i].packaged = true }
        it.parts[2].nextAttempt = 50
        XCTAssertEqual(it.schedulable(now: 10), [0, 1])
        XCTAssertFalse(it.backgroundSafe)
        it.sessionID = "s-1"
        it.parts[0].taskID = 7; it.parts[0].sent = 40
        it.parts[1].taskID = 8
        it.parts[2].taskID = 9
        XCTAssertTrue(it.backgroundSafe)
        XCTAssertEqual(it.sentBytes, 40)
        XCTAssertEqual(it.dropStaleTasks(live: [7, 9]), [1])
        XCTAssertNil(it.parts[1].taskID)
        XCTAssertFalse(it.backgroundSafe)
        it.markHeld([0, 1])
        XCTAssertEqual(it.sentBytes, 200)
        XCTAssertFalse(it.serverHasAll)
        it.markHeld([2])
        XCTAssertTrue(it.serverHasAll)
        XCTAssertEqual(it.progress, 1)
    }

    func testProgressText() {
        let mb = 1_048_576
        XCTAssertEqual(UploadText.progressLine(sent: 110 * mb, total: 253 * mb, bytesPerSecond: Double(mb) * 0.8),
                       "Uploading 43 % · 110/253 MB · ~3 min")
        XCTAssertEqual(UploadText.progressLine(sent: 0, total: 0, bytesPerSecond: nil), "Uploading 0 % · 0/0 MB")
        XCTAssertEqual(UploadText.eta(seconds: 5), "<10 s")
        XCTAssertEqual(UploadText.eta(seconds: 44), "~40 s")
        XCTAssertEqual(UploadText.eta(seconds: 7200), "~2.0 h")
    }

    func testRateMeter() {
        var r = RateMeter()
        r.add(t: 0, bytes: 0)
        XCTAssertNil(r.bytesPerSecond)
        r.add(t: 0.5, bytes: 100)                // under 1 s: ignored
        XCTAssertNil(r.bytesPerSecond)
        r.add(t: 1, bytes: 1000)
        XCTAssertEqual(r.bytesPerSecond ?? 0, 1000, accuracy: 1e-9)
        r.add(t: 2, bytes: 3000)
        XCTAssertEqual(r.bytesPerSecond ?? 0, 1000 * 0.7 + 2000 * 0.3, accuracy: 1e-9)
    }
}
