import XCTest
@testable import SnailSightCore

/// 12.0 "Mesh (live)": the downlink tile-apply path the app runs for every tile (LiveDownMessage → LiveTileStore.accept →
/// LiveMeshTile.decode → LiveMeshFeed.apply → TilePlanRaster), on a real tile captured from the live service.
final class LiveMeshFeedTests: XCTestCase {
    /// A real `tile` message from `snailsight-live` 0.4.1 (replay agent on an unanchored test map, 2026-10-18).
    static let realTile = #"{"type": "tile", "layer": "mesh", "key": "0/1/-2", "level": 0, "tx": 1, "ty": -2, "ver": {"base_version": 0, "live_seq": 114}, "enc": "f32", "origin": [4.0, -8.0, -1.35], "size_m": 4.0, "z_range": [null, null], "hw": {"replay-x/ar-b275e23e": 63}, "hw_wall": 1792340171.042, "keyframes": 2, "vertices": 5, "triangles": 3, "data": "BQAAAAMAAAAAAIBAnu/rwGdmxr8AAIBAzczswFTjxb9iEIBAMzPrwGdmxr9qvIBAzczswAAAwL9/aoBAMzPrwAAAwL8CAAAAAAAAAAEAAAADAAAAAgAAAAEAAAAEAAAAAgAAAAMAAAA="}"#

    func testRealTileDecodesThroughTheAppPath() throws {
        let d = Data(Self.realTile.utf8)
        guard case .tile(let layer, let key, let ver, let enc, let data)? = LiveDownMessage.parse(d) else {
            return XCTFail("not a tile")
        }
        XCTAssertEqual(layer, "mesh"); XCTAssertEqual(key, "0/1/-2"); XCTAssertEqual(ver, TileVer(base: 0, seq: 114))
        let m = try XCTUnwrap(LiveMeshTile.decode(enc: enc, base64: data))
        XCTAssertEqual(m.vertexCount, 5); XCTAssertEqual(m.triangleCount, 3)
        let h = try XCTUnwrap(LiveTileHeader.parse(d))
        XCTAssertEqual(h.levelIndex, 0)
        XCTAssertEqual(h.agents, ["replay-x"])
        XCTAssertEqual(h.square, [4, -8, 8, -4])
        for i in stride(from: 0, to: m.positions.count, by: 3) {          // every vertex inside the tile (± a voxel)
            XCTAssertGreaterThanOrEqual(Double(m.positions[i]), 4 - 0.05)
            XCTAssertLessThanOrEqual(Double(m.positions[i]), 8 + 0.05)
        }
        XCTAssertNil(LiveTileHeader.parse(Data(#"{"type":"agent","agent_id":"x"}"#.utf8)))
    }

    /// 12.1: a coloured tile exactly as `snailsight-live` 0.5 sends it on the json transport (livetiles.encode_colour ->
    /// livepub.tile_json; 6-bit colour bins).
    static let colourTile = #"{"type": "tile", "layer": "mesh", "key": "0/1/-2", "level": 0, "tx": 1, "ty": -2, "ver": {"base_version": 0, "live_seq": 7}, "origin": [4.0, -8.0, -1.35], "size_m": 4.0, "hw": {"replay-col/ar-1": 9}, "vertices": 5, "triangles": 3, "colour": "rgb8", "enc": "f32", "data": "BQAAAAMAAAAAAIBACtfrwGdmxr8AAIBAzczswJDCxb9iEIBAMzPrwGdmxr9qvIBAzczswAAAwL9/aoBAMzPrwAAAwL8CAAAAAAAAAAEAAAADAAAAAgAAAAEAAAAEAAAAAgAAAAMAAAA=", "rgb": "yraiyraeHj5aZmZm+goK"}"#

    func testColourTileDecodesToFaceStripAndPlanColours() throws {
        let d = Data(Self.colourTile.utf8)
        guard case .tile(_, _, _, let enc, let data)? = LiveDownMessage.parse(d) else { return XCTFail("not a tile") }
        let m = try XCTUnwrap(LiveMeshTile.decode(enc: enc, base64: data))
        let h = try XCTUnwrap(LiveTileHeader.parse(d))
        XCTAssertEqual(h.colour, "rgb8")
        let rgb = try XCTUnwrap(LiveMeshTile.decodeColour(base64: h.rgb, vertexCount: m.vertexCount))
        XCTAssertEqual(rgb, [202, 182, 162, 202, 182, 158, 30, 62, 90, 102, 102, 102, 250, 10, 10])
        XCTAssertNil(LiveMeshTile.decodeColour(base64: h.rgb, vertexCount: 4))          // wrong length = untinted
        XCTAssertNil(LiveMeshTile.decodeColour(base64: nil, vertexCount: 5))
        // face colour = mean of its vertices; triangle 0 = (2, 0, 1)
        let fc = LiveMeshTile.faceColours(m, rgb: rgb)
        XCTAssertEqual(Array(fc[0..<3]), [UInt8((30 + 202 + 202) / 3), UInt8((62 + 182 + 182) / 3), UInt8((90 + 162 + 158) / 3)])
        let ft = try XCTUnwrap(LiveMeshTile.faceTextured(m, rgb: rgb))
        XCTAssertEqual(ft.width, 3); XCTAssertEqual(ft.rows, 1)
        XCTAssertEqual(ft.positions.count, 27); XCTAssertEqual(ft.indices, (0..<9).map { UInt32($0) }); XCTAssertEqual(ft.uvs.count, 18)
        XCTAssertEqual(ft.uvs[0], 0.5 / 3, accuracy: 1e-6); XCTAssertEqual(ft.uvs[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(ft.uvs[6], 1.5 / 3, accuracy: 1e-6)                             // triangle 1 -> texel 1
        XCTAssertEqual(ft.uvs[12], 2.5 / 3, accuracy: 1e-6)
        XCTAssertEqual(Array(ft.rgba[0..<4]), Array(fc[0..<3]) + [255])
        XCTAssertEqual(Array(ft.positions[0..<3]), Array(m.positions[6..<9]))         // vertex 2 first
        // the Map: every non-empty plan cell has a photo colour
        let px = TilePlanRaster.rasterRGBA(m, faceRGB: fc, square: try XCTUnwrap(h.square), floorZ: -1.35, n: 40)
        XCTAssertEqual(px.count, 40 * 40 * 4)
        let lit = stride(from: 3, to: px.count, by: 4).filter { px[$0] == 255 }
        XCTAssertFalse(lit.isEmpty)
        XCTAssertTrue(TilePlanRaster.rasterRGBA(m, faceRGB: [1, 2], square: [0, 0, 4, 4], floorZ: nil).allSatisfy { $0 == 0 })
    }

    func testApplyNewThenInPlaceUpdateAndFreshness() {
        var f = LiveMeshFeed()
        var h = LiveTileHeader(layer: "mesh", key: "1/0/0", level: 1, ver: TileVer(base: 14, seq: 3),
                               origin: [0, 0, 1.36], hw: ["phone-a/ar-1": 4])
        XCTAssertEqual(f.apply(h, triangles: 100, floorZ: 1.36, me: "phone-a", now: 100), .new)
        XCTAssertEqual(f.step(key: "1/0/0", now: 100), 2)
        XCTAssertEqual(f.step(key: "1/0/0", now: 103), 1)
        XCTAssertEqual(f.step(key: "1/0/0", now: 107), 0)
        h.ver = TileVer(base: 14, seq: 9)
        h.hw = ["replay-x/ar-9": 2]
        XCTAssertEqual(f.apply(h, triangles: 140, floorZ: 1.36, me: "phone-a", now: 110), .updated)
        let t = f.tiles["live|1/0/0"]!
        XCTAssertEqual(t.updates, 1)
        XCTAssertEqual(t.triangles, 140)
        XCTAssertEqual(t.agents, ["phone-a", "replay-x"])
        XCTAssertTrue(t.mine)
        XCTAssertEqual(t.arrivedAt, 100); XCTAssertEqual(t.changedAt, 110)
        XCTAssertEqual(f.step(key: "1/0/0", now: 110.5), 2)                  // the update glows again
        XCTAssertEqual(f.liveCount, 1); XCTAssertEqual(f.mineCount, 1)
        XCTAssertEqual(f.live(level: 1).count, 1); XCTAssertEqual(f.live(level: 0).count, 0)
        XCTAssertTrue(f.summary(now: 111, me: "phone-a").contains("1 tile (1 yours) · 1 other agent"))
    }

    func testBaseSwapsShareTheHighlight() {
        var f = LiveMeshFeed()
        f.noteBase(key: "L1/3/4", square: [12, 16, 16, 20], level: 1, now: 50)
        XCTAssertEqual(f.step(key: "L1/3/4", source: .base, now: 50), 2)
        XCTAssertEqual(f.fresh(now: 51).map(\.key), ["L1/3/4"])
        XCTAssertTrue(f.fresh(now: 60).isEmpty)
        f.noteBase(key: "L1/3/4", square: nil, level: 1, now: 70)
        XCTAssertEqual(f.tiles["base|L1/3/4"]?.updates, 2)
        XCTAssertEqual(f.liveCount, 0)
    }

    func testStoreRejectsOlderAndSameVersionsSoNothingFlickers() {
        var s = LiveTileStore()
        XCTAssertTrue(s.accept(layer: "mesh", key: "0/0/0", ver: TileVer(base: 0, seq: 5)))
        XCTAssertFalse(s.accept(layer: "mesh", key: "0/0/0", ver: TileVer(base: 0, seq: 5)))
        XCTAssertFalse(s.accept(layer: "mesh", key: "0/0/0", ver: TileVer(base: 0, seq: 4)))
        XCTAssertTrue(s.accept(layer: "mesh", key: "0/0/0", ver: TileVer(base: 1, seq: 0)))   // a rebase re-fuse
    }

    func testPlanRasterClassesFloorWallRaised() {
        // floor quad at z = 0 over [0,1]², a wall at x = 2 (vertical), a table top at z = 0.7 over [3,3.5]²
        var p: [Float] = []
        var idx: [UInt32] = []
        func quad(_ a: [Float], _ b: [Float], _ c: [Float], _ d: [Float]) {
            let o = UInt32(p.count / 3)
            p += a + b + c + d
            idx += [o, o + 1, o + 2, o, o + 2, o + 3]
        }
        quad([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
        quad([2, 0, 0], [2, 1, 0], [2, 1, 1], [2, 0, 1])
        quad([3, 3, 0.7], [3.5, 3, 0.7], [3.5, 3.5, 0.7], [3, 3.5, 0.7])
        let r = TilePlanRaster.raster(FlatMesh(positions: p, indices: idx), square: [0, 0, 4, 4], floorZ: 0, n: 40)
        XCTAssertEqual(r.count, 1600)
        XCTAssertEqual(r[5 * 40 + 5], TilePlanRaster.floor)
        XCTAssertEqual(r[5 * 40 + 20], TilePlanRaster.wall)
        XCTAssertEqual(r[32 * 40 + 32], TilePlanRaster.raised)
        XCTAssertEqual(r[38 * 40 + 1], TilePlanRaster.empty)
        XCTAssertGreaterThan(TilePlanRaster.coverage(r), 0.05)
    }

    /// Replays a downlink capture from `app_downlink_sim.py` (SNAILSIGHT_DOWNLINK_REPLAY = path to its JSONL) through
    /// the app's exact apply path; skipped without one (CI).
    func testReplayCapturedDownlink() throws {
        guard let path = ProcessInfo.processInfo.environment["SNAILSIGHT_DOWNLINK_REPLAY"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("SNAILSIGHT_DOWNLINK_REPLAY not set")
        }
        var store = LiveTileStore()
        var feed = LiveMeshFeed()
        var accepted = 0, rejected = 0, decoded = 0, updates = 0, triangles = 0, covered = 0
        var levels: [Int: Double] = [:]
        for line in text.split(separator: "\n") {
            let d = Data(line.utf8)
            guard let (m, _) = LiveDownMessage.parseWithSeq(d) else { continue }
            if case .head = m, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let ls = o["levels"] as? [[String: Any]] {
                for l in ls { if let i = l["level"] as? Int, let z = l["floor_z"] as? Double { levels[i] = z } }
            }
            guard case .tile(let l, let key, let ver, let enc, let data) = m, l == "mesh" else { continue }
            guard store.accept(layer: l, key: key, ver: ver) else { rejected += 1; continue }
            accepted += 1
            guard let mesh = LiveMeshTile.decode(enc: enc, base64: data), let h = LiveTileHeader.parse(d) else { continue }
            decoded += 1
            triangles += mesh.triangleCount
            if feed.apply(h, triangles: mesh.triangleCount, floorZ: levels[h.levelIndex], me: "phone-uisim",
                          now: Double(accepted)) == .updated { updates += 1 }
            if let sq = h.square, mesh.triangleCount > 0,
               TilePlanRaster.coverage(TilePlanRaster.raster(mesh, square: sq, floorZ: levels[h.levelIndex])) > 0 { covered += 1 }
        }
        print("DOWNLINK_REPLAY accepted=\(accepted) rejected=\(rejected) decoded=\(decoded) tiles=\(feed.liveCount) "
              + "in_place_updates=\(updates) triangles=\(triangles) rastered_nonempty=\(covered) agents=\(feed.otherAgents)")
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertEqual(decoded, accepted)                                    // every accepted tile decodes
        XCTAssertGreaterThan(feed.liveCount, 0)
    }
}


final class LiveOverBaseTests: XCTestCase {
    func testCoveredLeavesAndShowLive() {
        let cov = LiveOverBase.coveredLeaves(["1/0/-1", "0/8/1/1", "2/bad", "0/1000/0/0"])
        XCTAssertTrue(cov.contains("1/0/-1"))
        for k in ["0/2/2", "0/3/2", "0/2/3", "0/3/3"] { XCTAssertTrue(cov.contains(k), k) }     // 8 m parent (1, 1)
        XCTAssertFalse(cov.contains("0/1/1"))
        XCTAssertEqual(cov.count, 5)                                                            // oversized parent ignored
        XCTAssertTrue(LiveOverBase.showLive(key: "0/9/9", covered: cov, changeCentres: []))    // new territory
        XCTAssertFalse(LiveOverBase.showLive(key: "1/0/-1", covered: cov, changeCentres: []))  // base drawn there
        XCTAssertTrue(LiveOverBase.showLive(key: "1/0/-1", covered: cov, changeCentres: [[1.5, -2.0, 0.3]]))  // a change
        XCTAssertFalse(LiveOverBase.showLive(key: "1/0/-1", covered: cov, changeCentres: [[4.5, -2.0, 0.3]]))
    }
}
