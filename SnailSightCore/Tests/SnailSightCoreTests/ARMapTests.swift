import XCTest
@testable import SnailSightCore

final class ARMapTests: XCTestCase {
    private func close(_ a: [Double], _ b: [Double], _ tol: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: tol, file: file, line: line) }
    }

    // MARK: Align4

    func testAlign4MatchesMatrixAndMapAlignment() {
        let a = Align4(x: 1.5, y: -2, z: 0.3, yaw: 0.7)
        let p = [0.4, 1.2, -3.0]
        close(a.toMap(p), a.matrix.apply(p))
        close(a.toArkit(a.toMap(p)), p)
        close(a.inverseMatrix.apply(a.toMap(p)), p)
        // same convention as MapAlignment (P2b): yaw and the map pose of a point agree
        let m = MapAlignment(mapID: "site", version: 10, T: a.matrix, at: 0)
        XCTAssertEqual(m.yaw, 0.7, accuracy: 1e-12)
        XCTAssertEqual(m.tiltDeg, 0, accuracy: 1e-9)
        close(m.toMap(arkit: p), a.toMap(p))
        // round trip through a Mat4
        let b = Align4(a.matrix)
        XCTAssertEqual(b.x, a.x, accuracy: 1e-12); XCTAssertEqual(b.yaw, a.yaw, accuracy: 1e-12)
        // ARKit up is map up
        let up = a.toMap([0, 1, 0]), o = a.toMap([0, 0, 0])
        XCTAssertEqual(up[2] - o[2], 1, accuracy: 1e-12)
    }

    func testPivotedPutsPivotAtMapPoint() {
        let a = Align4.pivoted(yaw: -1.1, pivot: [2, 1.4, -1], at: [5, 6, 2.8])
        close(a.toMap([2, 1.4, -1]), [5, 6, 2.8], 1e-12)
        XCTAssertEqual(a.yaw, -1.1, accuracy: 1e-12)
    }

    // MARK: blender

    func testFirstLockSnapsThenSmallCorrectionBlendsWithoutJumps() {
        var b = AlignBlender()
        let a0 = Align4(x: 0, y: 0, z: 0, yaw: 0)
        b.setTarget(a0)
        XCTAssertTrue(b.step(dt: 1 / 60, pivot: [0, 1.4, 0]))
        XCTAssertTrue(b.snapped)
        XCTAssertEqual(b.shown, a0)
        // a 20 cm / 3° refinement: per-frame motion at the camera stays ≤ 0.5 m/s · dt, converges within ~3 s
        let a1 = Align4(x: 0.2, y: -0.05, z: 0.01, yaw: 3 * .pi / 180)
        b.setTarget(a1)
        let cam = [1.0, 1.4, -2.0]
        var prev = b.shown!.toMap(cam)
        var maxStep = 0.0
        var t = 0.0
        while !b.settled && t < 10 {
            b.step(dt: 1 / 60, pivot: cam)
            XCTAssertFalse(b.snapped)
            let now = b.shown!.toMap(cam)
            maxStep = max(maxStep, hypot(now[0] - prev[0], now[1] - prev[1]))
            prev = now
            t += 1 / 60
        }
        XCTAssertTrue(b.settled)
        XCTAssertLessThan(t, 3.5)
        XCTAssertLessThanOrEqual(maxStep, 0.5 / 60 + 1e-9)
        XCTAssertEqual(b.remaining(pivot: cam).cm, 0, accuracy: 1e-9)
    }

    func testPivotPointMovesLessThanFarPoints() {
        // a pure yaw correction about the camera barely moves the camera's map point
        var b = AlignBlender()
        let cam = [3.0, 1.4, -4.0]
        let a0 = Align4(x: 0, y: 0, z: 0, yaw: 0)
        b.setTarget(a0); b.step(dt: 0, pivot: cam)
        let target = Align4.pivoted(yaw: 0.05, pivot: cam, at: a0.toMap(cam))
        b.setTarget(target)
        let before = b.shown!.toMap(cam)
        b.step(dt: 0.1, pivot: cam)
        let after = b.shown!.toMap(cam)
        XCTAssertEqual(hypot(after[0] - before[0], after[1] - before[1]), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(abs(b.shown!.yaw), 0.001)
    }

    func testRelockFarAwaySnaps() {
        var b = AlignBlender()
        b.setTarget(Align4(x: 0, y: 0, z: 0, yaw: 0)); b.step(dt: 0, pivot: [0, 0, 0])
        b.setTarget(Align4(x: 3, y: 0, z: 0, yaw: 0))
        b.step(dt: 1 / 60, pivot: [0, 0, 0])
        XCTAssertTrue(b.snapped)
        XCTAssertTrue(b.settled)
        b.setTarget(nil)
        XCTAssertNil(b.shown)
    }

    // MARK: status

    func testStatusTexts() {
        var s = ARMapStatus.make(online: false, lock: .none, version: nil, tracking: "normal", remainingCm: 0)
        XCTAssertEqual(s.opacity, 0); XCTAssertEqual(s.tone, .warn)
        s = ARMapStatus.make(online: true, lock: .none, version: nil, tracking: "normal", remainingCm: 0, searchingS: 4, matches: 2)
        XCTAssertEqual(s.title, "FINDING YOU"); XCTAssertTrue(s.detail.contains("2 matches")); XCTAssertEqual(s.opacity, 0)
        s = ARMapStatus.make(online: true, lock: .server(method: "visual+mesh"), version: 10, tracking: "normal", remainingCm: 0.5)
        XCTAssertEqual(s.title, "1:1 · geometry+visual · whole house v10"); XCTAssertEqual(s.opacity, 1); XCTAssertEqual(s.tone, .good)
        s = ARMapStatus.make(online: true, lock: .server(method: "visual"), version: 10, tracking: "normal", remainingCm: 12)
        XCTAssertEqual(s.title, "CORRECTING 12 cm")
        s = ARMapStatus.make(online: true, lock: .server(method: nil), version: 10, tracking: "relocalizing", remainingCm: 0)
        XCTAssertEqual(s.opacity, 0)
        s = ARMapStatus.make(online: true, lock: .server(method: nil), version: 10, tracking: "excessiveMotion", remainingCm: 0)
        XCTAssertEqual(s.opacity, 0.3)
        s = ARMapStatus.make(online: true, lock: .cached, version: 9, tracking: "normal", remainingCm: 0)
        XCTAssertEqual(s.opacity, 0.6); XCTAssertTrue(s.title.contains("saved place"))
    }

    // MARK: mesh

    func testObjReaderParsesVerticesFacesSlashesNegativeAndPolygons() {
        let obj = """
        # comment
        v 0 0 0
        v 1 0 0 0.5 0.5 0.5
        v 1 1 0
        v 0 1 1.5e-1
        vn 0 0 1
        f 1 2 3
        f 1//1 3//1 4//1
        f -4 -3 -2 -1
        f 1 2 99
        """
        let m = ObjReader.parse(Data(obj.utf8))
        XCTAssertEqual(m.vertexCount, 4)
        XCTAssertEqual(m.positions[11], 0.15, accuracy: 1e-6)
        XCTAssertEqual(m.triangleCount, 4)                     // 1 + 1 + quad fanned to 2; the bad index face dropped
        XCTAssertEqual(Array(m.indices[0..<3]), [0, 1, 2])
        XCTAssertEqual(Array(m.indices[3..<6]), [0, 2, 3])
        XCTAssertEqual(Array(m.indices[6..<12]), [0, 1, 2, 0, 2, 3])
    }

    func testChunkerKeepsEveryTriangleAndNearestBudget() {
        // 3 x 1 strip of unit quads 5 m apart → 3 chunks at 4 m
        var m = FlatMesh()
        for k in 0..<3 {
            let x = Float(k) * 5, base = UInt32(m.vertexCount)
            m.positions += [x, 0, 0, x + 1, 0, 0, x + 1, 1, 0, x, 1, 0]
            m.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let ch = MeshChunker.split(m, cell: 4)
        XCTAssertEqual(ch.count, 3)
        XCTAssertEqual(ch.reduce(0) { $0 + $1.mesh.triangleCount }, 6)
        XCTAssertTrue(ch.allSatisfy { $0.mesh.vertexCount == 4 })
        let near = MeshChunker.nearest(ch, to: [10, 0.5], maxTriangles: 4)
        XCTAssertEqual(near.count, 2)
        XCTAssertEqual(ch.first { $0.key == near[0] }!.center[0], 10.5, accuracy: 1e-6)
    }

    func testLiftAlongNormals() {
        let m = FlatMesh(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0, 5, 5, 5], indices: [0, 1, 2])
        let l = m.liftedAlongNormals(0.005)
        XCTAssertEqual(l.positions[2], 0.005, accuracy: 1e-7)
        XCTAssertEqual(l.positions[8], 0.005, accuracy: 1e-7)
        XCTAssertEqual(l.positions[9], 5)                   // unused vertex unchanged
        XCTAssertEqual(l.indices, m.indices)
    }

    // MARK: rooms + objects

    func testRoomsAndObjectsDecodeAndFilter() throws {
        let rooms = #"{"scene":"site@10","revision":3,"rooms":[{"id":"r1","name":"Family room","polygon":[[0,0],[4,0],[4,3],[0,3]],"floor_z":-1.3,"height":2.4},{"id":"r2","name":"bad","polygon":[[0,0],[1,1]]}]}"#
        let rd = try JSONDecoder().decode(ARRoomsDoc.self, from: Data(rooms.utf8))
        let labels = ARMapContent.roomLabels(rd, defaultFloorZ: 0)
        XCTAssertEqual(labels.count, 1)
        close(labels[0].position, [2, 1.5, 0.3], 1e-9)
        let objs = #"{"revision":5,"objects":[{"id":"o-1","label":"lamp","category":"furniture","static":true,"centroid":[1,2,0.5],"box":{"center":[1,2,0.5],"size":[0.3,0.3,1.0],"yaw":0.2},"confidence":0.8,"state":"present","source":"yoloe"},{"id":"o-2","label":"cup","category":"movable","centroid":[0,0,0],"confidence":0.3,"state":"present","source":"yoloe"},{"id":"m-1","label":"keys","name":"Spare keys","category":"movable","centroid":[3,3,1],"confidence":1,"source":"manual"},{"id":"o-3","label":"box","centroid":[5,5,0],"confidence":0.9,"state":"missing"}]}"#
        let od = try JSONDecoder().decode(ARObjectsDoc.self, from: Data(objs.utf8))
        let vis = ARMapContent.visible(od)
        XCTAssertEqual(vis.map(\.id), ["o-1", "m-1"])
        let boxes = ARMapContent.boxes(vis)
        XCTAssertFalse(boxes[0].movable)
        XCTAssertTrue(boxes[1].movable)
        XCTAssertEqual(boxes[1].label, "Spare keys")
        XCTAssertEqual(boxes[1].size, [0.2, 0.2, 0.2])
        let ol = ARMapContent.objectLabels(boxes)
        XCTAssertEqual(ol[0].position[2], 1.08, accuracy: 1e-9)
    }

    func testPickNearestOrientedBox() {
        let a = ARBoxItem(id: "a", label: "a", center: [2, 0, 0.5], size: [1, 0.2, 1], yaw: .pi / 2, movable: false, confidence: 1)
        let b = ARBoxItem(id: "b", label: "b", center: [5, 0, 0.5], size: [1, 1, 1], yaw: 0, movable: false, confidence: 1)
        // along +x: the rotated box is thin along x (0.2 → picked as 0.25)
        let h = ARMapContent.pick(origin: [0, 0, 0.5], direction: [1, 0, 0], boxes: [b, a])
        XCTAssertEqual(h?.id, "a")
        XCTAssertEqual(h!.distance, 2 - 0.125, accuracy: 1e-9)
        // passing beside the rotated box: its long side is along y now (0.5 half), 0.6 off misses it
        let miss = ARMapContent.pick(origin: [0, 0.6, 0.5], direction: [1, 0, 0], boxes: [a])
        XCTAssertNil(miss)
        XCTAssertNil(ARMapContent.pick(origin: [0, 0, 0.5], direction: [-1, 0, 0], boxes: [a, b]))
        XCTAssertEqual(ARMapContent.boxEdges(b).count, 12)
    }

    func testCorrectionRequests() throws {
        let r = ObjectCorrectionRequest.rename(scene: "site@10", id: "o-1", label: " Stool ", name: "Mom's chair",
                                               author: "snailsight-phone-1", baseRevision: 7)
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.path, "/v1/scenes/site@10/objects/o-1")
        let o = try JSONSerialization.jsonObject(with: r.body!) as! [String: Any]
        XCTAssertEqual(o["label"] as? String, "Stool")
        XCTAssertEqual(o["name"] as? String, "Mom's chair")
        XCTAssertEqual(o["base_revision"] as? Int, 7)
        let d = ObjectCorrectionRequest.delete(scene: "site@10", id: "o-1", author: "a", baseRevision: nil)
        XCTAssertEqual(d.method, "DELETE"); XCTAssertNil(d.body); XCTAssertEqual(d.query.count, 1)
    }
}
