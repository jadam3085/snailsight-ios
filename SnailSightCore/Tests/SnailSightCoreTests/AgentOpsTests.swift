import XCTest
@testable import SnailSightCore

final class AgentOpsTests: XCTestCase {
    func testControlsAvailabilityAndReasons() {
        XCTAssertEqual(AgentOpsControl.offered(drone: true).map(\.title), ["Hold", "Climb above", "Return", "Land now"])
        XCTAssertEqual(AgentOpsControl.offered(drone: false), [.hold, .returnHome])
        let none: Set<String> = []
        XCTAssertTrue(AgentOpsControl.hold.availability(drone: true, features: none, home: nil, serverSim: true).enabled)
        let ret = AgentOpsControl.returnHome.availability(drone: true, features: none, home: nil, serverSim: true)
        XCTAssertFalse(ret.enabled); XCTAssertNotNil(ret.reason)
        XCTAssertTrue(AgentOpsControl.returnHome.availability(drone: true, features: none, home: [1, 2, 0], serverSim: true).enabled)
        let climb = AgentOpsControl.climbAbove.availability(drone: true, features: none, home: nil, serverSim: true)
        XCTAssertFalse(climb.enabled); XCTAssertTrue(climb.reason?.contains("no climb order") ?? false)
        let missions: Set<String> = [AgentOpsControl.missionsFlag]
        for c in AgentOpsControl.offered(drone: true) {
            XCTAssertTrue(c.availability(drone: true, features: missions, home: nil, serverSim: true).enabled)
        }
        XCTAssertFalse(AgentOpsControl.landNow.availability(drone: false, features: missions, home: nil,
                                                            serverSim: true).enabled)
        XCTAssertFalse(AgentOpsControl.hold.availability(drone: true, features: none, home: nil, serverSim: false).enabled)
    }

    func testCommandsMapToServerOrders() {
        XCTAssertEqual(AgentOpsControl.hold.command(home: nil), .stop)
        XCTAssertEqual(AgentOpsControl.returnHome.command(home: [1, 2, 0.5]), .goal(x: 1, y: 2, z: 0.5))
        XCTAssertNil(AgentOpsControl.returnHome.command(home: nil))
        XCTAssertNil(AgentOpsControl.landNow.command(home: nil))
        let missions: Set<String> = ["drone_missions"]
        XCTAssertEqual(AgentOpsControl.landNow.command(features: missions, home: nil), .droneOp("land"))
        XCTAssertEqual(AgentOpsControl.climbAbove.command(features: missions, home: nil), .droneOp("climb_above"))
        XCTAssertEqual(AgentOpsControl.returnHome.command(drone: false, features: missions, home: [1, 2]), .goal(x: 1, y: 2, z: nil))
        let body = String(decoding: SimServerAPI.body(.droneOp("return"), agentID: "p"), as: UTF8.self)
        XCTAssertEqual(body, #"{"owner":"p","return":true}"#)
        let m = String(decoding: SimServerAPI.body(.mission(goal: [1, 2, 3], mode: "explore", canopy: "auto"), agentID: "p"),
                       as: UTF8.self)
        XCTAssertTrue(m.contains(#""mission":{"canopy":"auto","goal":[1,2,3],"mode":"explore"}"#))
    }

    func testObstacleBanner() {
        XCTAssertEqual(ObstacleBanner.make(nav: nil, event: "block", now: 5)?.title, "Obstacle sensor took over")
        XCTAssertEqual(ObstacleBanner.make(nav: nil, event: "obstacle_takeover", eventDetail: "2.1 m ahead", now: 5)?.detail,
                       "2.1 m ahead")
        XCTAssertEqual(ObstacleBanner.make(nav: SimNav(status: "no_path", reason: "stairs"), event: nil, now: 5)?.detail, "stairs")
        XCTAssertNil(ObstacleBanner.make(nav: SimNav(status: "walking"), event: nil, now: 5))
        let b = ObstacleBanner.make(nav: nil, event: "plan", now: 5)!
        XCTAssertTrue(b.visible(now: 10)); XCTAssertFalse(b.visible(now: 20))
    }

    func testAltitudeProfile() {
        let route = [[0.0, 0.0, 6.0], [4.0, 0.0, 6.0], [4.0, 3.0, 8.0]]
        let s = AltitudeProfile.sample(route: route, step: 1, ground: { x, _ in x * 0.25 }, canopy: { x, y in y > 1 ? 7.5 : nil })
        XCTAssertEqual(s.count, 8)                                           // 0…7 m
        XCTAssertEqual(s.first?.ground, 0); XCTAssertEqual(s[4].ground, 1)
        XCTAssertEqual(s.last!.body, 8, accuracy: 1e-9)
        XCTAssertEqual(AltitudeProfile.length(route), 7, accuracy: 1e-9)
        let c = AltitudeProfile.minClearance(s)!
        XCTAssertLessThan(c, 1)                                              // canopy 7.5 under a 6.67 m pass
    }

    func testTerrainClassifyAndRaster() {
        XCTAssertEqual(TerrainPlanRaster.classify(slopeDeg: 5, cost: 0.1, unknown: 0), .ground)
        XCTAssertEqual(TerrainPlanRaster.classify(slopeDeg: 20, cost: 0.1, unknown: 0), .noGo)
        XCTAssertEqual(TerrainPlanRaster.classify(slopeDeg: 5, cost: 1, unknown: 0), .noGo)
        XCTAssertEqual(TerrainPlanRaster.classify(slopeDeg: 5, cost: 0.5, unknown: 0), .caution)
        XCTAssertEqual(TerrainPlanRaster.classify(slopeDeg: nil, cost: nil, unknown: nil), .unknown)
        XCTAssertEqual(TerrainPlanRaster.classify(slopeDeg: 3, cost: 0.1, unknown: 1), .unknown)
        XCTAssertGreaterThan(TerrainPlanRaster.shade(slopeDeg: 0), TerrainPlanRaster.shade(slopeDeg: 30))
        // 4 × 2 grid: left half measured flat, (2,0) steep, right column unknown (NaN)
        let nx = 4, ny = 2
        var slope = [Float](repeating: .nan, count: nx * ny), cost = slope, elev = slope
        for ix in 0..<3 { for iy in 0..<ny { slope[ix * ny + iy] = 2; cost[ix * ny + iy] = 0.1; elev[ix * ny + iy] = 0 } }
        slope[2 * ny + 0] = 25
        let g = TerrainGrid(nx: nx, ny: ny, x0: 0, y0: 0, cell: 0.5, layers: ["slope": slope, "cost": cost, "elevation": elev])
        let r = TerrainPlanRaster.build(g)
        XCTAssertEqual(r.surveyed, 6); XCTAssertEqual(r.unknown, 2); XCTAssertEqual(r.noGo, 1)
        XCTAssertEqual(r.rgba.count, nx * ny * 4)
        XCTAssertEqual(r.rgba[(1 * nx + 3) * 4 + 3], 0)                      // unknown = transparent (the view hatches it)
        XCTAssertEqual(r.rgba[(1 * nx + 2) * 4], 231)                         // (2, iy 0) = image row 1: no-go amber
        XCTAssertEqual(r.surveyedFrac, 0.75, accuracy: 1e-9)
        XCTAssertEqual(TerrainPlanRaster.unknownMask(g).filter { $0 }.count, 2)
    }

    func testGapFinderPicksLargestBorderedGap() {
        // 10 × 10: left 4 columns known, a 6 × 10 unknown block on the right
        let nx = 10, ny = 10
        var unknown = [Bool](repeating: false, count: nx * ny), known = unknown
        for iy in 0..<ny { for ix in 0..<nx { if ix < 4 { known[iy * nx + ix] = true } else { unknown[iy * nx + ix] = true } } }
        let g = GapFinder.find(nx: nx, ny: ny, x0: 0, y0: 0, cell: 1, unknown: unknown, known: known)!
        XCTAssertEqual(g.cells, 60)
        XCTAssertEqual(g.center[0], 7, accuracy: 1e-9)
        XCTAssertEqual(g.approach[0], 3.5, accuracy: 1e-9)                    // the known column next to it
        XCTAssertNil(GapFinder.find(nx: nx, ny: ny, x0: 0, y0: 0, cell: 1, unknown: unknown, known: known, minCells: 100))
    }
}
