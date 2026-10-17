import XCTest
@testable import SnailSightCore

/// 11.3 Room scan (RoomPlan → structure layer S4): ids, the normalized room JSON, simd column order, map alignment
/// maths and the upload body / retry rules. The server side of the same fixtures: snailCOP tests/test_snailsight_roomplan.py.
final class RoomScanTests: XCTestCase {
    /// [Rz(yaw) | t] · Rx(+90°): ARKit +y (up) → map +z (ARMapAlign's convention), row-major.
    private func tMapArkit(yawDeg: Double, t: [Double]) -> [Double] {
        let a = yawDeg * .pi / 180, c = cos(a), s = sin(a)
        let rz = Mat4([c, -s, 0, t[0], s, c, 0, t[1], 0, 0, 1, t[2], 0, 0, 0, 1])
        let rx = Mat4([1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1])
        return (rz * rx).m
    }

    /// A wall surface in ARKit: centre (x, y, z), width along ARKit +x, y up.
    private func wallT(_ x: Double, _ y: Double, _ z: Double) -> [Double] {
        [1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1]
    }

    func testIds() {
        let id = RoomScanID.make(date: Date(timeIntervalSince1970: 1_792_000_000), random: 0xABCDEF12)
        XCTAssertEqual(id, "rp-20261014-174640-cdef12")
        XCTAssertTrue(RoomScanID.isValid(id))
        XCTAssertFalse(RoomScanID.isValid("mm-20261014-174640-cdef12"))
        XCTAssertFalse(RoomScanID.isValid("rp-a b"))
    }

    func testColumnMajorToRowMajor() {
        // simd columns: c0 = (1,0,0,0) c1 = (0,1,0,0) c2 = (0,0,1,0) c3 = (5,6,7,1) -> translation in the last column
        let cm: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 6, 7, 1]
        let rm = RoomScanMath.rowMajor(columnMajor: cm)
        XCTAssertEqual(rm, [1, 0, 0, 5, 0, 1, 0, 6, 0, 0, 1, 7, 0, 0, 0, 1])
    }

    func testMapAlignmentOfASurface() {
        let T = tMapArkit(yawDeg: 90, t: [10, 20, 1])
        // ARKit (1, 1.2, -2): Rx(+90) -> (1, 2, 1.2); Rz(90) -> (-2, 1, 1.2); + t -> (8, 21, 2.2)
        let c = RoomScanMath.mapCentre(T_map_arkit: T, surfaceT: wallT(1, 1.2, -2))
        XCTAssertEqual(c[0], 8, accuracy: 1e-9)
        XCTAssertEqual(c[1], 21, accuracy: 1e-9)
        XCTAssertEqual(c[2], 2.2, accuracy: 1e-9)
        XCTAssertTrue(RoomScanMath.isVerticalInMap(T_map_arkit: T, surfaceT: wallT(0, 0, 0)))
        // a surface lying flat in ARKit (its y axis along ARKit z) is not a wall in the map
        let flat: [Double] = [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1]
        XCTAssertFalse(RoomScanMath.isVerticalInMap(T_map_arkit: T, surfaceT: flat))
    }

    private func room() -> RoomScanRoom {
        RoomScanRoom(surfaces: [
            RoomSurface(id: "W0", kind: .wall, confidence: .high, dimensions: [4, 2.5, 0], T: wallT(0, 1.25, -1.5)),
            RoomSurface(id: "W1", kind: .wall, confidence: .medium, dimensions: [3, 2.5, 0], T: wallT(2, 1.25, 0)),
            RoomSurface(id: "D0", kind: .door, confidence: .high, dimensions: [0.85, 2.05, 0], T: wallT(0.3, 1.02, -1.5),
                        parent: "W0", open: true),
            RoomSurface(id: "F0", kind: .floor, confidence: .high, dimensions: [4, 3, 0], T: wallT(0, 0, 0),
                        polygon: [[-2, -1.5, 0], [2, -1.5, 0], [2, 1.5, 0], [-2, 1.5, 0]]),
        ], objects: [RoomObject(id: "O1", category: "bed", confidence: .high, dimensions: [1.6, 0.5, 2], T: wallT(0, 0.25, 0))],
        story: 0)
    }

    func testRoomJSONAndSummary() throws {
        let r = room()
        XCTAssertEqual(r.summary, "2 walls · 1 door · 1 object")
        let j = r.json()
        XCTAssertEqual(j["format"] as? String, "snailsight-roomplan/1")
        let s = try XCTUnwrap(j["surfaces"] as? [[String: Any]])
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s[2]["parent"] as? String, "W0")
        XCTAssertEqual(s[2]["open"] as? Bool, true)
        XCTAssertNil(s[0]["polygon"])
        XCTAssertEqual((s[3]["polygon"] as? [[Double]])?.count, 4)
        XCTAssertEqual((j["objects"] as? [[String: Any]])?.first?["category"] as? String, "bed")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(j))
    }

    func testUploadBody() throws {
        let al = MapAlignment(mapID: "site", version: 14, T: Mat4(tMapArkit(yawDeg: 30, t: [1, 2, 3])), at: 1000,
                              spreadCm: 0.8, method: "visual+mesh")
        XCTAssertNil(RoomScanUpload.body(id: "rp-x0001", room: room(), appleJSON: nil, align: nil, errCm: nil,
                                         agentID: "phone-1", appVersion: "11.3", capturedAt: 1, usdz: nil))
        let apple = Data(#"{"walls":[],"version":2}"#.utf8)
        let big = Data(count: RoomScanUpload.usdzMaxBytes + 1)
        let d = try XCTUnwrap(RoomScanUpload.body(id: "rp-x0001", room: room(), appleJSON: apple, align: al, errCm: 1.5,
                                                  agentID: "phone-1", appVersion: "11.3", capturedAt: 1, usdz: big))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(o["id"] as? String, "rp-x0001")
        XCTAssertEqual((o["T_map_arkit"] as? [Double])?.count, 16)
        XCTAssertEqual((o["align"] as? [String: Any])?["err_cm"] as? Double, 1.5)
        XCTAssertEqual((o["captured_room"] as? [String: Any])?["version"] as? Int, 2)
        XCTAssertNil(o["usdz_b64"])                                  // too big: stays on the phone
        let small = try XCTUnwrap(RoomScanUpload.body(id: "rp-x0001", room: room(), appleJSON: nil, align: al, errCm: nil,
                                                      agentID: "p", appVersion: "11.3", capturedAt: 1, usdz: Data([1, 2, 3])))
        let o2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: small) as? [String: Any])
        XCTAssertEqual(o2["usdz_b64"] as? String, "AQID")
    }

    func testOutcome() {
        XCTAssertEqual(RoomScanUpload.outcome(status: 200), .sent)
        XCTAssertEqual(RoomScanUpload.outcome(status: 202), .sent)
        XCTAssertEqual(RoomScanUpload.outcome(status: 422), .drop)
        XCTAssertEqual(RoomScanUpload.outcome(status: 429), .retry)
        XCTAssertEqual(RoomScanUpload.outcome(status: 503), .retry)
        XCTAssertEqual(RoomScanUpload.outcome(status: nil), .retry)
        XCTAssertEqual(RoomScanText.result("kept", changed: false), "Room scan checked: the map's walls were already better")
    }
}
