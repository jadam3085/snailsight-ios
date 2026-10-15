import XCTest
import simd
@testable import SnailSightCore

/// 9.6 Scans screen: catalogue decode + order, cache policy, splat budget, frames, cameras, walk points, ray casts,
/// dollhouse fit.
final class ScanTests: XCTestCase {
    let sample = """
    {"items":[
     {"id":"site@4","type":"map","title":"Whole house · v4","subtitle":"7 walks · v4","created":100,"map_id":"site","version":4,
      "latest":false,"thumb_url":"/v1/phone/scans/site@4/files/thumb.jpg",
      "mesh":{"state":"ready","usdz_url":"/v1/phone/scans/site@4/files/mesh.usdz","bytes":41000000,"triangles":990000,
              "texture_px":4096,"error":null,"frame":"y-up"},
      "splat":{"url":"/v1/scenes/site@4/files/splat_v1/splat_mobile.splat","bytes":32000000,"count":1000000,
               "format":"splat","frame":"z-up"},
      "views_url":"/v1/scenes/site@4/files/views.json","bounds":{"min":[-1,-2,0],"max":[3,4,2.5]},"bounds_frame":"z-up",
      "floor_z":0.02,"dims_m":null},
     {"id":"site@5","type":"map","title":"Whole house · v5","created":200,"map_id":"site","version":5,"latest":true,
      "thumb_url":null,"mesh":{"state":"building","usdz_url":null,"bytes":null,"triangles":null,"texture_px":null,
      "error":null,"frame":"y-up"},"splat":null,"views_url":null,"bounds":null,"bounds_frame":"z-up","floor_z":null,"dims_m":null},
     {"id":"trial@2","type":"map","title":"Trial","created":300,"map_id":"trial","version":2,"latest":true},
     {"id":"s-1","type":"session","title":"walk 1","created":50},
     {"id":"s-2","type":"session","title":"walk 2","created":60},
     {"id":"o-1","type":"object","title":"RoboSnailBob","created":70,"dims_m":[0.84,0.61,0.62],
      "bounds":{"min":[-0.42,0,-0.31],"max":[0.42,0.61,0.31]},"bounds_frame":"y-up",
      "mesh":{"state":"ready","usdz_url":"/x/model.usdz","bytes":5,"triangles":10,"texture_px":null,"error":null,"frame":"y-up"}}
    ]}
    """

    func testDecodeAndSections() throws {
        let items = try ScanCatalog.decode(Data(sample.utf8))
        XCTAssertEqual(items.count, 6)
        let s4 = items[0]
        XCTAssertEqual(s4.mapID, "site"); XCTAssertEqual(s4.mesh?.isReady, true); XCTAssertEqual(s4.splat?.count, 1_000_000)
        XCTAssertEqual(items[1].mesh?.isPending, true); XCTAssertNil(items[2].mesh)
        let secs = ScanCatalog.sections(items)
        XCTAssertEqual(secs.map(\.title), ["Whole house", "Walks", "Objects", "Older map versions"])
        XCTAssertEqual(secs[0].items.map(\.id), ["site@5", "trial@2"])       // newest version per map, site first
        XCTAssertEqual(secs[1].items.map(\.id), ["s-2", "s-1"])
        XCTAssertEqual(secs[2].items.map(\.id), ["o-1"])
        XCTAssertEqual(secs[3].items.map(\.id), ["site@4"])
        XCTAssertTrue(ScanCatalog.sections([]).isEmpty)
    }

    func testBoundsFrames() throws {
        let items = try ScanCatalog.decode(Data(sample.utf8))
        let b = try XCTUnwrap(items[0].boundsYUp)                   // map z-up → y-up: (x, z, −y)
        XCTAssertEqual(b.min, SIMD3<Float>(-1, 0, -4)); XCTAssertEqual(b.max, SIMD3<Float>(3, 2.5, 2))
        let o = try XCTUnwrap(items[5].boundsYUp)                   // objects are already y-up
        XCTAssertEqual(o.max.y, 0.61, accuracy: 1e-6)
        let p = SIMD3<Float>(1, 2, 3)
        XCTAssertEqual(ScanFrames.yUpToMap(ScanFrames.mapToYUp(p)), p)
        let m = ScanFrames.mapToYUpMatrix * SIMD4<Float>(p, 1)
        XCTAssertEqual(SIMD3(m.x, m.y, m.z), ScanFrames.mapToYUp(p))
    }

    func testCachePolicyAndSplatBudget() {
        let pol = ScanCachePolicy(budgetBytes: 100)
        let e: [ScanCachePolicy.Entry] = [.init(key: "a", bytes: 60, lastUsed: 1), .init(key: "b", bytes: 60, lastUsed: 2),
                                          .init(key: "c", bytes: 30, lastUsed: 3)]
        XCTAssertEqual(pol.evictions(e, keep: "c"), ["a"])
        XCTAssertEqual(pol.evictions(e, keep: "a"), ["b"])            // the kept one is never evicted
        XCTAssertEqual(pol.evictions([.init(key: "a", bytes: 500, lastUsed: 1)], keep: "a"), [])
        XCTAssertEqual(ScanCachePolicy.folderName("site@5"), "site_5")
        XCTAssertEqual(SplatBudget.maxSplats(physicalMemoryBytes: 8 << 30), 1_500_000)
        XCTAssertEqual(SplatBudget.maxSplats(physicalMemoryBytes: 6 << 30), 1_000_000)
        XCTAssertEqual(SplatBudget.maxSplats(physicalMemoryBytes: 4 << 30), 500_000)
        XCTAssertEqual(SplatBudget.loadBytes(fileBytes: 32 * 10 + 7, maxSplats: 100), 320)
        XCTAssertEqual(SplatBudget.loadBytes(fileBytes: 32 * 10, maxSplats: 4), 128)
        XCTAssertEqual(ScanCatalog.bytesText(41_000_000), "39 MB")
    }

    func testCameras() {
        var o = OrbitCamera(target: .zero, yaw: 0, pitch: 0, distance: 2)
        XCTAssertEqual(o.eye.z, 2, accuracy: 1e-5)
        let v = o.viewMatrix * SIMD4<Float>(0, 0, 0, 1)                 // target is straight ahead, 2 m along −Z
        XCTAssertEqual(v.z, -2, accuracy: 1e-5); XCTAssertEqual(v.x, 0, accuracy: 1e-5)
        o.zoom(2); XCTAssertEqual(o.distance, 1, accuracy: 1e-5)
        o.zoom(1e-9); XCTAssertEqual(o.distance, OrbitCamera.maxDistance)
        o.rotate(dx: 0, dy: 10); XCTAssertEqual(o.pitch, OrbitCamera.maxPitch)
        var p = OrbitCamera(target: .zero, yaw: 0, pitch: 0, distance: 1)
        p.pan(dx: 0.5, dy: 0)                                           // finger right → scene right → target left
        XCTAssertEqual(p.target.x, -0.5, accuracy: 1e-5)
        var f = OrbitCamera()
        f.frame(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1), fovy: .pi / 3)
        XCTAssertEqual(f.target, .zero); XCTAssertGreaterThan(f.distance, 3.4)

        var w = WalkCamera(eye: SIMD3(0, 1.5, 0), yaw: 0)
        XCTAssertEqual(w.forward.z, -1, accuracy: 1e-6)
        w.move(forwardM: 1, rightM: 0); XCTAssertEqual(w.eye.z, -1, accuracy: 1e-6)
        w.move(forwardM: 0, rightM: 1); XCTAssertEqual(w.eye.x, 1, accuracy: 1e-6)
        XCTAssertEqual(w.eye.y, 1.5)
        XCTAssertEqual(WalkCamera.yaw(of: SIMD3(-1, 0, 0)), .pi / 2, accuracy: 1e-6)
        w.look(dx: 0, dy: 5); XCTAssertEqual(w.pitch, 1.2)

        // projection round trip: the centre ray hits what the view matrix puts in front of the camera
        let r = CameraMath.ray(screen: SIMD2(200, 300), size: SIMD2(400, 600), eye: SIMD3(0, 1, 5), forward: SIMD3(0, 0, -1),
                               fovy: 1)
        XCTAssertEqual(r.dir.z, -1, accuracy: 1e-5)
        let r2 = CameraMath.ray(screen: SIMD2(400, 300), size: SIMD2(400, 600), eye: .zero, forward: SIMD3(0, 0, -1), fovy: 1)
        XCTAssertGreaterThan(r2.dir.x, 0)                               // right edge → +X
        let P = CameraMath.perspective(fovyRadians: 1, aspect: 400.0 / 600, near: 0.1, far: 100)
        let clip = P * SIMD4<Float>(r2.dir * 3, 1)
        XCTAssertEqual(clip.x / clip.w, 1, accuracy: 1e-4)              // lands on the right edge of NDC
    }

    func testWalkPoints() {
        let views = """
        {"frame":"scene, Z-up, OpenGL camera","views":[
          {"id":1,"c2w":[[1,0,0,1],[0,0,-1,2],[0,1,0,1.4],[0,0,0,1]]}]}
        """
        // camera −Z column = −(0,−1,0)... c2w col2 = (0,-1,0) → forward (map) = (0,1,0) = +Y map → viewer (0,0,−1)
        let v = WalkPoints.parse(Data(views.utf8))
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].eye, SIMD3<Float>(1, 1.4, -2))
        XCTAssertEqual(v[0].yaw, 0, accuracy: 1e-5); XCTAssertEqual(v[0].pitch, 0, accuracy: 1e-5)
        let paths = """
        {"paths":[{"points":[[0,0,0],[0.5,0,0],[1.0,0,0],[2.0,0,0]]}]}
        """
        let p = WalkPoints.parse(Data(paths.utf8), spacing: 0.75)
        XCTAssertEqual(p.count, 3)                                      // 0, 1.0, 2.0 (0.5 is too close)
        XCTAssertEqual(p[0].yaw, -.pi / 2, accuracy: 1e-5)              // heading +X
        XCTAssertEqual(WalkPoints.nearest(p, to: SIMD3(1.9, 0, 0)), 2)
        XCTAssertNil(WalkPoints.nearest([], to: .zero))
        XCTAssertTrue(WalkPoints.parse(Data("nope".utf8)).isEmpty)
    }

    func testTriangleIndexRaycast() {
        // floor quad 4×4 m at y = 0 and a wall at z = −1 (x −2…2, y 0…2)
        let pos: [SIMD3<Float>] = [SIMD3(-2, 0, -2), SIMD3(2, 0, -2), SIMD3(2, 0, 2), SIMD3(-2, 0, 2),
                                   SIMD3(-2, 0, -1), SIMD3(2, 0, -1), SIMD3(2, 2, -1), SIMD3(-2, 2, -1)]
        let idx: [UInt32] = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
        let ti = TriangleIndex(positions: pos, indices: idx)
        XCTAssertEqual(ti.triangleCount, 4)
        let down = ti.raycast(origin: SIMD3(0.3, 1.5, 0.5), dir: SIMD3(0, -1, 0))
        XCTAssertEqual(down?.t ?? -1, 1.5, accuracy: 1e-4)
        XCTAssertEqual(down?.normal.y ?? 0, 1, accuracy: 1e-4)
        let fwd = ti.raycast(origin: SIMD3(0, 1, 1), dir: SIMD3(0, 0, -1))    // wall first, not the floor beyond
        XCTAssertEqual(fwd?.point.z ?? 0, -1, accuracy: 1e-4)
        XCTAssertEqual(fwd?.normal.z ?? 0, 1, accuracy: 1e-4)                // faces the ray
        XCTAssertNil(ti.raycast(origin: SIMD3(0, 1, 1), dir: SIMD3(0, 1, 0)))
        XCTAssertNil(ti.raycast(origin: SIMD3(10, 1, 10), dir: SIMD3(1, 0, 0)))
        let diag = ti.raycast(origin: SIMD3(-1.9, 1.9, 1.9), dir: SIMD3(1, -0.5, -1))
        XCTAssertNotNil(diag)
        // brute-force agreement on a random-ish fan of rays
        for i in 0..<40 {
            let a = Float(i) * 0.15
            let o = SIMD3<Float>(0, 1.2, 1.5), d = SIMD3<Float>(cosf(a) * 0.7, -0.4 + 0.02 * Float(i), -sinf(a))
            var bt = Float.infinity
            for t in 0..<4 {
                if let h = TriangleIndex.intersect(origin: o, dir: simd_normalize(d), pos[Int(idx[t * 3])],
                                                   pos[Int(idx[t * 3 + 1])], pos[Int(idx[t * 3 + 2])]) { bt = min(bt, h) }
            }
            let g = ti.raycast(origin: o, dir: d)?.t ?? .infinity
            if bt.isInfinite { XCTAssertTrue(g.isInfinite, "ray \(i)") } else { XCTAssertEqual(g, bt, accuracy: 1e-3, "ray \(i)") }
        }
        XCTAssertNil(TriangleIndex(positions: [], indices: []).raycast(origin: .zero, dir: SIMD3(0, 0, 1)))
    }

    func testDollhouse() {
        let s = Dollhouse.fitScale(min: SIMD3(-6, 0, -11), max: SIMD3(6, 6, 11), targetM: 0.6)
        XCTAssertEqual(s, 0.6 / 22, accuracy: 1e-6)
        XCTAssertEqual(Dollhouse.fitScale(min: SIMD3(-0.2, 0, -0.2), max: SIMD3(0.2, 0.5, 0.2)), 1)
        XCTAssertEqual(Dollhouse.scaleLabel(0.6 / 22), "1 : 37")
        XCTAssertEqual(Dollhouse.scaleLabel(1), "1 : 1")
        XCTAssertEqual(Dollhouse.baseOffset(min: SIMD3(1, -0.1, 2), max: SIMD3(3, 2, 4)), SIMD3<Float>(-2, 0.1, -3))
        XCTAssertEqual(Dollhouse.baseOffset(min: SIMD3(1, -0.1, 2), max: SIMD3(3, 2, 4), floorY: 0.05).y, -0.05)
    }
}

final class SplatDecodeTests: XCTestCase {
    func testDotSplatRecordAndFit() {
        var d = Data()
        for v: Float in [1, 2, 3, 0.1, 0.2, 0.3] { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: [255, 128, 0, 51, 255, 128, 128, 128] as [UInt8])     // rot w = 127/128, x=y=z=0
        XCTAssertEqual(d.count, DotSplatRecord.byteWidth)
        let r = d.withUnsafeBytes { DotSplatRecord.decode($0.baseAddress!) }
        XCTAssertEqual(r.position, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(r.scale.y, 0.2, accuracy: 1e-7)
        XCTAssertEqual(r.opacity, 0.2, accuracy: 1e-6)
        XCTAssertEqual(r.rotation.real, 1, accuracy: 1e-6)
        XCTAssertEqual(r.sh0.x, 0.5 / DotSplatRecord.shC0, accuracy: 1e-4)
        XCTAssertEqual(r.sh0.z, -0.5 / DotSplatRecord.shC0, accuracy: 1e-4)
        XCTAssertEqual(SplatBudget.fit(maxSplats: 1_500_000, availableMB: nil), 1_500_000)
        XCTAssertEqual(SplatBudget.fit(maxSplats: 1_500_000, availableMB: 532), 524_288)
        XCTAssertEqual(SplatBudget.fit(maxSplats: 1_500_000, availableMB: 100), 0)
    }
}
