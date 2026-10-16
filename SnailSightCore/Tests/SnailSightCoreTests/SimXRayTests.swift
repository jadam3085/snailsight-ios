import XCTest
@testable import SnailSightCore

/// 10.8: server sim paths over storeys, refusals with reasons, X-ray ghosts (API §5.9.11).
final class SimXRayTests: XCTestCase {
    private func snap(_ s: String) throws -> SimEntitySnap { try JSONDecoder().decode(SimEntitySnap.self, from: Data(s.utf8)) }

    func testNavDecodesFromSnapshotStringAndDocObject() throws {
        let s = try snap(#"{"id":"f","kind":"fox","pose":{"x":0,"y":0,"z":1.2},"level":1,"nav":"climbing"}"#)
        XCTAssertEqual(s.level, 1)
        XCTAssertEqual(s.nav?.status, "climbing")
        XCTAssertNil(s.nav?.reason)
        let d = try snap(#"""
        {"id":"f","kind":"fox","cat":"animal","pose":{"x":0,"y":0,"z":1.2},"level":0,
         "path":[[0,0,-1.3,0],[-2.7,-1.0,-1.1,-1],[-1.5,-2.3,1.1,-1],[0.2,2.8,3.9,2]],
         "nav":{"status":"climbing","target_level":2,"path_m":22.9,"levels":[0,1,2],"stairs":["stair-0-1-0"]}}
        """#)
        XCTAssertEqual(d.nav, SimNav(status: "climbing", reason: nil, targetLevel: 2, pathM: 22.9))
        XCTAssertEqual(d.path?.count, 4)
        XCTAssertEqual(d.path?[1][3], -1)
        // a 10 Hz snapshot keeps the doc's path + details while the status agrees, drops them when it changed
        let m = s.merged(withStatic: d)
        XCTAssertEqual(m.nav?.targetLevel, 2)
        XCTAssertEqual(m.path?.count, 4)
        XCTAssertEqual(m.level, 1)                       // the snapshot's storey wins
        let w = try snap(#"{"id":"f","kind":"fox","pose":{"x":0,"y":0},"nav":"with_you"}"#).merged(withStatic: d)
        XCTAssertEqual(w.nav, SimNav(status: "with_you"))
        XCTAssertEqual(w.nav?.text, "with you")
    }

    func testNavTextShowsTheReason() throws {
        let d = try snap(#"{"id":"r","kind":"robot","pose":{"x":0,"y":0},"nav":{"status":"no_path","reason":"no path: the stairs to level 2 have 21-24 cm risers, RobosnailBob climbs at most 4 cm"}}"#)
        XCTAssertTrue(d.nav!.text.contains("climbs at most 4 cm"))
        XCTAssertTrue(d.nav!.isProblem)
        XCTAssertEqual(SimNav(status: "walking", targetLevel: 2).text, "walking to level 2")
        XCTAssertFalse(SimNav(status: "walking").isProblem)
    }

    func testRefusedAckCarriesTheReason() {
        let m = SimStreamMessage.parse(Data(#"{"type":"ack","ref":"c4","ok":false,"status":422,"detail":"no path","reason":"no path: the target is walled off (no walkable route on this level)","id":"deer-1"}"#.utf8))
        XCTAssertEqual(m, .ack(ref: "c4", ok: false, status: 422,
                               detail: "no path: the target is walled off (no walkable route on this level)"))
        // older servers: detail only (text or an object)
        XCTAssertEqual(SimStreamMessage.parse(Data(#"{"type":"ack","ref":"c5","ok":false,"status":422,"detail":"bad"}"#.utf8)),
                       .ack(ref: "c5", ok: false, status: 422, detail: "bad"))
    }

    func testGhostAndBadge() {
        let cam = 3.93 + 1.35                            // phone upstairs (floor 3.93)
        // a body upstairs next to the phone, nothing in between: normal, no badge
        XCTAssertFalse(SimXRay.ghost(enabled: true, occluded: false, bodyZ: 3.95, cameraZ: cam))
        XCTAssertNil(SimXRay.badge(enabled: true, occluded: false, bodyZ: 3.95, bodyLevel: 2, cameraZ: cam, distance: 2))
        // behind a wall on the same storey: ghost + distance
        XCTAssertTrue(SimXRay.ghost(enabled: true, occluded: true, bodyZ: 3.95, cameraZ: cam))
        XCTAssertEqual(SimXRay.badge(enabled: true, occluded: true, bodyZ: 3.95, bodyLevel: 2, cameraZ: cam, distance: 4.3),
                       "4.5 m")
        // in the basement: always a ghost (another storey) with level + arrow
        XCTAssertTrue(SimXRay.ghost(enabled: true, occluded: false, bodyZ: -1.3, cameraZ: cam))
        XCTAssertEqual(SimXRay.badge(enabled: true, occluded: false, bodyZ: -1.3, bodyLevel: 0, cameraZ: cam, distance: 6.2),
                       "↓ L0 · 6 m")
        XCTAssertEqual(SimXRay.badge(enabled: true, occluded: false, bodyZ: 6.6, bodyLevel: nil, cameraZ: cam, distance: 12.2),
                       "↑ upstairs · 12 m")
        // X-ray off: never a ghost, never a badge
        XCTAssertFalse(SimXRay.ghost(enabled: false, occluded: true, bodyZ: -1.3, cameraZ: cam))
        XCTAssertNil(SimXRay.badge(enabled: false, occluded: true, bodyZ: -1.3, bodyLevel: 0, cameraZ: cam, distance: 6))
        // a body on a 40 cm step is still "this storey"
        XCTAssertFalse(SimXRay.otherStorey(bodyZ: 4.33, cameraZ: cam))
    }

    func testPathPreviewTrimsWhatIsBehind() {
        let path: [[Double]] = [[0, 0, 0, 0], [2, 0, 0, 0], [2, 2, 0.2, -1], [2, 4, 2.6, 1]]
        let r = SimPathPreview.remaining(path, from: [1.0, 0.1, 0])!
        XCTAssertEqual(r.first!, [1.0, 0.1, 0])
        XCTAssertEqual(r.count, 4)                       // body, then (2,0), (2,2), (2,4)
        XCTAssertEqual(r[1], [2, 0, 0])
        let near = SimPathPreview.remaining(path, from: [2.05, 3.0, 1.4])!
        XCTAssertEqual(near.count, 2)                    // on the stair: only the top is left
        XCTAssertNil(SimPathPreview.remaining(path, from: [2, 4, 2.6]))     // arrived
        XCTAssertNil(SimPathPreview.remaining([[0, 0, 0]], from: [0, 0, 0]))
        XCTAssertEqual(SimPathPreview.length([[0, 0, 0], [3, 4, 0], [3, 4, 2]]), 7, accuracy: 1e-9)
    }

    func testRibbonMesh() {
        let m = SimPathPreview.ribbon([[0, 0, 0], [1, 0, 0], [1, 1, 0.5]], width: 0.1, lift: 0.02)
        XCTAssertEqual(m.positions.count, 3 * 4 * 3)    // 2 segments + 1 joint, 4 vertices each
        XCTAssertEqual(m.indices.count, 3 * 12)
        XCTAssertEqual(Double(m.positions[2]), 0.02, accuracy: 1e-6)      // lifted
        XCTAssertEqual(Double(m.positions[1]), 0.05, accuracy: 1e-6)      // half width to the left of +x
        XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.positions.count / 3 })
        XCTAssertTrue(SimPathPreview.ribbon([[0, 0, 0]]).positions.isEmpty)
    }
}
