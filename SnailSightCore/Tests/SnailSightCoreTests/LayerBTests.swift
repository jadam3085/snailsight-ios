import XCTest
@testable import SnailSightCore

final class LayerBTests: XCTestCase {
    /// base64(<u32 nv><u32 nt> f32 xyz, u32 idx) of one triangle inside block b (0.4 m blocks).
    private func tri(_ b: [Int]) -> String {
        let o = b.map { Float($0) * 0.4 + 0.1 }
        let pos: [Float] = [o[0], o[1], o[2], o[0] + 0.1, o[1], o[2], o[0], o[1] + 0.1, o[2]]
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(3); u32(1)
        for p in pos { u32(p.bitPattern) }
        for i: UInt32 in [0, 1, 2] { u32(i) }
        return d.base64EncodedString()
    }

    private func frame(since: Int?, seq: Int, blocks: [(b: [Int], s: String)], removed: [[Int]] = [], rgb: Bool = false) -> Data {
        let bl = blocks.map { e -> String in
            var s = #"{"b":[\#(e.b[0]),\#(e.b[1]),\#(e.b[2])],"s":"\#(e.s)","rev":\#(seq),"tracked":3,"src":"live""#
            if e.s == "surface" {
                s += #","nv":3,"nt":1,"data":"\#(tri(e.b))""#
                if rgb { s += #","rgb":"\#(Data([255, 0, 0, 0, 255, 0, 0, 0, 255]).base64EncodedString())""# }
            } else { s += #","nv":0,"nt":0"# }
            return s + "}"
        }.joined(separator: ",")
        let rm = removed.map { "[\($0[0]),\($0[1]),\($0[2])]" }.joined(separator: ",")
        let sinceS = since.map(String.init) ?? "null"
        let json = #"{"type":"tile","layer":"surface","key":"0/0/0","level":0,"tx":0,"ty":0,"ver":{"base_version":14,"live_seq":\#(seq)},"since":\#(sinceS),"enc":"ssmesh1+zlib","voxel_m":0.04,"block_m":0.4,"blocks":[\#(bl)],"removed":[\#(rm)],"hw":{"phone-1/ar-1":12},"hw_wall":100.5,"stages":{"capture_to_commit_ms":850}}"#
        return Data(json.utf8)
    }

    func testFullDeltaRemovedAndGap() throws {
        var st = LayerBStore()
        let full = try XCTUnwrap(SurfaceFrame.parse(frame(since: nil, seq: 10, blocks: [([1, 2, 3], "surface"), ([2, 2, 3], "empty")], rgb: true)))
        XCTAssertTrue(SurfaceFrame.isSurface(frame(since: nil, seq: 10, blocks: [])))
        XCTAssertEqual(full.captureToCommitMs, 850)
        XCTAssertEqual(full.agents, ["phone-1"])
        XCTAssertEqual(full.blocks[0].mesh?.triangleCount, 1)
        XCTAssertEqual(full.blocks[0].rgb?.count, 9)
        XCTAssertEqual(st.apply(full, now: 1), .applied(changed: [BlockKey(1, 2, 3), BlockKey(2, 2, 3)], full: true))
        XCTAssertEqual(st.blockCount, 2)
        XCTAssertEqual(st.surfaceBlocks, 1)
        // a base face inside the empty cube and one inside the surface cube are hidden, one outside is not
        let (mask, n) = st.hiddenFaces(centroids: [0.9, 0.9, 1.3, 0.5, 0.9, 1.3, 5, 5, 5])
        XCTAssertEqual(mask, [true, true, false])
        XCTAssertEqual(n, 2)
        // delta on top of 10: the empty cube is removed, a new surface block added
        let d = try XCTUnwrap(SurfaceFrame.parse(frame(since: 10, seq: 12, blocks: [([1, 3, 3], "surface")], removed: [[2, 2, 3]])))
        XCTAssertEqual(st.apply(d, now: 2), .applied(changed: [BlockKey(1, 3, 3), BlockKey(2, 2, 3)], full: false))
        XCTAssertFalse(st.supersedes(x: 0.9, y: 0.9, z: 1.3))
        XCTAssertEqual(st.held["0/0/0"], TileVer(base: 14, seq: 12))
        let m = try XCTUnwrap(st.tileMesh("0/0/0"))
        XCTAssertEqual(m.mesh.triangleCount, 2)
        XCTAssertEqual(m.mesh.indices, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(m.rgb?.count, 18)                                 // one coloured block + one grey block
        // a delta on top of 20 (missed 13…20): gap, nothing applied
        let g = try XCTUnwrap(SurfaceFrame.parse(frame(since: 20, seq: 25, blocks: [([9, 9, 9], "surface")])))
        XCTAssertEqual(st.apply(g, now: 3), .gap(held: 12, since: 20))
        XCTAssertFalse(st.supersedes(x: 3.7, y: 3.7, z: 3.7))
        // an old re-send (since older than held) is harmless
        let old = try XCTUnwrap(SurfaceFrame.parse(frame(since: 8, seq: 12, blocks: [])))
        if case .gap = st.apply(old, now: 4) { XCTFail("older since must apply") }
        // a full frame drops everything first
        let f2 = try XCTUnwrap(SurfaceFrame.parse(frame(since: nil, seq: 30, blocks: [([0, 0, 0], "empty")])))
        _ = st.apply(f2, now: 5)
        XCTAssertEqual(st.blockCount, 1)
        XCTAssertEqual(st.tileMesh("0/0/0")?.mesh.triangleCount, 0)
    }

    func testDeltaWithoutHeldTileIsAGap() throws {
        var st = LayerBStore()
        let d = try XCTUnwrap(SurfaceFrame.parse(frame(since: 3, seq: 5, blocks: [([1, 1, 1], "surface")])))
        XCTAssertEqual(st.apply(d, now: 0), .gap(held: nil, since: 3))
    }

    func testEpochResets() throws {
        var st = LayerBStore()
        st.setEpoch("a")
        _ = st.apply(try XCTUnwrap(SurfaceFrame.parse(frame(since: nil, seq: 1, blocks: [([1, 1, 1], "surface")]))), now: 0)
        st.setEpoch("a")
        XCTAssertEqual(st.blockCount, 1)
        st.setEpoch("b")
        XCTAssertEqual(st.blockCount, 0)
        XCTAssertNil(SurfaceFrame.parse(Data(#"{"type":"tile","layer":"mesh","key":"0/0/0"}"#.utf8)))
    }

    func testStagesLine() {
        var s = LiveStages()
        XCTAssertNil(s.short)
        XCTAssertTrue(s.ack(["seq": 5, "stages": ["seq": 4, "ms": ["ingest": 120, "align": 640, "mesh": 900, "publish": 1900,
                                                                  "extra": 5], "total_ms": 1900],
                             "gate": ["state": "trusted", "why": NSNull()]]))
        XCTAssertFalse(s.ack(["seq": 6]))
        s.tileArrived(hwWall: 100, now: 102.1)
        XCTAssertEqual(s.short, "capture→phone 2.1 s · server 1.9 s · gate trusted")
        s.tileDrawn(hwWall: 100, now: 102.2)
        XCTAssertEqual(s.short, "capture→drawn 2.2 s · server 1.9 s · gate trusted")
        XCTAssertEqual(s.detail, "ingest 120 ms → align 640 ms → mesh 900 ms → publish 1.9 s → extra 5 ms → phone 2.1 s → drawn 2.2 s · gate trusted · kf 4")
        s.tileArrived(hwWall: 100, now: 5000)                           // 81 min: a clock problem, ignored
        XCTAssertEqual(s.phoneMs ?? 0, 2100, accuracy: 0.01)
    }
}
