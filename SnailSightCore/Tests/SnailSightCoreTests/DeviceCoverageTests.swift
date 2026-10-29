import XCTest
@testable import SnailSightCore

final class DeviceCoverageTests: XCTestCase {
    /// Identity camera at the ARKit origin looking along −z; a flat wall 2 m in front (depth 2 everywhere).
    private func wallFrame(depth d: Float = 2, w: Int = 64, h: Int = 48) -> (depth: [Float], K: [Float], m: [Float]) {
        let K: [Float] = [50, 50, Float(w) / 2, Float(h) / 2]
        let m: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        return ([Float](repeating: d, count: w * h), K, m)
    }

    private let ident = Align4(x: 0, y: 0, z: 0, yaw: 0)

    /// map (x, y, z) for an ARKit world point under the identity alignment (world = (x, z, −y)).
    private func mapPoint(world p: [Float]) -> [Float] { [p[0], -p[2], p[1]] }

    func testFreeSpaceAndSurfaceHideButOccludedStays() {
        var g = DeviceCoverageGrid()
        let f = wallFrame()
        let st = g.observe(depth: f.depth, width: 64, height: 48, confidence: nil, K: f.K, camToWorld: f.m, stride: 2)
        XCTAssertGreaterThan(st.marked, 100)
        XCTAssertEqual(st.skipped, 0)
        // a ghost 50 cm in front of the wall (free space), the wall's doubled copy 5 cm behind it, a face 50 cm behind
        // it (occluded: no evidence) and one far outside the view
        let faces = [[0, 0, -1.5], [0.1, 0.05, -2.05], [0, 0, -2.5], [5, 0, -2]].map { mapPoint(world: $0.map(Float.init)) }
        var cf = CoveredFaces(id: "t", centroids: faces.flatMap { $0 })
        XCTAssertEqual(cf.update(grid: g, align: ident), 2)
        XCTAssertEqual(cf.hidden, [true, true, false, false])
        XCTAssertEqual(cf.keptIndices([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]), [6, 7, 8, 9, 10, 11])
    }

    func testStickyAndSkipsWhenNothingNewNearby() {
        var g = DeviceCoverageGrid()
        let f = wallFrame()
        g.observe(depth: f.depth, width: 64, height: 48, confidence: nil, K: f.K, camToWorld: f.m)
        var cf = CoveredFaces(id: "t", centroids: mapPoint(world: [0, 0, -1]))
        XCTAssertEqual(cf.update(grid: g, align: ident), 1)
        // the wall moves away (a later frame sees deeper): nothing un-hides
        let f2 = wallFrame(depth: 0.5)
        g.observe(depth: f2.depth, width: 64, height: 48, confidence: nil, K: f2.K, camToWorld: f2.m)
        XCTAssertEqual(cf.update(grid: g, align: ident), 0)
        XCTAssertTrue(cf.allHidden)
        // a far-away face set is not re-tested for a frame that marked nothing near it
        var far = CoveredFaces(id: "far", centroids: [40, 40, 0])
        far.update(grid: g, align: ident)
        XCTAssertFalse(g.changed(in: far.worldBox(ident), since: far.testedGen))
    }

    func testLowConfidenceAndOutOfRangeGiveNoEvidence() {
        var g = DeviceCoverageGrid()
        let f = wallFrame(depth: 6)                              // beyond maxRange
        let st = g.observe(depth: f.depth, width: 64, height: 48, confidence: nil, K: f.K, camToWorld: f.m)
        XCTAssertEqual(st.marked, 0)
        let f2 = wallFrame()
        let low = [UInt8](repeating: 0, count: 64 * 48)
        XCTAssertEqual(g.observe(depth: f2.depth, width: 64, height: 48, confidence: low, K: f2.K, camToWorld: f2.m).marked, 0)
        XCTAssertEqual(g.count, 0)
    }

    func testAlignmentDecidesWhereStoredFacesAreTested() {
        var g = DeviceCoverageGrid()
        let f = wallFrame()
        g.observe(depth: f.depth, width: 64, height: 48, confidence: nil, K: f.K, camToWorld: f.m)
        // the stored face at map (10, 1.5, 0): under the identity it is far away; with the map shifted by x = 10
        // (world = map − 10 in x) it lands in front of the camera
        var cf = CoveredFaces(id: "t", centroids: [10, 1.5, 0])
        XCTAssertEqual(cf.update(grid: g, align: ident), 0)
        XCTAssertEqual(cf.update(grid: g, align: Align4(x: 10, y: 0, z: 0, yaw: 0)), 1)
    }

    func testCameraPoseRotatesRays() {
        var g = DeviceCoverageGrid()
        // camera turned 90° about y (looks along −x): column-major [x | y | z | t]
        let m: [Float] = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1]
        let f = wallFrame()
        g.observe(depth: f.depth, width: 64, height: 48, confidence: nil, K: f.K, camToWorld: m)
        XCTAssertTrue(g.contains(x: -1.5, y: 0, z: 0))
        XCTAssertFalse(g.contains(x: 0, y: 0, z: -1.5))
    }

    func testClearAndRebuildRule() {
        var g = DeviceCoverageGrid()
        let f = wallFrame()
        g.observe(depth: f.depth, width: 64, height: 48, confidence: nil, K: f.K, camToWorld: f.m)
        XCTAssertGreaterThan(g.count, 0)
        g.clear()
        XCTAssertEqual(g.count, 0)
        XCTAssertTrue(CoverageRebuild.due(hidden: 30, applied: 0, faces: 10_000))
        XCTAssertFalse(CoverageRebuild.due(hidden: 10, applied: 0, faces: 10_000))
        XCTAssertTrue(CoverageRebuild.due(hidden: 10, applied: 0, faces: 10))          // everything hidden
        XCTAssertTrue(CoverageRebuild.due(hidden: 5, applied: 0, faces: 100))           // ≥ 1 %
        XCTAssertFalse(CoverageRebuild.due(hidden: 5, applied: 5, faces: 100))
    }

    func testCentroids() {
        let c = CoveredFaces.centroids(positions: [0, 0, 0, 3, 0, 0, 0, 3, 0], indices: [0, 1, 2, 0, 1, 9])
        XCTAssertEqual(Array(c[0..<3]), [1, 1, 0])
        XCTAssertTrue(c[3].isNaN)
    }
}
