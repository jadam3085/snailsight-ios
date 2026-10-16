import XCTest
@testable import SnailSightCore

/// 10.3 master-map-first localization: the saved-place accelerator state machine, evidence, lock carry, migration and
/// the single status pill.
final class PlaceAssistTests: XCTestCase {
    // MARK: state machine

    func testCleanLaunchNeverTriesWithoutEvidence() {
        var a = PlaceAssist()
        a.reset(now: 0)
        XCTAssertEqual(a.phase, .clean)
        XCTAssertFalse(a.wantsEvidence(now: 4.9, serverLocked: false))         // the server gets its 5 s first
        XCTAssertEqual(a.tick(now: 4.9, serverLocked: false, evidence: "bed"), .none)
        XCTAssertEqual(a.tick(now: 30, serverLocked: false, evidence: nil), .none)   // no evidence: stay clean
        XCTAssertEqual(a.phase, .clean)
    }

    func testServerLockWithinGraceMeansNoTry() {
        var a = PlaceAssist()
        a.reset(now: 0)
        XCTAssertFalse(a.wantsEvidence(now: 6, serverLocked: true))
        XCTAssertEqual(a.tick(now: 6, serverLocked: true, evidence: "bed"), .none)
        XCTAssertEqual(a.serverLock(now: 6), .none)                              // nothing to cancel
        XCTAssertEqual(a.phase, .clean)
    }

    func testEvidenceTriesOnceThenAbortsAfterTimeout() {
        var a = PlaceAssist()
        a.reset(now: 0)
        XCTAssertTrue(a.wantsEvidence(now: 5, serverLocked: false))
        XCTAssertEqual(a.tick(now: 5, serverLocked: false, evidence: "bed"), .tryPlace("bed"))
        XCTAssertTrue(a.isTrying)
        a.runStarted(now: 6)                                                     // the map file took 1 s to load
        XCTAssertEqual(a.tracking("limited:relocalizing", now: 7), .none)
        XCTAssertTrue(a.sawRelocalizing)
        XCTAssertEqual(a.tick(now: 13.9, serverLocked: false, evidence: "bed"), .none)
        XCTAssertEqual(a.tick(now: 14, serverLocked: false, evidence: "bed"),
                       .abort(place: "bed", reason: "timeout", keepLock: false))
        XCTAssertEqual(a.phase, .clean)
        // tried once this session: the same evidence does not loop the session through resets
        XCTAssertEqual(a.tick(now: 30, serverLocked: false, evidence: "bed"), .none)
        // another place can still be tried
        XCTAssertEqual(a.tick(now: 30, serverLocked: false, evidence: "hall"), .tryPlace("hall"))
    }

    func testServerLockCancelsRelocalizationAndKeepsTheLock() {
        var a = PlaceAssist()
        a.reset(now: 0)
        _ = a.tick(now: 5, serverLocked: false, evidence: "bed")
        XCTAssertEqual(a.tracking("limited:relocalizing", now: 6), .none)
        XCTAssertEqual(a.serverLock(now: 7), .abort(place: "bed", reason: "server_locked", keepLock: true))
        XCTAssertEqual(a.phase, .clean)
        XCTAssertEqual(a.tracking("normal", now: 8), .none)                     // the old map can no longer "match"
    }

    func testMissedLockEventStillCancelsOnTick() {
        var a = PlaceAssist()
        a.reset(now: 0)
        _ = a.tick(now: 5, serverLocked: false, evidence: "bed")
        XCTAssertEqual(a.tick(now: 6, serverLocked: true, evidence: nil),
                       .abort(place: "bed", reason: "server_locked", keepLock: true))
    }

    func testMatchRestoresAndIsStable() {
        var a = PlaceAssist()
        a.reset(now: 0)
        _ = a.tick(now: 5, serverLocked: false, evidence: "bed")
        XCTAssertEqual(a.tracking("normal", now: 5.2), .none)                   // too early to trust
        XCTAssertEqual(a.tracking("normal", now: 8), .matched(place: "bed", seconds: 3))
        XCTAssertTrue(a.isMatched)
        XCTAssertEqual(a.serverLock(now: 9), .none)                              // matched: the lock just confirms
        XCTAssertEqual(a.tick(now: 100, serverLocked: true, evidence: "bed"), .none)
    }

    func testPickGetsLongerTimeoutAndIsRefusedWhileLocked() {
        var a = PlaceAssist()
        a.reset(now: 0)
        XCTAssertEqual(a.pick("bed", now: 1, serverLocked: true), .none)       // locked on the house map already
        XCTAssertEqual(a.phase, .clean)
        XCTAssertEqual(a.pick("bed", now: 1, serverLocked: false), .tryPlace("bed"))
        XCTAssertTrue(a.isPicked)
        XCTAssertEqual(a.tick(now: 10, serverLocked: false, evidence: nil), .none)   // 8 s is for automatic tries
        XCTAssertEqual(a.tick(now: 21, serverLocked: false, evidence: nil),
                       .abort(place: "bed", reason: "timeout", keepLock: false))
        // a picked try is cancelled by the server lock too
        _ = a.pick("hall", now: 30, serverLocked: false)
        XCTAssertEqual(a.serverLock(now: 31), .abort(place: "hall", reason: "server_locked", keepLock: true))
    }

    func testCancelAndReset() {
        var a = PlaceAssist()
        a.reset(now: 0)
        XCTAssertEqual(a.cancel(now: 1), .none)                                  // nothing to cancel (grace restarts)
        XCTAssertEqual(a.tick(now: 5, serverLocked: false, evidence: "bed"), .none)
        XCTAssertEqual(a.tick(now: 6, serverLocked: false, evidence: "bed"), .tryPlace("bed"))
        XCTAssertEqual(a.cancel(now: 6), .abort(place: "bed", reason: "cancelled", keepLock: false))
        XCTAssertEqual(a.tick(now: 20, serverLocked: false, evidence: "bed"), .none)  // tried this session
        a.reset(now: 50)                                                         // Reset AR: everything may be tried again
        XCTAssertEqual(a.tick(now: 55, serverLocked: false, evidence: "bed"), .tryPlace("bed"))
    }

    // MARK: evidence

    private func place(_ id: String, center: [Double], extent: [Double], used: Double = 0) -> PlaceManifest {
        var p = PlaceManifest(id: id, name: id, now: used)
        p.mapBytes = 1000
        p.mapCenter = center
        p.mapExtent = extent
        return p
    }

    /// map ← ARKit for a y-up ARKit frame into the z-up map, plus an offset: map = (x, -z, y) + o.
    private func align(_ o: [Double], version: Int = 10) -> MapAlignment {
        MapAlignment(mapID: "site", version: version,
                     T: Mat4([1, 0, 0, o[0], 0, 0, -1, o[1], 0, 1, 0, o[2], 0, 0, 0, 1]), at: 0)
    }

    func testEvidenceIsTheRoomYouAreIn() {
        let bed = place("bed", center: [0, 0, 0], extent: [4, 2.5, 4])
        let bath = place("bath", center: [0, 0, 0], extent: [2, 2.5, 2])
        // both places' ARKit frames: bed origin at map (0,0,0), bath origin at map (10,0,0)
        let als = ["bed": align([0, 0, 0]), "bath": align([10, 0, 0])]
        let inBath = LastMapFix(mapID: "site", position: [10.5, -0.5, 1.4], at: 1000)
        XCTAssertEqual(PlaceEvidence.candidate(places: [bed, bath], alignments: als, fix: inBath, now: 1100), "bath")
        let inBed = LastMapFix(mapID: "site", position: [1, 1, 1.4], at: 1000)
        XCTAssertEqual(PlaceEvidence.candidate(places: [bed, bath], alignments: als, fix: inBed, now: 1100), "bed")
        let hall = LastMapFix(mapID: "site", position: [5, 0, 1.4], at: 1000)
        XCTAssertNil(PlaceEvidence.candidate(places: [bed, bath], alignments: als, fix: hall, now: 1100))
        // stale fix, other map, no alignment, other floor
        XCTAssertNil(PlaceEvidence.candidate(places: [bed, bath], alignments: als, fix: inBed, now: 1000 + 7 * 3600))
        XCTAssertNil(PlaceEvidence.candidate(places: [bed], alignments: als,
                                             fix: LastMapFix(mapID: "garage", position: [1, 1, 1.4], at: 1000), now: 1100))
        XCTAssertNil(PlaceEvidence.candidate(places: [bed], alignments: [:], fix: inBed, now: 1100))
        XCTAssertNil(PlaceEvidence.candidate(places: [bed], alignments: als,
                                             fix: LastMapFix(mapID: "site", position: [1, 1, 5.0], at: 1000), now: 1100))
    }

    func testEvidencePrefersTheSmallerRoom() {
        let house = place("house", center: [0, 0, 0], extent: [20, 2.5, 20])
        let bath = place("bath", center: [0, 0, 0], extent: [2, 2.5, 2])
        let als = ["house": align([0, 0, 0]), "bath": align([0, 0, 0])]
        let fix = LastMapFix(mapID: "site", position: [0.2, 0.2, 1.4], at: 0)
        XCTAssertEqual(PlaceEvidence.candidate(places: [house, bath], alignments: als, fix: fix, now: 10), "bath")
    }

    // MARK: lock carry

    private func pose(yaw: Double, _ t: [Double]) -> Mat4 {
        let c = cos(yaw), s = sin(yaw)
        return Mat4([c, 0, s, t[0], 0, 1, 0, t[1], -s, 0, c, t[2], 0, 0, 0, 1])
    }

    func testCarryKeepsTheMapPositionOfTheCamera() {
        let al = align([3, 4, 0])
        let oldCam = pose(yaw: 0.7, [1.2, 1.4, -2.0])
        let newCam = pose(yaw: 0.05, [0.01, 0.0, 0.02])             // the new frame starts at the phone
        let carried = FrameCarry.carry(al, oldCam: oldCam, newCam: newCam, now: 5)
        XCTAssertEqual(carried.at, 5)
        // the camera (and anything near it) maps to the same map point through either frame
        let a = al.toMap(arkit: oldCam.translation), b = carried.toMap(arkit: newCam.translation)
        for k in 0..<3 { XCTAssertEqual(a[k], b[k], accuracy: 1e-9) }
        // a point 2 m in front of the camera too (yaw carried)
        let fwdOld = (oldCam * pose(yaw: 0, [0, 0, -2])).translation
        let fwdNew = (newCam * pose(yaw: 0, [0, 0, -2])).translation
        let p = al.toMap(arkit: fwdOld), q = carried.toMap(arkit: fwdNew)
        for k in 0..<3 { XCTAssertEqual(p[k], q[k], accuracy: 1e-9) }
        XCTAssertEqual(carried.tiltDeg, al.tiltDeg, accuracy: 1e-9)  // gravity untouched
    }

    // MARK: migration

    func testOrphansGoIntoTheMapOnce() {
        var bed = place("bed", center: [0, 0, 0], extent: [4, 2.5, 4], used: 10)
        bed.updated = 10
        bed.entities = [SimEntityRecord(id: "deer1", kind: "deer", behaviour: "roam", heading: 0, anchor: [1, 0, -2]),
                        SimEntityRecord(id: "fox1", kind: "fox", behaviour: "stay", heading: 0, anchor: [0, 0, 0])]
        var old = place("old", center: [0, 0, 0], extent: [4, 2.5, 4], used: 1)
        old.updated = 1
        old.entities = [SimEntityRecord(id: "deer1", kind: "deer", behaviour: "roam", heading: 0, anchor: [9, 9, 9])]
        var noAlign = place("lost", center: [0, 0, 0], extent: [1, 1, 1])
        noAlign.entities = [SimEntityRecord(id: "rab1", kind: "rabbit", behaviour: "roam", heading: 0, anchor: [0, 0, 0])]
        let als = ["bed": align([10, 0, 0], version: 9), "old": align([0, 0, 0])]
        let o = PlaceMigration.orphans(places: [old, bed, noAlign], alignments: als, mapID: "site",
                                       present: ["fox1"], known: [], agentID: "phone")
        XCTAssertEqual(o.map { $0.id }, ["deer1"])                    // fox already in the map; rabbit has no alignment
        XCTAssertEqual(o[0].placeID, "bed")                           // the newest place's copy
        XCTAssertEqual(o[0].mapVersion, 9)                            // in the version its alignment was locked against
        XCTAssertEqual(o[0].pose.x, 11, accuracy: 1e-9)
        XCTAssertEqual(o[0].pose.y, 2, accuracy: 1e-9)
        XCTAssertEqual(o[0].pose.z, 0, accuracy: 1e-9)
        // deleted from the map since (known): not resurrected
        XCTAssertTrue(PlaceMigration.orphans(places: [bed], alignments: als, mapID: "site", present: ["fox1"],
                                             known: ["deer1"], agentID: "phone").isEmpty)
        XCTAssertTrue(PlaceMigration.orphans(places: [bed], alignments: als, mapID: "garage", present: [],
                                             known: [], agentID: "phone").isEmpty)
        let body = String(data: try! PlaceMigration.putBody(o[0]), encoding: .utf8)!
        XCTAssertTrue(body.contains("\"map_version\":9"))
        XCTAssertTrue(body.contains("\"place_id\":\"bed\""))
    }

    // MARK: one status

    func testOwnerScreenshotIsOneLocalizedState() {
        // server locked (mesh), saved place cancelled → green LOCALIZED, the place is not a blocker
        let s = LocPill.make(LocPillInput(online: true, phase: .locked, version: 10, method: "visual+mesh",
                                          source: "server", errCm: 4.3, trackingCode: "normal"))
        XCTAssertEqual(s.tone, .good)
        XCTAssertEqual(s.text, "LOCALIZED · whole house v10 · geometry+visual · ±5 cm")
        XCTAssertFalse(s.rows.contains { $0.lowercased().contains("relocaliz") })
    }

    func testTryingSavedPlaceIsFindingYouNotTrackingLimited() {
        let note = SavedPlaceNote(name: "Area 1", state: .trying(seconds: 4, timeout: 8))
        let s = LocPill.make(LocPillInput(online: true, phase: .searching, searchSeconds: 6,
                                          trackingCode: "limited:relocalizing", savedPlace: note))
        XCTAssertEqual(s.tone, .working)
        XCTAssertEqual(s.text, "FINDING YOU… 6 s")
        XCTAssertTrue(s.rows.contains("Saved place Area 1: also trying its AR map · 4 / 8 s"))
    }

    func testTrackingLimitedIsTheHeadline() {
        let s = LocPill.make(LocPillInput(online: true, phase: .locked, version: 10, method: "mesh", source: "server",
                                          errCm: 2, trackingCode: "limited:excessiveMotion"))
        XCTAssertEqual(s.tone, .working)
        XCTAssertEqual(s.text, "TRACKING LIMITED — move slowly")
        XCTAssertTrue(s.rows.contains { $0.hasPrefix("House map lock kept") })
        // relocalizing with no saved map being tried (an interruption) is limited too
        let r = LocPill.make(LocPillInput(online: true, phase: .searching, trackingCode: "limited:relocalizing"))
        XCTAssertEqual(r.text, "TRACKING LIMITED — look around slowly")
        // the first second of a session is not
        let i = LocPill.make(LocPillInput(online: true, phase: .searching, searchSeconds: 1,
                                          trackingCode: "limited:initializing"))
        XCTAssertEqual(i.text, "FINDING YOU… 1 s")
    }

    func testCarriedLockWording() {
        let s = LocPill.make(LocPillInput(online: true, phase: .locked, version: 10, method: "mesh", source: "carried",
                                          errCm: LocPill.errorEstimate(spreadCm: 1, rmseCm: nil, method: "mesh",
                                                                       source: "carried")))
        XCTAssertEqual(s.text, "LOCALIZED · whole house v10 · re-anchored · ±8 cm")
    }

    func testPlaceLineNeverBlocksOnceLocked() {
        let none = PlaceLine.make(note: nil, masterLocked: true, savedCount: 2, bodies: 0)
        XCTAssertEqual(none.title, "SAVED PLACES · not loaded")
        XCTAssertEqual(none.detail, "Not needed: localized on the house map")
        XCTAssertFalse(none.trying)
        let t = PlaceLine.make(note: SavedPlaceNote(name: "Area 1", state: .trying(seconds: 3, timeout: 8)),
                               masterLocked: false, savedCount: 2, bodies: 0)
        XCTAssertEqual(t.title, "SAVED PLACE · trying Area 1 · 3 s")
        XCTAssertEqual(t.tone, .working)
        XCTAssertTrue(t.trying)
        let m = PlaceLine.make(note: SavedPlaceNote(name: "Area 1", state: .matched), masterLocked: true, savedCount: 2,
                               bodies: 3)
        XCTAssertEqual(m.tone, .good)
        XCTAssertTrue(m.detail.contains("3 sim bodies"))
        XCTAssertEqual(PlaceLine.make(note: nil, masterLocked: false, savedCount: 0, bodies: 0).title, "NO SAVED PLACE")
    }
}
