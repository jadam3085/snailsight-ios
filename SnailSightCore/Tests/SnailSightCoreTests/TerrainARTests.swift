import XCTest
@testable import SnailSightCore

final class TerrainARTests: XCTestCase {
    /// grid_map.bin exactly as terrain.py writes it: per layer a[::-1, ::-1].ravel(order="F").
    private func gridMapBin(_ layers: [[[Float]]], nx: Int, ny: Int) -> Data {
        var d = Data()
        for a in layers {                                       // a[ix][iy]
            for j in 0..<ny {                                   // Fortran order: i fastest
                for i in 0..<nx {
                    let v = a[nx - 1 - i][ny - 1 - j]
                    var bits = v.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { d.append(contentsOf: $0) }
                }
            }
        }
        return d
    }

    private func layer(_ nx: Int, _ ny: Int, _ f: (Int, Int) -> Float) -> [[Float]] {
        (0..<nx).map { ix in (0..<ny).map { iy in f(ix, iy) } }
    }

    func testYAMLLayers() {
        let y = """
        type: grid_map_msgs/msg/GridMap
        layers:
        - elevation
        - cost
        basic_layers:
        - elevation
        """
        XCTAssertEqual(GridMapYAML.layers(y), ["elevation", "cost"])
        XCTAssertEqual(GridMapYAML.layers("nothing"), GridMapYAML.defaultLayers)
    }

    func testParseMatchesPythonLayoutAndIndexing() {
        let nx = 5, ny = 3
        let elev = layer(nx, ny) { ix, iy in Float(ix) * 10 + Float(iy) }
        let cost = layer(nx, ny) { ix, iy in ix == 4 && iy == 0 ? .nan : Float(ix + iy) / 10 }
        let bin = gridMapBin([elev, cost], nx: nx, ny: ny)
        let g = TerrainGrid.parse(bin: bin, nx: nx, ny: ny, x0: -1, y0: 2, cell: 0.05, layerNames: ["elevation", "cost"])!
        for ix in 0..<nx { for iy in 0..<ny { XCTAssertEqual(g.value("elevation", ix: ix, iy: iy), Float(ix) * 10 + Float(iy)) } }
        XCTAssertNil(g.value("cost", ix: 4, iy: 0))
        XCTAssertEqual(g.value("cost", ix: 3, iy: 2)!, 0.5, accuracy: 1e-6)
        XCTAssertEqual(g.index(x: -1 + 0.051, y: 2.149)!.ix, 1)
        XCTAssertEqual(g.index(x: -1 + 0.051, y: 2.149)!.iy, 2)
        XCTAssertNil(g.index(x: -1.01, y: 2))
        XCTAssertNil(TerrainGrid.parse(bin: bin.prefix(10), nx: nx, ny: ny, x0: 0, y0: 0, cell: 0.05, layerNames: ["elevation", "cost"]))
    }

    func testPatchClassesBlocksAndRadius() {
        let nx = 40, ny = 40                                    // 2 m × 2 m at 5 cm
        let elev = layer(nx, ny) { _, _ in 0.0 }
        // left half free, a lethal stripe at ix 20..21, unknown top rows
        let cost = layer(nx, ny) { ix, iy in iy >= 36 ? .nan : (ix == 20 || ix == 21 ? 1.0 : (ix > 30 ? 0.6 : 0.1)) }
        let elevU = layer(nx, ny) { ix, iy in iy >= 36 ? .nan : elev[ix][iy] }
        let g = TerrainGrid.parse(bin: gridMapBin([elevU, cost], nx: nx, ny: ny), nx: nx, ny: ny, x0: 0, y0: 0,
                                  cell: 0.05, layerNames: ["elevation", "cost"])!
        let r = TerrainPatch.build(g, cx: 1, cy: 1, radius: 5, block: 2, lift: 0.03)
        XCTAssertEqual(r.cells, 20 * 18)                        // 10 cm blocks, top 2 block rows unknown
        XCTAssertEqual(r.meshes[.lethal]!.triangleCount, 2 * 18)   // ix 20..21 = one block column
        XCTAssertEqual(r.meshes[.caution]!.triangleCount, 2 * 18 * 5)   // ix 31..39 → blocks 30..38 (worst cost wins)
        XCTAssertNil(r.meshes[.hard])
        XCTAssertEqual(r.meshes[.free]!.positions[2], 0.03, accuracy: 1e-6)
        // radius
        let small = TerrainPatch.build(g, cx: 0.5, cy: 0.5, radius: 0.3)
        XCTAssertLessThan(small.cells, 40)
        XCTAssertGreaterThan(small.cells, 20)
        XCTAssertTrue(TerrainPatch.needsRebuild(last: nil, x: 0, y: 0))
        XCTAssertFalse(TerrainPatch.needsRebuild(last: [0, 0], x: 1, y: 1))
        XCTAssertTrue(TerrainPatch.needsRebuild(last: [0, 0], x: 2, y: 1))
        XCTAssertEqual(TerrainClass.of(cost: 0.95), .hard)
    }

    func testNavDocLevelChoiceAndAnswers() throws {
        let j = #"{"map_id":"site","version":10,"latest_version":10,"cell_m":0.05,"profile":{"name":"robosnailbob"},"levels":[{"level":0,"ground_z":-1.313,"bounds_xy":[-5.55,-10.85,9.45,4.35],"shape":[300,304],"grid_map":{"yaml":"/a.yaml","bin":"/a.bin"}},{"level":1,"ground_z":1.321,"bounds_xy":[-6.0,-14.85,13.0,7.2],"shape":[380,441],"grid_map":{"yaml":"/b.yaml","bin":"/b.bin"}}]}"#
        let nav = try JSONDecoder().decode(NavDoc.self, from: Data(j.utf8))
        XCTAssertEqual(nav.profileName, "robosnailbob")
        XCTAssertEqual(nav.level(x: 0, y: 0, cameraZ: 0.1)?.level, 0)       // phone 1.4 m above the basement floor
        XCTAssertEqual(nav.level(x: 0, y: 0, cameraZ: 2.7)?.level, 1)
        XCTAssertEqual(nav.level(x: 12, y: 6, cameraZ: 0.1)?.level, 1)      // only level 1 covers it
        let q = try JSONDecoder().decode(NavQueryAnswer.self, from: Data(#"{"level":0,"known":true,"slope_deg":2.4,"step_m":0.02,"traversable":true,"cost":0.1}"#.utf8))
        XCTAssertEqual(q.text, "Robot fits here · slope 2° · step 2 cm")
        let q2 = try JSONDecoder().decode(NavQueryAnswer.self, from: Data(#"{"known":true,"traversable":false,"reason":"step 0.09 m > 0.06","step_m":0.09}"#.utf8))
        XCTAssertTrue(q2.text.hasPrefix("Robot can't stand here: step"))
        let p = try JSONDecoder().decode(NavPathAnswer.self, from: Data(#"{"ok":true,"length_m":2.0,"climb_m":0.03,"max_cost":0.2,"points":[[0,0,0],[1,0,0],[1,1,0.1]]}"#.utf8))
        XCTAssertEqual(p.text, "Robot path 2.0 m · climbs 3 cm")
        let dense = p.dense(spacing: 0.25)
        XCTAssertEqual(dense.count, 9)
        XCTAssertEqual(dense.last![2], 0.1, accuracy: 1e-9)
        let bad = try JSONDecoder().decode(NavPathAnswer.self, from: Data(#"{"ok":false,"reason":"goal unreachable"}"#.utf8))
        XCTAssertEqual(bad.text, "No path for the robot: goal unreachable")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NavPathRequest(start: [0, 0, 0], goal: [1, 1]))) as! [String: Any]
        XCTAssertEqual(body["snap_m"] as? Double, 0.3)
        XCTAssertEqual(body["allow_unknown"] as? Bool, false)
    }
}
