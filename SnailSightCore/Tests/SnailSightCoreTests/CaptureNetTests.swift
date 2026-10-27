import XCTest
@testable import SnailSightCore

final class AgentIDTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(AgentID.make(random: 0x1a2b3c4d), "phone-1a2b3c4d")
        XCTAssertEqual(AgentID.make(random: 1), "phone-00000001")
        XCTAssertTrue(AgentID.isValid(AgentID.make()))
    }

    func testValidation() {
        XCTAssertFalse(AgentID.isValid("ab"))
        XCTAssertFalse(AgentID.isValid("phone 1"))
        XCTAssertFalse(AgentID.isValid("phone/1"))
        XCTAssertFalse(AgentID.isValid(String(repeating: "a", count: 65)))
        XCTAssertTrue(AgentID.isValid("rover_01-x"))
        XCTAssertTrue(AgentID.isValidName("session-20261012-140501.jsonl"))
        XCTAssertFalse(AgentID.isValidName("../etc"))
        XCTAssertFalse(AgentID.isValidName(""))
    }
}

final class ServerConfigTests: XCTestCase {
    func testNormalise() {
        XCTAssertEqual(ServerConfig.normalise(" 10.0.0.5:8904/ "), "http://10.0.0.5:8904")
        XCTAssertEqual(ServerConfig.normalise("http://h:1//"), "http://h:1")
        XCTAssertNil(ServerConfig.normalise(""))
        XCTAssertNil(ServerConfig.normalise(nil))
    }

    // Example defaults (the real ones are injected into Info.plist at build/sign time, never in source).
    let T = "http://100.64.0.1:8904", L = "http://192.168.1.10:8904"

    func testOrderDefault() {
        let c = ServerConfig.candidates(override: nil, lastGood: nil, tailnet: T, lan: L)
        XCTAssertEqual(c.map(\.label), ["tailnet", "lan"])
        XCTAssertEqual(c.first?.base, T)
    }

    func testNoCompiledInDefaults() {
        // Without Info.plist values there is no default server: only an override / last good one is probed.
        XCTAssertEqual(ServerConfig.candidates(override: nil, lastGood: nil, tailnet: "", lan: "").count, 0)
        XCTAssertEqual(ServerConfig.candidates(override: "10.1.1.1:9", lastGood: nil, tailnet: "", lan: "").map(\.label),
                       ["override"])
    }

    func testOrderWithOverrideAndLastGood() {
        let c = ServerConfig.candidates(override: "10.1.1.1:9", lastGood: L, tailnet: T, lan: L)
        XCTAssertEqual(c.map(\.label), ["override", "lan", "tailnet"])
        XCTAssertEqual(c.map(\.base), ["http://10.1.1.1:9", L, T])
    }

    func testNoDuplicates() {
        let c = ServerConfig.candidates(override: T, lastGood: T, tailnet: T, lan: L)
        XCTAssertEqual(c.map(\.base), [T, L])
        XCTAssertEqual(c.first?.label, "override")
    }
}

final class ChunkPlannerTests: XCTestCase {
    func testPlan() {
        let p = ChunkPlanner.plan(received: 0, total: 10, chunk: 4)
        XCTAssertEqual(p.map(\.offset), [0, 4, 8])
        XCTAssertEqual(p.map(\.length), [4, 4, 2])
        XCTAssertNil(ChunkPlanner.next(received: 10, total: 10, chunk: 4))
        XCTAssertNil(ChunkPlanner.next(received: 0, total: 0))
        let r = ChunkPlanner.next(received: 5, total: 10, chunk: 4)!
        XCTAssertEqual(r.offset, 5); XCTAssertEqual(r.length, 4)
    }
}

final class LogUploadStateTests: XCTestCase {
    func testAppendFlow() {
        var s = LogUploadState()
        XCTAssertEqual(s.action(name: "a", localSize: 100), .send(offset: 0, length: 100))
        s.accepted(name: "a", size: 100)
        XCTAssertEqual(s.action(name: "a", localSize: 100), .upToDate)
        XCTAssertEqual(s.action(name: "a", localSize: 150), .send(offset: 100, length: 50))
        XCTAssertEqual(s.action(name: "a", localSize: 150, maxChunk: 20), .send(offset: 100, length: 20))
    }

    func testConflictResumesFromServer() {
        var s = LogUploadState(uploaded: ["a": 10])
        s.conflict(name: "a", serverSize: 60, localSize: 100)
        XCTAssertEqual(s.action(name: "a", localSize: 100), .send(offset: 60, length: 40))
        s.conflict(name: "a", serverSize: 500, localSize: 100)     // server has more: replace from 0
        XCTAssertEqual(s.action(name: "a", localSize: 100), .send(offset: 0, length: 100))
    }

    func testShrunkFileRestarts() {
        let s = LogUploadState(uploaded: ["a": 200])
        XCTAssertEqual(s.action(name: "a", localSize: 50), .send(offset: 0, length: 50))
    }

    func testPruneAndCodable() throws {
        var s = LogUploadState(uploaded: ["a": 1, "b": 2])
        s.prune(keeping: ["b"])
        XCTAssertEqual(s.uploaded, ["b": 2])
        let back = try JSONDecoder().decode(LogUploadState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}

final class CaptureNamingTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(CaptureNaming.clientSessionID(start: Date(timeIntervalSince1970: 0)), "cap-19700101-000000")
        XCTAssertEqual(CaptureNaming.frameStem(42), "000042")
    }

    func testPruneKeepsNewestAndUnuploaded() {
        let ids = ["cap-1", "cap-2", "cap-3", "cap-4", "cap-5"]
        XCTAssertEqual(CaptureNaming.toPrune(ids, serverHas: ["cap-1", "cap-3", "cap-5"], keep: 3), ["cap-1"])
        XCTAssertEqual(CaptureNaming.toPrune(ids, serverHas: [], keep: 0), [])
    }

    func testBackoff() {
        XCTAssertEqual(Backoff.delay(attempt: 0), 2)
        XCTAssertEqual(Backoff.delay(attempt: 3), 16)
        XCTAssertEqual(Backoff.delay(attempt: 20), 60)
    }
}

final class CaptureFormatTests: XCTestCase {
    func assertQuat(_ q: CaptureFormat.Quat, _ x: Double, _ y: Double, _ z: Double, _ w: Double,
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(q.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(q.y, y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(q.z, z, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(q.w, w, accuracy: 1e-9, file: file, line: line)
    }

    func testQuaternionKnownRotations() {
        assertQuat(CaptureFormat.quaternion(rows: [[1, 0, 0], [0, 1, 0], [0, 0, 1]]), 0, 0, 0, 1)
        let h = 0.5.squareRoot()
        // +90° about Z: x→y
        assertQuat(CaptureFormat.quaternion(rows: [[0, -1, 0], [1, 0, 0], [0, 0, 1]]), 0, 0, h, h)
        // +90° about X: y→z
        assertQuat(CaptureFormat.quaternion(rows: [[1, 0, 0], [0, 0, -1], [0, 1, 0]]), h, 0, 0, h)
        // 180° about Y (trace -1 branch)
        assertQuat(CaptureFormat.quaternion(rows: [[-1, 0, 0], [0, 1, 0], [0, 0, -1]]), 0, 1, 0, 0)
        // 180° about X and Z
        assertQuat(CaptureFormat.quaternion(rows: [[1, 0, 0], [0, -1, 0], [0, 0, -1]]), 1, 0, 0, 0)
        assertQuat(CaptureFormat.quaternion(rows: [[-1, 0, 0], [0, -1, 0], [0, 0, 1]]), 0, 0, 1, 0)
    }

    func testQuaternionArbitraryRoundTrip() {
        // 30° about the normalised (1,2,3) axis, Rodrigues → matrix → quaternion
        let a = [1.0, 2, 3]; let n = (a[0]*a[0] + a[1]*a[1] + a[2]*a[2]).squareRoot()
        let (x, y, z) = (a[0]/n, a[1]/n, a[2]/n); let t = Double.pi / 6
        let c = cos(t), s = sin(t), C = 1 - c
        let r = [[c + x*x*C, x*y*C - z*s, x*z*C + y*s],
                 [y*x*C + z*s, c + y*y*C, y*z*C - x*s],
                 [z*x*C - y*s, z*y*C + x*s, c + z*z*C]]
        assertQuat(CaptureFormat.quaternion(rows: r), x * sin(t/2), y * sin(t/2), z * sin(t/2), cos(t/2))
    }

    func testOdometryLine() {
        let l = CaptureFormat.odometryLine(timestamp: 12.5, frame: 3, position: [1, 2, -3],
                                           rotationRows: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        XCTAssertEqual(l, "12.500000, 3, 1.000000, 2.000000, -3.000000, 0.00000000, 0.00000000, 0.00000000, 1.00000000\n")
        XCTAssertEqual(CaptureFormat.odometryHeader.split(separator: ",").count, 9)
        XCTAssertEqual(l.split(separator: ",").count, 9)
    }

    func testIMUAndCameraMatrix() {
        let l = CaptureFormat.imuLine(timestamp: 1, accelG: [0, -1, 0], gyro: [0.1, 0, 0])
        XCTAssertEqual(l, "1.000000, 0.000000, -9.806650, 0.000000, 0.100000, 0.000000, 0.000000\n")
        let k = CaptureFormat.cameraMatrix(fx: 1400, fy: 1401, cx: 960, cy: 720)
        let rows = k.split(separator: "\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], "1400.000000,0.000000,960.000000")
        XCTAssertEqual(rows[1], "0.000000,1401.000000,720.000000")
        XCTAssertEqual(rows[2].split(separator: ",").count, 3)
    }

    func testDepthMillimetres() {
        XCTAssertEqual(CaptureFormat.depthMillimetres([1.2344, 0, -1, .nan, .infinity, 70, 0.0004, 0.0006]),
                       [1234, 0, 0, 0, 0, 65535, 0, 1])
    }

    func testRateControl() {
        XCTAssertTrue(CaptureFormat.shouldSave(now: 0, last: nil, rateHz: 10))
        XCTAssertFalse(CaptureFormat.shouldSave(now: 0.05, last: 0, rateHz: 10))
        XCTAssertTrue(CaptureFormat.shouldSave(now: 6.0 / 60.0, last: 0, rateHz: 10))
        XCTAssertFalse(CaptureFormat.shouldSave(now: 1, last: 0, rateHz: 0))
    }
}

final class NetFailureTests: XCTestCase {
    func testTimeoutDoesNotMarkOffline() {
        XCTAssertFalse(NetFailure.marksOffline(code: -1001))                        // .timedOut: re-probe instead
        XCTAssertTrue(NetFailure.wantsProbe(code: -1001))
    }

    func testConnectionFailuresMarkOffline() {
        for c in [-1003, -1004, -1005, -1006, -1009, -1200] {                        // host / connect / lost / dns / no net / tls
            XCTAssertTrue(NetFailure.marksOffline(code: c), "\(c)")
            XCTAssertFalse(NetFailure.wantsProbe(code: c))
        }
    }

    func testOtherErrorsOnlyReprobe() {
        for c in [-1011, -1017, -1103] {                                            // bad response / parse / too big
            XCTAssertFalse(NetFailure.marksOffline(code: c))
            XCTAssertTrue(NetFailure.wantsProbe(code: c))
        }
        XCTAssertFalse(NetFailure.marksOffline(code: -999))                         // cancelled: ours, no verdict
        XCTAssertFalse(NetFailure.wantsProbe(code: -999))
    }

    func testProbeRateLimit() {
        XCTAssertTrue(NetFailure.probeDue(now: 100, last: nil))
        XCTAssertFalse(NetFailure.probeDue(now: 105, last: 100))
        XCTAssertTrue(NetFailure.probeDue(now: 110, last: 100))
    }
}
