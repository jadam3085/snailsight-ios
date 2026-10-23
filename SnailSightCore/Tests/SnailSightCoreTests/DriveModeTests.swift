import XCTest
@testable import SnailSightCore

/// 12.7 drive mode layout + the controller lease (the owner's "RobosnailBob is driven by another device" while he was
/// the only driver: every RELEASE event `granted:false, owner:null` flashed it).
final class DriveModeTests: XCTestCase {
    func testEnterHidesChromeAndExitRestoresExactly() {
        var l = DriveModeLayout()
        XCTAssertFalse(l.isHidden(.sheet))
        let before = DriveLayoutSnapshot(sheetDetent: .half, selectionID: "server.r1", statusExpanded: true, locExpanded: false,
                                         legacyJoystickHidden: true)
        XCTAssertTrue(l.enter(body: "r1", current: before))
        for c in DriveChrome.allCases { XCTAssertTrue(l.isHidden(c), "\(c)") }
        XCTAssertEqual(l.view, .ar)
        XCTAssertEqual(l.setView(.fpv)?.to, .fpv)
        XCTAssertNil(l.setView(.fpv))                                   // no change
        // L1 / R1 switch the body; re-entering never overwrites the original snapshot
        l.switchBody("r2")
        XCTAssertTrue(l.enter(body: "r2", current: DriveLayoutSnapshot(sheetDetent: .collapsed, selectionID: "server.r2")))
        let e = l.exit()
        XCTAssertEqual(e?.restore, before)
        XCTAssertEqual(e?.release, "r2")
        XCTAssertEqual(e?.resumeAR, true)                                // FPV paused AR
        XCTAssertFalse(l.active); XCTAssertFalse(l.isHidden(.commandRing)); XCTAssertEqual(l.view, .ar)
        XCTAssertNil(l.exit())                                           // twice: nothing
        XCTAssertFalse(l.enter(body: "", current: before))
    }

    func testViewCycle() {
        var l = DriveModeLayout()
        XCTAssertNil(l.cycleView())                                      // not driving
        l.enter(body: "r1", current: DriveLayoutSnapshot(sheetDetent: .collapsed, selectionID: nil))
        XCTAssertEqual(l.cycleView()?.to, .fpv)
        XCTAssertEqual(l.cycleView()?.to, .chase)
        XCTAssertEqual(l.cycleView()?.to, .ar)
        XCTAssertFalse(DriveView.ar.pausesAR); XCTAssertTrue(DriveView.chase.pausesAR)
        XCTAssertEqual(l.exit()?.resumeAR, false)
    }

    func testReleaseEventIsNotDrivenByAnother() throws {
        // the server's own release after 2 s idle: {type: lease, granted: false, owner: null, released_by: me}
        let raw = #"{"type":"lease","seq":9,"t":1.0,"kind":"lease","id":"r1","entity_id":"r1","owner":null,"granted":false,"released_by":"phone-1","holder":"iPhone app","reason":"idle"}"#
        let e = try XCTUnwrap(SimLeaseEvent.parse(Data(raw.utf8)))
        XCTAssertEqual(e.granted, false); XCTAssertNil(e.owner); XCTAssertEqual(e.reason, "idle")
        var t = LeaseTracker()
        XCTAssertEqual(t.observe(SimLeaseEvent(entityID: "r1", owner: "phone-1", granted: true, holder: "iPhone app"), me: "phone-1"),
                       .mine(takenFrom: nil))
        let n = t.observe(e, me: "phone-1")
        XCTAssertEqual(n, .released(reason: "idle", mine: true))
        XCTAssertNil(n.flash(title: "RobosnailBob"))                       // nothing flashed
        XCTAssertNil(t.drivenByOther("r1"))
        // a release of a body I never held (someone else's lease expiring) is also silent
        var u = LeaseTracker()
        XCTAssertNil(u.observe(SimLeaseEvent(entityID: "r1", owner: nil, granted: false, releasedBy: "other"), me: "me")
            .flash(title: "x"))
        XCTAssertNil(u.drivenByOther("r1"))
        // the old shape still parses as a lease message
        XCTAssertEqual(SimStreamMessage.parse(Data(raw.utf8)), .lease(entityID: "r1", owner: nil, granted: false))
    }

    func testSomeoneElseTakesOverAndRefusal() throws {
        var t = LeaseTracker()
        _ = t.observe(SimLeaseEvent(entityID: "r1", owner: "phone-1", granted: true), me: "phone-1")
        let n = t.observe(SimLeaseEvent(entityID: "r1", owner: "snailcop-portal-a", granted: true, by: "snailcop-portal-a",
                                        holder: "portal (cop.snail)", takenFrom: "phone-1"), me: "phone-1")
        XCTAssertEqual(n, .takenByOther(holder: "portal (cop.snail)", fromMe: true))
        XCTAssertEqual(n.flash(title: "RobosnailBob"), "portal (cop.snail) took over RobosnailBob")
        XCTAssertEqual(t.drivenByOther("r1"), "portal (cop.snail)")
        // its later release clears it
        _ = t.observe(SimLeaseEvent(entityID: "r1", owner: nil, granted: false, reason: "idle", releasedBy: "snailcop-portal-a"), me: "phone-1")
        XCTAssertNil(t.drivenByOther("r1"))
        // a 409 (dict detail) names the holder; Take over (force) → my grant with taken_from clears it
        let ack = #"{"type":"ack","ref":null,"ok":false,"status":409,"detail":{"detail":"leased","by":"snailcop-portal-a","holder":"portal (cop.snail)","until":105.2},"id":"r1"}"#
        let r = try XCTUnwrap(LeaseHolder.refusal(Data(ack.utf8)))
        XCTAssertEqual(r.id, "r1"); XCTAssertEqual(r.holder.label, "portal (cop.snail)"); XCTAssertEqual(r.holder.until, 105.2)
        XCTAssertEqual(t.refused("r1", holder: r.holder).flash(title: "RobosnailBob"), "RobosnailBob is driven by portal (cop.snail)")
        XCTAssertEqual(t.drivenByOther("r1", serverNow: 100), "portal (cop.snail)")
        XCTAssertNil(t.drivenByOther("r1", serverNow: 110))                 // its lease ran out
        XCTAssertEqual(t.observe(SimLeaseEvent(entityID: "r1", owner: "phone-1", granted: true, takenFrom: "snailcop-portal-a"),
                                 me: "phone-1").flash(title: "RobosnailBob"), "You took over RobosnailBob from portal (cop.snail)")
        XCTAssertNil(t.drivenByOther("r1"))
        // older servers: string detail; a non-409 ack is not a lease refusal
        XCTAssertEqual(LeaseHolder.refusal(Data(#"{"type":"ack","ok":false,"status":409,"detail":"leased"}"#.utf8))?.holder.label,
                       "another device")
        XCTAssertNil(LeaseHolder.refusal(Data(#"{"type":"ack","ok":false,"status":422,"detail":"robot has no turret"}"#.utf8)))
        // the old ack decoding is unchanged (dict detail → "detail")
        XCTAssertEqual(SimStreamMessage.parse(Data(ack.utf8)), .ack(ref: "", ok: false, status: 409, detail: "detail"))
    }

    func testWheelItems() {
        XCTAssertEqual(DriveWheelItem.allCases.count, 8)
        XCTAssertFalse(DriveWheelItem.available(.centreTurret, hasTurret: false, ackermann: true, otherDriver: false))
        XCTAssertTrue(DriveWheelItem.available(.tank, hasTurret: false, ackermann: true, otherDriver: false))
        XCTAssertFalse(DriveWheelItem.available(.takeOver, hasTurret: true, ackermann: false, otherDriver: false))
        XCTAssertTrue(DriveWheelItem.available(.stop, hasTurret: false, ackermann: false, otherDriver: false))
    }
}
