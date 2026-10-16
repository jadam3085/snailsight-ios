import XCTest
@testable import SnailSightCore

/// P2b: phone ↔ master-map frame maths (T_map_arkit from POST /v1/localize), sim entity poses in the map frame, the
/// keep / restore / migrate decision when a lock arrives, attempt cadence and the wire formats (API §5.6 / §5.7).
final class MapFrameTests: XCTestCase {
    /// Same vector as the server (services/snailsight/locmath.py): correction yaw 30°, t (1, −2, 0.3).
    let T30 = Mat4([0.866025404, 0, 0.5, 1, 0.5, 0, -0.866025404, -2, 0, 1, 0, 0.3, 0, 0, 0, 1])

    func close(_ a: [Double], _ b: [Double], _ tol: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: tol, file: file, line: line) }
    }

    func testMat4InverseMultiplyAndWire() throws {
        let I = T30 * T30.inverse
        close(I.m, Mat4.identity.m)
        let twelve = try JSONDecoder().decode(Mat4.self, from: Data("[1,0,0,1,0,1,0,2,0,0,1,3]".utf8))
        XCTAssertEqual(twelve.translation, [1, 2, 3])
        XCTAssertThrowsError(try JSONDecoder().decode(Mat4.self, from: Data("[1,2,3]".utf8)))
        let col = T30.columnsMajor
        XCTAssertEqual(Double(col[12]), 1, accuracy: 1e-6)             // column 3 = translation
        close(Mat4(columnsMajor: col).m, T30.m, 1e-6)
    }

    func testAlignmentMatchesTheServerConvention() {
        let a = MapAlignment(mapID: "site", version: 7, T: T30, at: 0)
        close(a.toMap(arkit: [0.3, 1.2, -4.0]), [-0.74019238, 1.61410162, 1.5])     // locmath.arkit_to_map_point
        close(a.toArkit(map: a.toMap(arkit: [0.3, 1.2, -4.0])), [0.3, 1.2, -4.0])
        XCTAssertEqual(a.yaw * 180 / .pi, 30, accuracy: 1e-6)
        XCTAssertEqual(a.tiltDeg, 0, accuracy: 1e-6)
    }

    func testEntityPoseRoundTripAndHeading() {
        let a = MapAlignment(mapID: "site", version: 7, T: T30, at: 0)
        let pose = a.mapPose(arkit: [1.76, -0.82, 0.15], groundYaw: 0.4)
        XCTAssertEqual(pose.yaw, 0.4 + .pi / 6, accuracy: 1e-9)
        XCTAssertEqual(pose.z, -0.82 + 0.3, accuracy: 1e-9)                // ARKit up = map up
        let back = a.arkit(pose)
        close(back.position, [1.76, -0.82, 0.15])
        XCTAssertEqual(back.groundYaw, 0.4, accuracy: 1e-9)
        // a sim ground heading of 0 points along ARKit +x = odom +x: in the map it must point along the correction yaw
        let p0 = a.toMap(arkit: [0, 0, 0]), p1 = a.toMap(arkit: [1, 0, 0])
        XCTAssertEqual(atan2(p1[1] - p0[1], p1[0] - p0[0]), a.mapPose(arkit: [0, 0, 0], groundYaw: 0).yaw, accuracy: 1e-9)
        // ground heading +90° = ARKit −z: also in the map
        let p2 = a.toMap(arkit: [0, 0, -1])
        XCTAssertEqual(atan2(p2[1] - p0[1], p2[0] - p0[0]), a.mapPose(arkit: [0, 0, 0], groundYaw: .pi / 2).yaw, accuracy: 1e-9)
    }

    func testDeltaBetweenAlignments() {
        let a = MapAlignment(mapID: "site", version: 7, T: T30, at: 0)
        var m = T30.m
        m[3] += 0.03
        let b = MapAlignment(mapID: "site", version: 7, T: Mat4(m), at: 0)
        let d = a.delta(b)
        XCTAssertEqual(d.cm, 3, accuracy: 1e-6)
        XCTAssertEqual(d.deg, 0, accuracy: 1e-4)
    }

    func testRestorePlan() {
        let here: [String: [Double]] = ["deer": [1, 0, 0], "rabbit": [0, 0, -2.6]]
        XCTAssertEqual(MapRestorePlan.decide(current: [:], map: [:]), .keep(maxCm: 0))
        XCTAssertEqual(MapRestorePlan.decide(current: here, map: [:]), .migrate)
        XCTAssertEqual(MapRestorePlan.decide(current: [:], map: here), .restore(reason: "no_bodies"))
        XCTAssertEqual(MapRestorePlan.decide(current: here, map: ["deer": [1, 0, 0]]), .restore(reason: "different_set"))
        guard case .keep(let cm) = MapRestorePlan.decide(current: here, map: ["deer": [1.05, 0, 0], "rabbit": [0, 0, -2.6]])
        else { return XCTFail("5 cm apart must keep the bodies") }
        XCTAssertEqual(cm, 5, accuracy: 1e-6)
        XCTAssertEqual(MapRestorePlan.decide(current: here, map: ["deer": [1.4, 0, 0], "rabbit": [0, 0, -2.6]]),
                       .restore(reason: "moved 40 cm"))
    }

    func testCadence() {
        XCTAssertEqual(LocalizeCadence.interval(locked: false, refinements: 0, thermalSerious: false), 1.0)
        XCTAssertEqual(LocalizeCadence.interval(locked: false, refinements: 0, thermalSerious: true), 3.0)
        XCTAssertEqual(LocalizeCadence.interval(locked: true, refinements: 2, thermalSerious: false), 8.0)
        XCTAssertNil(LocalizeCadence.interval(locked: true, refinements: 12, thermalSerious: false))
        XCTAssertNil(LocalizeCadence.interval(locked: true, refinements: 0, thermalSerious: true))
    }

    func testLocalizeAnswerDecodesTheServerReply() throws {
        let json = """
        {"ok":true,"map_id":"site","map_version":7,"frame":"map/site@v7","stream":"phone-1/ar-1","locked":true,
         "events":["locked"],"gate":{"locked":true,"fixes":2,"cluster":2,"relocks":0,"rejected":{"inliers":0},
         "attempts":2,"T_map_arkit":[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1],"spread_cm":0.8,"inliers":[233,134]},
         "frames":[{"node":10535,"inliers":233,"matches":300,"hyp":0.4,"map_session":8,"ms":133.0,"frame":"export",
                    "t":12.0,"accepted":true,"reason":"","tilt_deg":0.1,"event":"locked","session_id":"s-x",
                    "T_map_arkit_raw":[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1]}],
         "latency_ms":181.6,"localizer":{"version":"0.4.3","nodes":5190},
         "T_map_arkit":[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1],"T_arkit_map":[1,0,0,0,0,0,1,0,0,-1,0,0,0,0,0,1],
         "time_to_lock_s":1.21,"matched_session":"s-20261014-013507-4454cd"}
        """
        let a = try JSONDecoder().decode(LocalizeAnswer.self, from: Data(json.utf8))
        XCTAssertTrue(a.locked)
        XCTAssertEqual(a.mapVersion, 7)
        XCTAssertEqual(a.timeToLockS, 1.21)
        XCTAssertEqual(a.bestInliers, 233)
        XCTAssertEqual(a.gate?.spreadCm, 0.8)
        XCTAssertTrue(a.anyMatch)
        let al = MapAlignment(mapID: a.mapID, version: a.mapVersion, T: a.T_map_arkit!, at: 0)
        XCTAssertEqual(al.tiltDeg, 0, accuracy: 1e-9)                          // identity correction (X only)
        let searching = """
        {"ok":true,"map_id":"site","map_version":7,"locked":false,"events":[],"frames":[{"node":0,"inliers":0}]}
        """
        let s = try JSONDecoder().decode(LocalizeAnswer.self, from: Data(searching.utf8))
        XCTAssertFalse(s.locked)
        XCTAssertNil(s.T_map_arkit)
        XCTAssertFalse(s.anyMatch)
        XCTAssertNil(s.shownMethod)
    }

    func testMeshLockWording() throws {
        let json = """
        {"ok":true,"map_id":"site","map_version":10,"locked":true,"events":["refined"],"method":"mesh",
         "lock_method":"visual+mesh","frames":[{"node":0,"inliers":0,"accepted":false,"reason":"no_match"}],
         "T_map_arkit":[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1]}
        """
        let a = try JSONDecoder().decode(LocalizeAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(a.shownMethod, "visual+mesh")
        let al = MapAlignment(mapID: a.mapID, version: a.mapVersion, T: a.T_map_arkit!, at: 0, method: a.shownMethod)
        XCTAssertTrue(al.meshAligned)
        XCTAssertEqual(MapLocText.locked(mapID: "site", version: 10, seconds: 1.8, method: al.method),
                       "LOCALIZED · geometry+visual · whole house v10 · 1.8 s")
        // 10.4: lock_source (geometry | visual | both) wins; hint + geometry search state decode
        let g = """
        {"ok":true,"map_id":"site","map_version":12,"locked":false,"events":[],"method":"none","lock_method":null,
         "lock_source":null,"hint":{"code":"degenerate","text":"Turn to see a corner of the room"},
         "geometry":{"state":"searching","last":{"ok":true,"reason":"","ambiguity":0.55}},
         "frames":[{"node":0,"inliers":0,"accepted":false,"reason":"no_match"}]}
        """
        let ga = try JSONDecoder().decode(LocalizeAnswer.self, from: Data(g.utf8))
        XCTAssertEqual(ga.hint?.code, "degenerate")
        XCTAssertTrue(ga.geometryCandidate)
        XCTAssertNil(ga.shownMethod)
        let gl = """
        {"ok":true,"map_id":"site","map_version":12,"locked":true,"events":["locked"],"method":"mesh-global",
         "lock_method":"mesh-global","lock_source":"geometry","frames":[{"node":0,"inliers":0}],
         "T_map_arkit":[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1]}
        """
        let la = try JSONDecoder().decode(LocalizeAnswer.self, from: Data(gl.utf8))
        XCTAssertEqual(la.shownMethod, "geometry")
        XCTAssertEqual(MapLocText.locked(mapID: "site", version: 12, seconds: 6.2, method: la.shownMethod),
                       "LOCALIZED · geometry · whole house v12 · 6.2 s")
        XCTAssertEqual(MapLocText.locked(mapID: "site", version: 10, seconds: nil, method: "visual"),
                       "LOCALIZED · whole house v10")
        // an alignment cached by an older app (no "method" key) still decodes
        let old = #"{"mapID":"site","version":7,"T":[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1],"at":0}"#
        XCTAssertNil(try JSONDecoder().decode(MapAlignment.self, from: Data(old.utf8)).method)
    }

    func testEntitiesWire() throws {
        let rec = SimEntityRecord(id: "A1", kind: "deer", behaviour: "pace", heading: 0.2, anchor: [1, 0, 0],
                                  paceLoop: [V2(0, 0), V2(1, 0)], room: "Area 1")
        let e = MapEntity.from(rec, pose: MapPose(x: 1, y: 2, z: -0.1, yaw: 0.5), mapVersion: 7, agentID: "phone-1",
                               placeID: "place-959c97e5")
        let put = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MapEntitiesPut([e], agentID: "phone-1",
                                                                                             reason: "migrate"))) as! [String: Any]
        let item = (put["entities"] as! [String: Any])["A1"] as! [String: Any]
        XCTAssertEqual(item["map_version"] as? Int, 7)
        XCTAssertEqual(item["place_id"] as? String, "place-959c97e5")
        XCTAssertEqual((item["pose"] as! [String: Any])["yaw"] as? Double, 0.5)
        XCTAssertEqual(put["agent_id"] as? String, "phone-1")
        // what GET returns (the record echoed back, plus server fields the app ignores)
        let recData = try JSONEncoder().encode(rec)
        let recJSON = String(data: recData, encoding: .utf8)!
        let doc = """
        {"map_id":"site","revision":3,"updated":1.0,"map_version":7,"frame":"map/site@v7","entities":[
          {"id":"A1","kind":"deer","pose":{"x":1,"y":2,"z":-0.1,"yaw":0.5},"map_version":6,
           "record":\(recJSON),
           "agent_id":"phone-1","place_id":null,"name":"Area 1","created":1,"updated":2,
           "carried":{"from_version":6,"via_session":"s-a"}},
          {"id":"B2","kind":"fox","pose":{"x":0,"y":0,"z":0,"yaw":0},"map_version":7}]}
        """
        let d = try JSONDecoder().decode(MapEntitiesDoc.self, from: Data(doc.utf8))
        XCTAssertEqual(d.revision, 3)
        XCTAssertEqual(d.entities.count, 2)
        XCTAssertEqual(d.entities[0].record?.paceLoop, [V2(0, 0), V2(1, 0)])
        let r2 = d.entities[1].restoreRecord(arkitAnchor: [3, 0, 1])
        XCTAssertEqual(r2.id, "B2")
        XCTAssertEqual(r2.kind, "fox")
        XCTAssertEqual(r2.behaviour, "roam")
        XCTAssertEqual(r2.anchor, [3, 0, 1])
    }

    func testHUDText() {
        XCTAssertEqual(MapLocText.locked(mapID: "site", version: 7, seconds: 1.84), "LOCALIZED · whole house v7 · 1.8 s")
        XCTAssertEqual(MapLocText.locked(mapID: "test", version: 2, seconds: nil), "LOCALIZED · test v2")
        XCTAssertEqual(MapLocText.searching(mapID: "site", seconds: 4.2, attempts: 3, matches: 1),
                       "Finding you in the whole house map · 4 s · 1 match")
        XCTAssertTrue(MapLocText.searching(mapID: "site", seconds: 9, attempts: 6, matches: 0).hasSuffix("detail"))
    }
}
