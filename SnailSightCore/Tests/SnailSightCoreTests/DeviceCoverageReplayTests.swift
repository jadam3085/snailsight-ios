import Foundation
import XCTest
@testable import SnailSightCore

/// Replay of a REAL recorded live stream (LiDAR depth + confidence + ARKit pose + the phone's server lock T_map_arkit)
/// against the base leaf tiles near it, through the exact DeviceCoverage code the app runs. Skipped unless
/// SNAILSIGHT_COVERAGE_REPLAY = a fixture from tools (snailCOP scratch coverage_fixture.py):
/// {frames: [{w, h, K, camToWorld (column-major), T_map_arkit (row-major), depth_mm (b64 u16), conf (b64 u8)}],
///  tiles: [{key, faces, box, centroids (b64 f32 xyz, map frame)}], cams: [[x, y, z] map]}.
final class DeviceCoverageReplayTests: XCTestCase {
    func testRecordedStream() throws {
        guard let path = ProcessInfo.processInfo.environment["SNAILSIGHT_COVERAGE_REPLAY"] else {
            throw XCTSkip("set SNAILSIGHT_COVERAGE_REPLAY to a coverage fixture")
        }
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let frames = try XCTUnwrap(o["frames"] as? [[String: Any]])
        let tilesJ = try XCTUnwrap(o["tiles"] as? [[String: Any]])
        let cams = (o["cams"] as? [[Double]]) ?? []
        func floats(_ b64: String) -> [Float] {
            let d = Data(base64Encoded: b64) ?? Data()
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        var faces: [CoveredFaces] = tilesJ.map { CoveredFaces(id: $0["key"] as! String, centroids: floats($0["centroids"] as! String)) }
        var grid = DeviceCoverageGrid()
        var observeMs: [Double] = [], updateMs: [Double] = []
        var firstHideFrame: Int?
        for (i, f) in frames.enumerated() {
            let w = f["w"] as! Int, h = f["h"] as! Int
            let mm = Data(base64Encoded: f["depth_mm"] as! String)!.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            let depth = mm.map { Float($0) / 1000 }
            let conf = (f["conf"] as? String).flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) }
            let K = (f["K"] as! [NSNumber]).map { $0.floatValue }
            let M = (f["camToWorld"] as! [NSNumber]).map { $0.floatValue }
            let T = (f["T_map_arkit"] as! [NSNumber]).map { $0.doubleValue }
            let al = Align4(Mat4(T))
            var t0 = Date()
            grid.observe(depth: depth, width: w, height: h, confidence: conf, K: K, camToWorld: M)
            observeMs.append(Date().timeIntervalSince(t0) * 1000)
            t0 = Date()
            var newly = 0
            for j in faces.indices { newly += faces[j].update(grid: grid, align: al) }
            updateMs.append(Date().timeIntervalSince(t0) * 1000)
            if newly > 0 && firstHideFrame == nil { firstHideFrame = i }
        }
        func dist(_ b: [Double]) -> Double {
            cams.map { c -> Double in
                let dx = max(0, max(b[0] - c[0], c[0] - b[3])), dy = max(0, max(b[1] - c[1], c[1] - b[4]))
                let dz = max(0, max(b[2] - c[2], c[2] - b[5]))
                return (dx * dx + dy * dy + dz * dz).squareRoot()
            }.min() ?? 1e9
        }
        var total = 0, hidden = 0
        var lines: [String] = []
        for (j, t) in tilesJ.enumerated() {
            let b = (t["box"] as! [NSNumber]).map { $0.doubleValue }
            let cf = faces[j]
            total += cf.faceCount
            hidden += cf.hiddenCount
            lines.append(String(format: "%@ faces %d hidden %d (%.1f %%) cam-dist %.1f m", cf.id, cf.faceCount, cf.hiddenCount,
                                100 * Double(cf.hiddenCount) / Double(max(1, cf.faceCount)), dist(b)))
        }
        let om = observeMs.sorted(), um = updateMs.sorted()
        print("COVERAGE_REPLAY frames \(frames.count) cells \(grid.count) faces \(total) hidden \(hidden) " +
              String(format: "(%.1f %%)", 100 * Double(hidden) / Double(max(1, total))) +
              " first_hide_frame \(firstHideFrame ?? -1)" +
              String(format: " observe_ms p50 %.1f max %.1f update_ms p50 %.1f max %.1f", om[om.count / 2], om.last ?? 0,
                     um[um.count / 2], um.last ?? 0))
        for l in lines { print("COVERAGE_REPLAY " + l) }
        XCTAssertGreaterThan(hidden, 0)
        XCTAssertEqual(firstHideFrame, 0, "the first depth frame already hides what it sees")
    }
}
