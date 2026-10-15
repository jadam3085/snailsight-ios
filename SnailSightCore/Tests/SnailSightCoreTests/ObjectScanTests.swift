import XCTest
import simd
@testable import SnailSightCore

final class ObjectScanTests: XCTestCase {
    func testNamingAndRouting() {
        let d = Date(timeIntervalSince1970: 1_791_900_000)
        let p = ObjectNaming.clientObjectID(mode: .photo, start: d)
        let l = ObjectNaming.clientObjectID(mode: .lidar, start: d)
        XCTAssertTrue(p.hasPrefix("obj-") && l.hasPrefix("objl-"))
        XCTAssertEqual(p.count, "obj-20261013-000000".count)
        XCTAssertEqual(ObjectNaming.mode(of: p), .photo)
        XCTAssertEqual(ObjectNaming.mode(of: l), .lidar)
        XCTAssertNil(ObjectNaming.mode(of: "cap-20261012-140501"))
        // room captures keep going to the house workflow; objects never do
        XCTAssertEqual(UploadRoute.target(for: "cap-20261012-140501"), "session")
        XCTAssertEqual(UploadRoute.target(for: l), "object")
        XCTAssertEqual(UploadRoute.createPath(target: "object"), "/v1/objects")
        XCTAssertEqual(UploadRoute.createPath(target: "session"), "/v1/sessions")
        XCTAssertEqual(UploadRoute.partPath(target: "object", serverID: "o-1", part: 3), "/v1/objects/o-1/parts/3")
        XCTAssertEqual(UploadRoute.statusPath(target: "session", serverID: "s-1"), "/v1/sessions/s-1")
        XCTAssertEqual(UploadRoute.idKey(target: "object"), "object_id")
        XCTAssertEqual(UploadRoute.objectLine(dims: [0.84, 0.61, 0.62]), "Object 0.84 × 0.62 × 0.61 m (w × d × h)")
        XCTAssertNil(UploadRoute.objectLine(dims: [1]))
        XCTAssertEqual(ObjectNaming.tags(["Robot", "robot", "q6 base", ""]), ["robot", "q6base"])
        // the room-capture scans in UploadQueue look for "cap-" only
        XCTAssertFalse(p.hasPrefix("cap-") || l.hasPrefix("cap-"))
    }

    func testPlaceOnFrontFacePushesBoxBehindHit() {
        // camera 1.5 m in front (+Z) of a hit on the object's vertical front face
        let b = ObjectBox.place(hit: SIMD3(0, 0.3, 0), normal: SIMD3(0, 0, 1), camera: SIMD3(0, 1.4, 1.5), floorY: 0)
        XCTAssertEqual(b.yawDeg, 0, accuracy: 1e-4)                 // +Z faces the camera
        XCTAssertEqual(b.center.z, -0.4, accuracy: 1e-5)            // pushed in by depth/2
        XCTAssertEqual(b.center.y, 0.4, accuracy: 1e-5)             // bottom on the floor
        XCTAssertTrue(b.contains(SIMD3(0, 0.3, -0.1)))
        XCTAssertFalse(b.contains(SIMD3(0, -0.01, -0.4)))           // below the floor
        // a hit on the top deck is the centre
        let t = ObjectBox.place(hit: SIMD3(0.2, 0.6, 0.1), normal: SIMD3(0, 1, 0), camera: SIMD3(1.2, 1.4, 0.1), floorY: 0)
        XCTAssertEqual(t.center.x, 0.2, accuracy: 1e-5)
        XCTAssertEqual(t.center.z, 0.1, accuracy: 1e-5)
        XCTAssertEqual(t.yawDeg, 90, accuracy: 1e-3)                // camera on +X
        XCTAssertEqual(simd_length(t.zAxis - SIMD3(1, 0, 0)), 0, accuracy: 1e-5)
    }

    func testCornersEdgesNudgeClampAndJSON() {
        var b = ObjectBox(center: SIMD3(1, 0.5, 2), size: SIMD3(0.8, 1.0, 0.6), yawDeg: 90, floorY: 0)
        let c = b.corners
        XCTAssertEqual(c.count, 8)
        XCTAssertEqual(ObjectBox.edges.count, 12)
        // yaw 90: width axis = world −Z, depth axis = world +X
        XCTAssertEqual(simd_length(c[0] - SIMD3(1 - 0.3, 0, 2 + 0.4)), 0, accuracy: 1e-5)
        XCTAssertEqual(c[4].y, 1.0, accuracy: 1e-6)
        let n = b.nudged(dx: 0.1, dz: 0)
        XCTAssertEqual(simd_length(n.center - SIMD3(1, 0.5, 1.9)), 0, accuracy: 1e-5)
        b.size = SIMD3(5, 0.01, 1)
        let k = b.clamped()
        XCTAssertEqual(k.size.x, ObjectBox.maxSide)
        XCTAssertEqual(k.size.y, ObjectBox.minSide)
        XCTAssertEqual(k.center.y, ObjectBox.minSide / 2, accuracy: 1e-6)
        let j = k.json
        XCTAssertEqual((j["size"] as? [Double])?.count, 3)
        XCTAssertEqual(j["floor_y"] as? Double, 0)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: j))
        XCTAssertEqual(ObjectBox(center: .zero, size: SIMD3(1, 0.8, 0.6), yawDeg: 0, floorY: 0).label, "1.00 × 0.60 × 0.80 m")
    }

    func testObjectProfileKeyframesAreDenser() {
        // a 0.15 m move 0.5 s after the last keyframe: a keyframe in the object profile, not in the room profile
        XCTAssertTrue(AdaptiveCapture.isKeyframe(translationM: 0.15, rotationDeg: 1, sinceLastS: 0.5, scale: ObjectProfile.keyframeScale))
        XCTAssertFalse(AdaptiveCapture.isKeyframe(translationM: 0.15, rotationDeg: 1, sinceLastS: 0.5, scale: 1))
        // the adaptive policy's "no keyframes" (scale 0) still wins
        XCTAssertFalse(AdaptiveCapture.isKeyframe(translationM: 1, rotationDeg: 90, sinceLastS: 9, scale: 0 * ObjectProfile.keyframeScale))
    }

    func testUploadItemTargetDecodesOldQueues() throws {
        let old = #"[{"clientSessionID":"cap-20261012-140501","frames":3,"captureBytes":10,"mode":"parts"}]"#
        let items = try JSONDecoder().decode([UploadItem].self, from: Data(old.utf8))
        XCTAssertEqual(items[0].target, "session")
        var it = UploadItem(clientSessionID: "objl-20261012-150000", frames: 1, captureBytes: 1)
        XCTAssertEqual(it.target, "object")
        it.state = "processed"
        let back = try JSONDecoder().decode(UploadItem.self, from: JSONEncoder().encode(it))
        XCTAssertEqual(back.target, "object")
    }
}
