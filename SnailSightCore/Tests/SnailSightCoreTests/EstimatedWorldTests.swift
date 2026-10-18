import XCTest
@testable import SnailSightCore

/// API §5.16 decoders on real responses from the map server (2026-10-18, site rev 2).
final class EstimatedWorldTests: XCTestCase {
    static let coverage = #"{"map_id":"site","rev":2,"coverage_rev":1,"tile_m":16,"bbox":[10.0,-40.0,12.0,-38.0],"tiles":[{"key":"16/0/-3","bbox":[0,-48,16,-32],"surveyed_frac":0.03,"estimated_frac":0.97,"unknown_frac":0.0,"class":"estimated","trees":{"estimated":8}}],"mask":{"origin":[10.0,-40.0],"res":0.5,"w":4,"h":4,"order":"row-major, row 0 = min y","values":{"0":"unknown","1":"estimated","2":"surveyed"},"encoding":"base64 uint8","data":"AQEBAQEBAQEBAQEBAQEBAQ=="}}"#

    static let trees = #"{"map_id": "site", "layer": "estimated", "rev": 2, "events_seq": 0, "source": {"name": "NJOGIS DVRPC 2015 QL2 lidar (public domain)", "year": 2015, "accuracy_m": 2.0}, "counts": {"estimated": 1, "confirmed": 0, "corrected": 0, "refuted": 0, "retired": 0}, "trees": [{"id": 21396, "status": "estimated", "retired": false, "x": 6.92, "y": -38.41, "z": -0.46, "height_m": 20.8, "crown_r_m": 2.24, "trunk_r_m": 0.31, "est": {"x": 6.92, "y": -38.41}, "observed": null, "offset_m": null, "corrected_to": null}, {"id": 7, "status": "corrected", "retired": false, "x": 2.0, "y": 1.0, "est": {"x": 0.4, "y": 1.0}, "offset_m": [1.6, 0.0], "corrected_to": "s12"}], "surveyed_trees": [], "dem": {"origin": [6.0, -39.0], "res": 0.5, "w": 4, "h": 3, "encoding": "base64 float16 little-endian", "ground": "kbZRt9e3MrjWtlu3+LcmuG+3CLgMuOC3", "canopy": "FU0tTSlNE03TTO5MwEyNTGZMWExITFFM", "slope_deg": "s0WQRO5DB0TWRNhE+UL6QS5GkEV6PNBC", "nogo_slope_deg": 25.0}}"#

    func testCoverageMask() throws {
        let c = try XCTUnwrap(CoverageDoc.parse(Data(Self.coverage.utf8)))
        XCTAssertEqual(c.coverageRev, 1)
        XCTAssertEqual(c.tiles.first?.cls, "estimated")
        XCTAssertEqual(c.surveyedFrac, 0.03, accuracy: 1e-9)
        let g = try XCTUnwrap(c.grid)
        XCTAssertEqual(g.w, 4); XCTAssertEqual(g.counts.estimated, 16)
        XCTAssertEqual(g.cls(x: 10.2, y: -39.9), .estimated)
        XCTAssertEqual(g.cls(x: 50, y: 0), .unknown)
        let px = g.rgba()
        XCTAssertEqual(px.count, 64)
        XCTAssertGreaterThan(px[3], 0)                                      // estimated cells are tinted (hatched)
    }

    func testTreesLooksAndDem() throws {
        let d = try XCTUnwrap(EstimatedDoc.parse(Data(Self.trees.utf8)))
        XCTAssertEqual(d.trees.count, 2)
        XCTAssertEqual(d.trees[0].id, "21396"); XCTAssertEqual(d.trees[0].look, .ghost)
        XCTAssertEqual(d.trees[1].look, .corrected)
        XCTAssertEqual(d.trees[1].offsetDistance!, 1.6, accuracy: 1e-9)
        XCTAssertEqual(d.correctedCount, 1)
        XCTAssertEqual(d.sourceLabel, "NJOGIS DVRPC 2015 QL2 lidar (public domain) · 2015 · ±2 m")
        let dem = try XCTUnwrap(d.dem.flatMap(EstimatedDEM.init))
        XCTAssertEqual(dem.ground(x: 6.1, y: -38.9)!, -0.41, accuracy: 0.002)
        XCTAssertEqual(dem.canopy(x: 6.1, y: -38.9)!, 20.328, accuracy: 0.01)
        XCTAssertEqual(dem.slope(x: 7.9, y: -37.6)!, 3.406, accuracy: 0.01)
        XCTAssertNil(dem.ground(x: 0, y: 0))
        XCTAssertTrue(dem.noGoRGBA(coverage: nil).allSatisfy { $0 == 0 })   // nothing above 25° here
    }

    func testHalfFloat() {
        XCTAssertEqual(Half.toFloat(0x3c00), 1)
        XCTAssertEqual(Half.toFloat(0xc000), -2)
        XCTAssertEqual(Half.toFloat(0x0000), 0)
        XCTAssertTrue(Half.toFloat(0x7e00).isNaN)
        XCTAssertEqual(Half.toFloat(0x7c00), .infinity)
        XCTAssertEqual(Half.toFloat(0x0001), powf(2, -24), accuracy: 1e-12)
    }

    func testLiveEstimatedMessage() throws {
        let m = try XCTUnwrap(EstimatedLiveMessage.parse(Data(#"{"type":"estimated","rev":3,"seq":9,"coverage_changed":true,"events":[{"seq":9,"kind":"tree_status","id":21396,"from":"estimated","to":"corrected","offset_m":[1.2,-1.0]}]}"#.utf8)))
        XCTAssertEqual(m.coverageChanged, true)
        XCTAssertEqual(m.events?.first?.id, "21396")
        XCTAssertEqual(m.events?.first?.text, "Tree corrected · 1.6 m off the estimate")
        XCTAssertNil(EstimatedLiveMessage.parse(Data(#"{"type":"tile"}"#.utf8)))
    }
}
