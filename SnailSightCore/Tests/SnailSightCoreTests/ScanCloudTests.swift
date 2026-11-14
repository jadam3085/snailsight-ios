import XCTest
@testable import SnailSightCore

/// 12.27 Scan view point cloud: back-projection, voxel dedupe by range, quality classes, finer-supersedes-coarser,
/// the memory budget (evict far, decimate, drop), GPU export, coverage.
final class ScanCloudTests: XCTestCase {

    /// A synthetic LiDAR frame in an axis-aligned box room around (camX, camZ): walls at ±halfX / ±halfZ, floor y 0,
    /// ceiling y `ceil`; camera at height 1.4 m, `yaw` about +y, `pitch` about x (negative = down). ARKit depth = the
    /// distance along the camera's -z. Colour: floor red, walls green, ceiling blue (per depth pixel, colour = depth res).
    static func roomFrame(camX: Float, camZ: Float, yaw: Float, pitch: Float = -0.35, w: Int = 128, h: Int = 96,
                          halfX: Float = 2.0, halfZ: Float = 3.0, ceil: Float = 2.5, conf: UInt8 = 2, seed: Int = 0,
                          camY: Float = 1.4, roomCX: Float? = nil, roomCZ: Float? = nil) -> CloudFrameInput {
        let fx = Float(w) * 0.83, fy = fx, cx = Float(w) / 2, cy = Float(h) / 2
        let cyw = cos(yaw), syw = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        // R = Ry(yaw) * Rx(pitch), row-major
        let R: [Float] = [cyw, syw * sp, syw * cp,
                          0, cp, -sp,
                          -syw, cyw * sp, cyw * cp]
        let T: [Float] = [R[0], R[1], R[2], camX, R[3], R[4], R[5], camY, R[6], R[7], R[8], camZ, 0, 0, 0, 1]
        let rx = roomCX ?? camX, rz = roomCZ ?? camZ
        var depth = [Float](repeating: 0, count: w * h)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for v in 0..<h {
            for u in 0..<w {
                let dc = [(Float(u) - cx) / fx, -(Float(v) - cy) / fy, Float(-1)]           // ARKit camera ray, z = -1
                let d = [R[0] * dc[0] + R[1] * dc[1] + R[2] * dc[2],
                         R[3] * dc[0] + R[4] * dc[1] + R[5] * dc[2],
                         R[6] * dc[0] + R[7] * dc[1] + R[8] * dc[2]]
                var best = Float.infinity, col: (UInt8, UInt8, UInt8) = (0, 0, 0)
                func hit(_ t: Float, _ c: (UInt8, UInt8, UInt8)) { if t > 0, t < best { best = t; col = c } }
                if d[1] < 0 { hit((0 - camY) / d[1], (220, 30, 30)) }
                if d[1] > 0 { hit((ceil - camY) / d[1], (30, 30, 220)) }
                if d[0] > 0 { hit((rx + halfX - camX) / d[0], (30, 200, 30)) }
                if d[0] < 0 { hit((rx - halfX - camX) / d[0], (30, 200, 30)) }
                if d[2] > 0 { hit((rz + halfZ - camZ) / d[2], (30, 200, 30)) }
                if d[2] < 0 { hit((rz - halfZ - camZ) / d[2], (30, 200, 30)) }
                guard best.isFinite else { continue }
                depth[v * w + u] = best
                let o = (v * w + u) * 3
                rgb[o] = col.0; rgb[o + 1] = col.1; rgb[o + 2] = col.2
            }
        }
        _ = seed
        return CloudFrameInput(depth: depth, conf: [UInt8](repeating: conf, count: w * h), width: w, height: h,
                               K: [fx, fy, cx, cy], T: T, rgb: rgb, colorW: w, colorH: h)
    }

    /// Distance of a point to the nearest room plane.
    func planeDist(_ p: CloudPoint, halfX: Float = 2, halfZ: Float = 3, ceil: Float = 2.5, cx: Float = 0, cz: Float = 0) -> Float {
        min(abs(p.y), abs(p.y - ceil), abs(abs(p.x - cx) - halfX), abs(abs(p.z - cz) - halfZ))
    }

    func testBackprojectsOntoTheRoomWithColour() {
        var c = ScanCloud()
        let st = c.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: 0.3))
        XCTAssertGreaterThan(st.samples, 2000)
        XCTAssertGreaterThan(c.count, 500)
        XCTAssertEqual(st.added, c.count + st.superseded)
        for p in c.points {
            XCTAssertLessThan(planeDist(p), 0.06, "point \(p.x),\(p.y),\(p.z) off the room")
            let inside = abs(p.x) < 1.8 && abs(p.z) < 2.8                    // away from the corners (mixed voxels)
            if abs(p.y) < 0.03, inside { XCTAssertGreaterThan(p.r, 150) }    // floor red
            if abs(abs(p.z) - 3) < 0.03, abs(p.y - 1.2) < 0.5, abs(p.x) < 1.8 { XCTAssertGreaterThan(p.g, 150) }   // wall green
        }
        XCTAssertGreaterThan(c.version, 0)
    }

    func testSameFrameTwiceDedupes() {
        var c = ScanCloud()
        let f = Self.roomFrame(camX: 0, camZ: 0, yaw: 1.0)
        c.integrate(f)
        let n = c.count
        let st = c.integrate(f)
        XCTAssertEqual(c.count, n, "a repeated view adds no points")
        XCTAssertEqual(st.added, 0)
        XCTAssertGreaterThan(st.merged, 0)
        XCTAssertGreaterThanOrEqual(c.points.map(\.n).max() ?? 0, 2)
    }

    func testVoxelLevelByRange() {
        let cfg = ScanCloudConfig()
        XCTAssertEqual(cfg.level(range: 0.8), 0)
        XCTAssertEqual(cfg.level(range: 2.0), 1)
        XCTAssertEqual(cfg.level(range: 3.5), 2)
        // voxels nest inside a chunk
        for s in ScanCloudConfig.voxelM {
            let r = ScanCloudConfig.chunkM / s
            XCTAssertEqual(r, r.rounded(), accuracy: 1e-3)
        }
        // near wall (1 m): 1.5 cm points; far wall (3.5 m): 6 cm points -> far is much sparser per m²
        var near = ScanCloud(), far = ScanCloud()
        near.integrate(Self.roomFrame(camX: 0, camZ: -2.0, yaw: 0, pitch: 0, w: 256, h: 192, roomCX: 0, roomCZ: 0))   // -z wall 1 m away
        far.integrate(Self.roomFrame(camX: 0, camZ: 0.5, yaw: 0, pitch: 0, w: 256, h: 192, roomCX: 0, roomCZ: 0))     // 3.5 m away
        XCTAssertGreaterThan(near.count, far.count)
    }

    func testQualityClasses() {
        // confidence 1 -> everything faint, nothing good
        var c1 = ScanCloud()
        let s1 = c1.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: 0, conf: 1))
        XCTAssertEqual(s1.good, 0)
        XCTAssertGreaterThan(s1.faint, 0)
        XCTAssertEqual(c1.goodCount, 0)
        // confidence 0 -> dropped
        var c0 = ScanCloud()
        let s0 = c0.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: 0, conf: 0))
        XCTAssertEqual(c0.count, 0)
        XCTAssertEqual(s0.droppedConf, s0.samples)
        // a big room: the far wall (> 4 m) is dropped, 2.5-4 m is faint
        var big = ScanCloud()
        let sb = big.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: 0, pitch: 0, halfX: 8, halfZ: 5, ceil: 6))
        XCTAssertGreaterThan(sb.droppedRange, 0)
        for p in big.points where p.q == 2 {
            let r = (p.x * p.x + (p.y - 1.4) * (p.y - 1.4) + p.z * p.z).squareRoot()
            XCTAssertLessThanOrEqual(r, 2.5 / cos(0.75) + 0.1)                   // good = depth ≤ 2.5 m (corner rays longer)
        }
        // grazing: a floor seen nearly edge-on from 1.4 m looking level is partly dropped / faint
        var g = ScanCloud()
        let sg = g.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: 0, pitch: 0, halfX: 30, halfZ: 30, ceil: 30))
        XCTAssertGreaterThan(sg.droppedGraze + sg.droppedRange, 0)
    }

    func testFinerObservationSupersedesCoarser() {
        var c = ScanCloud()
        // the -z wall from 3.5 m (6 cm voxels), then from 1 m (1.5 cm voxels)
        c.integrate(Self.roomFrame(camX: 0, camZ: 0.5, yaw: 0, pitch: 0, w: 256, h: 192, roomCX: 0, roomCZ: 0))
        func coarseOnWall() -> Int { c.points.filter { abs($0.z + 3) < 0.05 && ($0.key >> 60) == 2 }.count }
        let before = coarseOnWall()
        XCTAssertGreaterThan(before, 50)
        let st = c.integrate(Self.roomFrame(camX: 0, camZ: -2.0, yaw: 0, pitch: 0, w: 256, h: 192, roomCX: 0, roomCZ: 0))
        XCTAssertGreaterThan(st.superseded, 0)
        XCTAssertLessThan(coarseOnWall(), before, "fine detail replaced the coarse voxels it covers")
        // and a coarse look afterwards does not bring them back where fine detail exists
        let fine = c.count
        c.integrate(Self.roomFrame(camX: 0, camZ: 0.5, yaw: 0, pitch: 0, w: 256, h: 192, roomCX: 0, roomCZ: 0))
        XCTAssertLessThan(c.count - fine, before, "coarse samples skip cells that already hold fine detail")
    }

    func testEnforceEvictsFarDecimatesThenDrops() {
        var c = ScanCloud()
        for i in 0..<8 { c.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: Float(i) * 0.8)) }       // room A at 0, 0
        for i in 0..<8 { c.integrate(Self.roomFrame(camX: 30, camZ: 0, yaw: Float(i) * 0.8)) }      // room B 30 m away
        let total = c.count
        // keep radius 20 m from room B: room A goes whole
        var r = c.enforce(camX: 30, camY: 1.4, camZ: 0, maxPoints: 10_000_000, keepRadiusM: 20)
        XCTAssertGreaterThan(r.evictedChunks, 0)
        XCTAssertLessThan(c.count, total)
        XCTAssertTrue(c.points.allSatisfy { $0.x > 20 })
        // budget: half of what is left -> far parts (> 3 m) decimated first, then dropped
        let left = c.count
        for i in 0..<8 { c.integrate(Self.roomFrame(camX: 36, camZ: 0, yaw: Float(i) * 0.8, roomCX: 30)) }
        let grown = c.count
        XCTAssertGreaterThan(grown, left)
        r = c.enforce(camX: 36, camY: 1.4, camZ: 0, maxPoints: grown / 2, keepRadiusM: 20)
        XCTAssertLessThanOrEqual(c.count, grown / 2)
        XCTAssertGreaterThan(r.decimatedChunks + r.evictedChunks, 0)
        // the count is consistent with the stored points
        XCTAssertEqual(c.count, c.points.count)
        // maxPoints 0 (critical) = cleared
        c.enforce(camX: 0, camY: 0, camZ: 0, maxPoints: 0, keepRadiusM: 1)
        XCTAssertEqual(c.count, 0)
    }

    func testDecimateMergesToSixCentimetres() {
        var c = ScanCloud()
        c.integrate(Self.roomFrame(camX: 0, camZ: -2.0, yaw: 0, pitch: 0, w: 256, h: 192))
        let n = c.count
        c.enforce(camX: 50, camY: 1.4, camZ: 0, maxPoints: n / 4, keepRadiusM: 100)        // all chunks far -> decimated
        XCTAssertGreaterThan(c.decimatedChunks, 0)
        XCTAssertLessThanOrEqual(c.count, n / 4 + 1)
        XCTAssertEqual(c.count, c.points.count)
    }

    func testExportWritesPackedVerticesAndFaintAlpha() {
        var c = ScanCloud()
        c.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: 0))                      // floor beyond 2.5 m -> some faint
        let cap = c.count
        let buf = UnsafeMutableRawPointer.allocate(byteCount: cap * ScanCloud.vertexStride, alignment: 16)
        defer { buf.deallocate() }
        let n = c.export(into: buf, capacity: cap, faintAlpha: 90)
        XCTAssertEqual(n, cap)
        var alphas = Set<UInt8>()
        for i in 0..<n { alphas.insert(buf.load(fromByteOffset: i * 16 + 15, as: UInt8.self)) }
        XCTAssertTrue(alphas.isSubset(of: [90, 255]))
        let hidden = c.export(into: buf, capacity: cap, faintAlpha: 0)
        XCTAssertEqual(hidden, c.goodCount)
        // capacity respected
        XCTAssertEqual(c.export(into: buf, capacity: 10), 10)
        let x = buf.load(fromByteOffset: 0, as: Float.self)
        XCTAssertTrue(x.isFinite)
    }

    func testCoverageByCellsAndSurfaceClasses() {
        var c = ScanCloud()
        // one slow turn looking down at 1.4 m, then level: floor + walls in good range
        for i in 0..<24 { c.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: Float(i) * 0.27, pitch: -0.6, halfX: 1.8, halfZ: 1.8)) }
        for i in 0..<24 { c.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: Float(i) * 0.27, pitch: 0.2, halfX: 1.8, halfZ: 1.8)) }
        let s = c.coverage.summary
        XCTAssertGreaterThan(s.cells, 50)
        XCTAssertNotNil(s.pct(.floor))
        XCTAssertNotNil(s.pct(.wall))
        XCTAssertGreaterThan(s.pct(.wall) ?? 0, 60)
        XCTAssertGreaterThan(s.pct(.floor) ?? 0, 40)
        XCTAssertGreaterThan(s.goodShare, 0.5)
        XCTAssertTrue(s.line(outdoor: false).hasPrefix("Floor "))
        XCTAssertTrue(s.line(outdoor: true).hasPrefix("Ground "))
        XCTAssertEqual(s.json["coverage_pct"] as? Int, s.coveragePct)
        // one frame only: nothing is "covered" (needs good depth in ≥ 2 frames)
        var one = ScanCloud()
        one.integrate(Self.roomFrame(camX: 0, camZ: 0, yaw: 0))
        XCTAssertEqual(one.coverage.summary.coveredCells, 0)
        // the top-down mini map marks covered cells around the camera
        let td = c.coverage.topDown(camX: 0, camZ: 0, spanM: 6, n: 12)
        XCTAssertEqual(td.count, 144)
        XCTAssertTrue(td.contains(2))
    }

    func testBoundsAndClear() {
        var c = ScanCloud()
        XCTAssertNil(c.bounds)
        c.integrate(Self.roomFrame(camX: 5, camZ: 5, yaw: 0))
        let b = c.bounds!
        XCTAssertEqual(b.center[0], 5, accuracy: 3)
        XCTAssertGreaterThan(b.radius, 0.5)
        let v = c.version
        c.clear()
        XCTAssertEqual(c.count, 0)
        XCTAssertGreaterThan(c.version, v)
        XCTAssertEqual(c.coverage.count, 0)
    }

    func testRejectsBadInput() {
        var c = ScanCloud()
        var f = Self.roomFrame(camX: 0, camZ: 0, yaw: 0)
        f.K = [0, 0, 0, 0]
        XCTAssertEqual(c.integrate(f).samples, 0)
        f = Self.roomFrame(camX: 0, camZ: 0, yaw: 0)
        f.depth = [1, 2, 3]
        XCTAssertEqual(c.integrate(f).samples, 0)
        f = Self.roomFrame(camX: 0, camZ: 0, yaw: 0)
        f.depth = f.depth.map { _ in Float.nan }
        XCTAssertEqual(c.integrate(f).samples, 0)
    }
}
