import XCTest
@testable import SnailSightCore

final class LocPillTests: XCTestCase {
    func testLockedMeshPill() {
        let s = LocPill.make(LocPillInput(online: true, phase: .locked, mapID: "site", version: 10, method: "visual+mesh",
                                          source: "server", errCm: 1.6, lastFixAge: 4))
        XCTAssertEqual(s.tone, .good)
        XCTAssertEqual(s.text, "LOCALIZED · whole house v10 · geometry+visual · ±2 cm")
        XCTAssertTrue(s.rows.contains("Method: geometry + visual (LiDAR on the house mesh, photo match agrees)"))
        XCTAssertTrue(s.rows.contains("Last fix: 4 s ago"))
        XCTAssertTrue(s.rows.contains("Error estimate: ±2 cm"))
    }

    func testGeometryLockAndHint() {
        // 10.4: a lock from the whole-map geometry search alone (night walk: no visual inliers)
        let g = LocPill.make(LocPillInput(online: true, phase: .locked, version: 12, method: "geometry", source: "server",
                                          errCm: 1.8))
        XCTAssertEqual(g.text, "LOCALIZED · whole house v12 · geometry · ±2 cm")
        XCTAssertTrue(g.rows.contains("Method: geometry (LiDAR on the house mesh, works in the dark)"))
        XCTAssertEqual(LocPill.errorEstimate(spreadCm: 0.5, rmseCm: nil, method: "geometry", source: "server"), 2)
        XCTAssertEqual(LocPill.errorEstimate(spreadCm: 0.5, rmseCm: nil, method: "both", source: "server"), 2)
        XCTAssertEqual(LocMethod.label("mesh-global"), "geometry")
        XCTAssertEqual(LocMethod.label("both"), "geometry+visual")
        XCTAssertEqual(LocMethod.label(nil), "visual")
        let f = LocPill.make(LocPillInput(online: true, phase: .searching, searchSeconds: 6, attempts: 5,
                                          hint: "Turn to see a corner of the room"))
        XCTAssertTrue(f.rows.contains("Tip: Turn to see a corner of the room"))
        XCTAssertEqual(MapLocText.searching(mapID: "site", seconds: 6, attempts: 6, matches: 0, hint: "Turn to see a corner of the room"),
                       "Finding you in the whole house map · 6 s · Turn to see a corner of the room")
    }

    func testLockedVisualAndCached() {
        let v = LocPill.make(LocPillInput(online: true, phase: .locked, version: 10, method: "visual", source: "server",
                                          errCm: 3))
        XCTAssertEqual(v.text, "LOCALIZED · whole house v10 · visual · ±3 cm")
        let c = LocPill.make(LocPillInput(online: false, phase: .locked, version: 9, source: "place_cache", errCm: 5))
        XCTAssertEqual(c.tone, .good)                                   // a lock survives the server going away
        XCTAssertEqual(c.text, "LOCALIZED · whole house v9 · saved place · ±5 cm")
        XCTAssertTrue(c.rows.contains { $0.hasPrefix("Server offline") })
    }

    func testSearchingOfflineNotInMap() {
        let f = LocPill.make(LocPillInput(online: true, phase: .searching, searchSeconds: 12.4, attempts: 9, matches: 1))
        XCTAssertEqual(f.tone, .working)
        XCTAssertEqual(f.text, "FINDING YOU… 12 s")
        let o = LocPill.make(LocPillInput(online: false, phase: .searching, searchSeconds: 3))
        XCTAssertEqual(o.tone, .idle)
        XCTAssertEqual(o.text, "OFFLINE")
        let n = LocPill.make(LocPillInput(online: true, phase: .searching, searchSeconds: 50, attempts: 30, notInMap: true))
        XCTAssertEqual(n.tone, .idle)
        XCTAssertEqual(n.text, "NOT IN MAP")
    }

    func testNotInMapRule() {
        XCTAssertFalse(LocPill.notInMap(searchSeconds: 60, attempts: 40, matches: 1))     // a match = not lost
        XCTAssertFalse(LocPill.notInMap(searchSeconds: 20, attempts: 40, matches: 0))     // too early
        XCTAssertFalse(LocPill.notInMap(searchSeconds: 60, attempts: 10, matches: 0))     // too few tries (offline gaps)
        XCTAssertTrue(LocPill.notInMap(searchSeconds: 46, attempts: 25, matches: 0))
    }

    func testErrorEstimate() {
        XCTAssertEqual(LocPill.errorEstimate(spreadCm: 0.8, rmseCm: 1.4, method: "visual+mesh", source: "server"), 2)
        XCTAssertEqual(LocPill.errorEstimate(spreadCm: 4.2, rmseCm: 1.4, method: "visual+mesh", source: "server"), 4.2)
        XCTAssertEqual(LocPill.errorEstimate(spreadCm: 0.5, rmseCm: nil, method: "visual", source: "server"), 3)
        XCTAssertEqual(LocPill.errorEstimate(spreadCm: nil, rmseCm: nil, method: nil, source: "place_cache"), 5)
        XCTAssertNil(LocPill.errorEstimate(spreadCm: 1, rmseCm: 1, method: nil, source: ""))
        XCTAssertEqual(LocPill.cm(4.2), "±5 cm")
        XCTAssertEqual(LocPill.cm(0.2), "±1 cm")
    }

    func testCadence() {
        // fast until locked, slower while recording / hot, slow retry when not in the map
        XCTAssertEqual(LocCadence.interval(locked: false, refinements: 0, thermalSerious: false, recording: false, notInMap: false), 1)
        XCTAssertEqual(LocCadence.interval(locked: false, refinements: 0, thermalSerious: false, recording: true, notInMap: false), 2)
        XCTAssertEqual(LocCadence.interval(locked: false, refinements: 0, thermalSerious: true, recording: false, notInMap: false), 3)
        XCTAssertEqual(LocCadence.interval(locked: false, refinements: 0, thermalSerious: false, recording: false, notInMap: true), 6)
        // 11.1: the first 20 s of a search go at 0.5 s (never while recording / hot / not in map)
        XCTAssertEqual(LocCadence.interval(locked: false, refinements: 0, thermalSerious: false, recording: false, notInMap: false,
                                           searchSeconds: 3), 0.5)
        XCTAssertEqual(LocCadence.interval(locked: false, refinements: 0, thermalSerious: false, recording: false, notInMap: false,
                                           searchSeconds: 25), 1)
        XCTAssertEqual(LocCadence.interval(locked: false, refinements: 0, thermalSerious: false, recording: true, notInMap: false,
                                           searchSeconds: 3), 2)
        XCTAssertEqual(LocCadence.interval(locked: true, refinements: 3, thermalSerious: false, recording: false, notInMap: false,
                                           searchSeconds: 3), 8)
        // refinements, then an occasional refresh (never "stop": the pill must stay truthful)
        XCTAssertEqual(LocCadence.interval(locked: true, refinements: 3, thermalSerious: false, recording: false, notInMap: false), 8)
        XCTAssertEqual(LocCadence.interval(locked: true, refinements: 12, thermalSerious: false, recording: false, notInMap: false), 60)
        XCTAssertEqual(LocCadence.interval(locked: true, refinements: 3, thermalSerious: true, recording: false, notInMap: false), 180)
        // depth: always while searching / refining; between refreshes only shortly before the next one
        XCTAssertTrue(LocCadence.depthNeeded(locked: false, refinements: 0, sinceLastAttempt: 0, thermalSerious: false, recording: false))
        XCTAssertTrue(LocCadence.depthNeeded(locked: true, refinements: 2, sinceLastAttempt: 0, thermalSerious: false, recording: false))
        XCTAssertFalse(LocCadence.depthNeeded(locked: true, refinements: 12, sinceLastAttempt: 10, thermalSerious: false, recording: false))
        XCTAssertTrue(LocCadence.depthNeeded(locked: true, refinements: 12, sinceLastAttempt: 58, thermalSerious: false, recording: false))
    }

    func testAnswerIcpFields() throws {
        let json = """
        {"ok":true,"map_id":"site","map_version":10,"locked":true,"events":["refined"],"method":"visual+mesh",
         "lock_method":"visual+mesh","gate":{"locked":true,"spread_cm":0.9},
         "frames":[{"node":12,"inliers":80,"accepted":true,"method":"visual+mesh",
                    "icp":{"ok":true,"fitness":0.81,"rmse_cm":1.42,"cond":0.2}},
                   {"node":0,"inliers":0,"accepted":false,"icp":{"ok":false,"reason":"degenerate","rmse_cm":0.9}}],
         "T_map_arkit":[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1]}
        """
        let a = try JSONDecoder().decode(LocalizeAnswer.self, from: Data(json.utf8))
        XCTAssertTrue(a.anyAccepted)
        XCTAssertEqual(a.bestRmseCm, 1.42)                  // the refused ICP does not count
        XCTAssertEqual(a.frames.first?.method, "visual+mesh")
    }

    func testAnswerTimingAndLockRule() throws {
        let json = """
        {"ok":true,"map_id":"site","map_version":14,"locked":true,"events":["locked"],"lock_rule":"strong",
         "timing_ms":{"prepare":8.1,"visual":352.0,"icp":171.5,"gsearch":0.4,"mesh":0,"total":540.2,
                      "native":{"posterior":150.2,"memory_update":98.0}},
         "frames":[{"node":12,"inliers":120,"accepted":true,"method":"visual+mesh"}]}
        """
        let a = try JSONDecoder().decode(LocalizeAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(a.lockRule, "strong")
        XCTAssertEqual(a.timingMs?.visual, 352.0)
        XCTAssertEqual(a.timingMs?.icp, 171.5)
        XCTAssertEqual(a.timingMs?.total, 540.2)
    }
}
