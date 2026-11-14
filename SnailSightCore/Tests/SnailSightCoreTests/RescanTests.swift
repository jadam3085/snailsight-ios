import XCTest
@testable import SnailSightCore

/// 12.27 Rescan area: the client state machine against a mock server (draft contract + tolerant parsing + fallbacks).
final class RescanTests: XCTestCase {

    /// A tiny in-memory rescan server: create -> id, finish -> building, GET -> building x `buildPolls` then `outcome`.
    final class MockServer {
        var calls: [(String, String, [String: Any]?)] = []
        var supported = true
        var offline = false
        var buildPolls = 2
        var outcome: [String: Any] = ["state": "published", "published_rev": 177, "coverage_pct": 91.5,
                                      "quality": ["label": "good", "score": 0.82],
                                      "preview": ["before_url": "/v1/maps/site/rescan/r1/before.png",
                                                  "after_url": "/v1/maps/site/rescan/r1/after.png", "at": "1,2,3,4,0.5,-0.3"]]
        var polls = 0
        var finishStatus = 202

        struct Down: Error {}

        func handle(_ m: String, _ p: String, _ b: Data?) async throws -> (Data, Int) {
            let body = b.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            calls.append((m, p, body))
            if offline { throw Down() }
            func j(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
            if !supported { return (j(["detail": "Not Found"]), 404) }
            switch (m, p) {
            case ("POST", "/v1/maps/site/rescan"):
                return (j(["rescan_id": "r1", "state": "open"]), 201)
            case ("POST", "/v1/maps/site/rescan/r1/finish"):
                return (j(["rescan_id": "r1", "state": "queued"]), finishStatus)
            case ("GET", "/v1/maps/site/rescan/r1"):
                polls += 1
                if polls <= buildPolls { return (j(["rescan_id": "r1", "state": "building", "coverage_pct": 40.0 + Double(polls)]), 200) }
                var o = outcome
                o["rescan_id"] = "r1"
                return (j(o), 200)
            default:
                return (j(["detail": "Not Found"]), 404)
            }
        }
    }

    func finishInfo() -> RescanFinish {
        var cov = ScanCoverage.Summary()
        cov.cells = 100; cov.coveredCells = 80; cov.seen = [30, 60, 10, 0]; cov.covered = [28, 45, 7, 0]; cov.goodShare = 0.7
        return RescanFinish(streamIDs: ["s1", "s2"], keyframes: 240, durationS: 312, coverage: cov, points: 412_000,
                            locked: true, queueLeft: 0)
    }

    func testFullFlowPublishes() async {
        let srv = MockServer()
        let c = RescanClient(transport: srv.handle)
        var s = RescanSession(setting: .indoor, name: "Kitchen", map: "site", now: 1000)
        XCTAssertEqual(s.phase, .idle)
        let id = await c.create(&s, RescanRequest(setting: .indoor, name: "Kitchen", appVersion: "12.27", lat: 45.1, lon: -75.2, hAccM: 8))
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(s.phase, .scanning)
        let create = srv.calls[0].2!
        XCTAssertEqual(create["kind"] as? String, "area")
        XCTAssertEqual(create["setting"] as? String, "indoor")
        XCTAssertEqual(create["name"] as? String, "Kitchen")
        XCTAssertEqual((create["geo"] as? [String: Any])?["lat"] as? Double, 45.1)
        s.finishing(finishInfo(), now: 1312)
        XCTAssertEqual(s.phase, .finishing)
        await c.finish(&s)
        XCTAssertEqual(s.phase, .building)
        let fin = srv.calls[1].2!
        XCTAssertEqual(srv.calls[1].1, "/v1/maps/site/rescan/r1/finish")
        XCTAssertEqual(fin["stream_ids"] as? [String], ["s1", "s2"])
        XCTAssertEqual((fin["coverage"] as? [String: Any])?["coverage_pct"] as? Int, 80)
        var t = 1312.0, delays: [Double] = []
        while let d = await c.poll(&s, now: t) { delays.append(d); t += d }
        XCTAssertEqual(s.phase, .published)
        XCTAssertEqual(delays, [4, 4])
        XCTAssertEqual(s.status?.publishedRev, 177)
        XCTAssertEqual(s.status?.quality, "good")
        XCTAssertEqual(s.status?.qualityScore, 0.82)
        XCTAssertEqual(s.status?.afterURL, "/v1/maps/site/rescan/r1/after.png")
        XCTAssertEqual(s.status?.viewAt, "1,2,3,4,0.5,-0.3")
        XCTAssertEqual(s.title, "Rescan published")
        XCTAssertTrue(s.lines.contains("Published as map rev 177"))
        XCTAssertTrue(s.lines.contains { $0.hasPrefix("Floor 93 %") })
        XCTAssertNil(s.persisted, "a published rescan is not resumed")
    }

    func testHeldShowsTheReason() async {
        let srv = MockServer()
        srv.buildPolls = 0
        srv.outcome = ["status": "held", "held_reason": "coverage 38 % < 60 %", "coverage": 0.38]
        let c = RescanClient(transport: srv.handle)
        var s = RescanSession(setting: .outdoor, name: nil, map: "site", now: 0)
        _ = await c.create(&s, RescanRequest(setting: .outdoor))
        s.finishing(finishInfo(), now: 100)
        await c.finish(&s)
        let d = await c.poll(&s, now: 104)
        XCTAssertNil(d)
        XCTAssertEqual(s.phase, .held)
        XCTAssertEqual(s.status?.coveragePct ?? 0, 38, accuracy: 1e-9)
        XCTAssertTrue(s.lines.contains("Why: coverage 38 % < 60 %"))
        XCTAssertNotNil(s.next)
        XCTAssertTrue(s.lines.contains { $0.hasPrefix("Ground ") })
    }

    func testServerWithoutRescanFallsBackToAWalk() async {
        let srv = MockServer()
        srv.supported = false
        let c = RescanClient(transport: srv.handle)
        var s = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        let id = await c.create(&s, RescanRequest(setting: .indoor))
        XCTAssertNil(id)
        XCTAssertEqual(s.phase, .scanning, "the scan still runs (as a normal walk)")
        s.finishing(finishInfo(), now: 50)
        XCTAssertEqual(s.phase, .local)
        await c.finish(&s)
        XCTAssertEqual(srv.calls.count, 1, "no finish without a rescan id")
        XCTAssertTrue(s.lines.contains { $0.contains("no Rescan yet") })
    }

    func testOfflineCreateAndFinishErrors() async {
        let srv = MockServer()
        srv.offline = true
        let c = RescanClient(transport: srv.handle)
        var s = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        let none = await c.create(&s, RescanRequest(setting: .indoor))
        XCTAssertNil(none)
        XCTAssertEqual(s.phase, .scanning)
        XCTAssertTrue(s.localReason?.hasPrefix("server unreachable") ?? false)
        // created online, the finish call drops: it keeps building and the poll decides
        let srv2 = MockServer()
        let c2 = RescanClient(transport: srv2.handle)
        var s2 = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        _ = await c2.create(&s2, RescanRequest(setting: .indoor))
        s2.finishing(finishInfo(), now: 10)
        srv2.offline = true
        await c2.finish(&s2)
        XCTAssertEqual(s2.phase, .building)
        let d = await c2.poll(&s2, now: 14)
        XCTAssertEqual(d, 4, "an unreachable poll retries")
        srv2.offline = false
        srv2.buildPolls = 0
        _ = await c2.poll(&s2, now: 18)
        XCTAssertEqual(s2.phase, .published)
    }

    func testFinishRefusedAnd404() {
        var s = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        s.creating()
        s.created(http: 201, body: #"{"id":"abc-1"}"#.data(using: .utf8))
        XCTAssertEqual(s.id, "abc-1")
        s.finishing(finishInfo(), now: 5)
        s.finished(http: 422, body: #"{"reason":"no keyframes"}"#.data(using: .utf8))
        XCTAssertEqual(s.phase, .failed)
        XCTAssertEqual(s.status?.reason, "no keyframes")
        // a 404 while polling = failed
        var t = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        t.creating()
        t.created(http: 200, body: #"{"rescan_id":"x"}"#.data(using: .utf8))
        t.finishing(finishInfo(), now: 1)
        t.finished(http: 200, body: nil)
        XCTAssertEqual(t.phase, .building)
        XCTAssertNil(t.polled(http: 404, body: nil, now: 5))
        XCTAssertEqual(t.phase, .failed)
    }

    func testRejectsUnsafeIDsAndIllegalTransitions() {
        var s = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        // created before creating(): ignored
        XCTAssertNil(s.created(http: 201, body: #"{"rescan_id":"r1"}"#.data(using: .utf8)))
        XCTAssertEqual(s.phase, .idle)
        s.creating()
        XCTAssertNil(s.created(http: 201, body: #"{"rescan_id":"../../etc"}"#.data(using: .utf8)))
        XCTAssertNil(s.id)
        // polling outside building does nothing
        XCTAssertNil(s.polled(http: 200, body: #"{"state":"published"}"#.data(using: .utf8), now: 1))
        XCTAssertEqual(s.phase, .scanning)
        s.cancel()
        XCTAssertEqual(s.phase, .cancelled)
        s.cancel()
        XCTAssertEqual(s.phase, .cancelled)
    }

    func testPollBackoffAndGiveUp() {
        var s = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        s.creating()
        s.created(http: 201, body: #"{"rescan_id":"r9"}"#.data(using: .utf8))
        s.finishing(finishInfo(), now: 0)
        s.finished(http: 202, body: #"{"state":"queued"}"#.data(using: .utf8))
        let b = #"{"state":"building"}"#.data(using: .utf8)
        XCTAssertEqual(s.polled(http: 200, body: b, now: 30), 4)
        XCTAssertEqual(s.polled(http: 200, body: b, now: 120), 10)
        XCTAssertEqual(s.polled(http: 200, body: b, now: 600), 20)
        XCTAssertNil(s.polled(http: 200, body: b, now: RescanSession.pollGiveUpS + 1))
        XCTAssertTrue(s.stale)
        XCTAssertEqual(s.title, "Still building: check snailCOP later")
        // "scanning" from the server after finish never moves the phase back
        var t = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        t.creating(); t.created(http: 201, body: #"{"rescan_id":"r2"}"#.data(using: .utf8))
        t.finishing(finishInfo(), now: 0); t.finished(http: 200, body: #"{"state":"open"}"#.data(using: .utf8))
        XCTAssertEqual(t.phase, .building)
    }

    func testStatusParsingIsTolerant() {
        let a = RescanStatus.parse(["rescan": ["id": "q", "state": "Done", "rev": 12, "quality": 0.7, "candidate": ["after": "/a.png"],
                                               "area": ["m2": 31.5, "name": "Yard east"]]])
        XCTAssertEqual(a.id, "q")
        XCTAssertEqual(a.phase, .published)
        XCTAssertEqual(a.publishedRev, 12)
        XCTAssertEqual(a.qualityScore, 0.7)
        XCTAssertEqual(a.afterURL, "/a.png")
        XCTAssertEqual(a.areaM2, 31.5)
        XCTAssertEqual(a.areaName, "Yard east")
        let b = RescanStatus.parse(["state": "something_new", "published_rev": 3])
        XCTAssertEqual(b.phase, .published, "a published rev counts even with an unknown state word")
        XCTAssertNil(RescanStatus.parse(Data("nope".utf8)))
        XCTAssertEqual(RescanStatus.phase(of: "rejected"), .held)
        XCTAssertEqual(RescanStatus.phase(of: "error"), .failed)
        XCTAssertEqual(RescanStatus.parse(["coverage_pct": 0.5]).coveragePct, 0.5, "coverage_pct is already a percent")
    }

    func testPersistAndResume() {
        var s = RescanSession(setting: .outdoor, name: "Back yard", map: "site", now: 100)
        s.creating(); s.created(http: 201, body: #"{"rescan_id":"r5"}"#.data(using: .utf8))
        XCTAssertNotNil(s.persisted)
        s.finishing(finishInfo(), now: 400)
        s.finished(http: 202, body: nil)
        let o = s.persisted!
        let r = RescanSession.resume(o, now: 500)!
        XCTAssertEqual(r.id, "r5")
        XCTAssertEqual(r.phase, .building)
        XCTAssertEqual(r.setting, .outdoor)
        XCTAssertEqual(r.name, "Back yard")
        XCTAssertNil(RescanSession.resume(o, now: 400 + 7201), "too old")
        var scanning = o; scanning["phase"] = "scanning"
        XCTAssertNil(RescanSession.resume(scanning, now: 500), "an interrupted scan is not resumed as a build")
    }

    func testRequestJSONAndGuidance() {
        let r = RescanRequest(setting: .outdoor, name: "  ", level: 0, appVersion: "12.27", lat: .nan, lon: 1)
        let j = r.json
        XCTAssertNil(j["name"])
        XCTAssertNil(j["geo"])
        XCTAssertEqual(j["level"] as? Int, 0)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(j))
        XCTAssertTrue(RescanSetting.outdoor.guidance.contains { $0.contains("fence") })
        XCTAssertTrue(RescanSetting.indoor.guidance.contains { $0.contains("doorway") })
        XCTAssertTrue(RescanSetting.indoor.guidance.contains { $0.contains("1-2.5 m") })
        XCTAssertEqual(RescanSession.path("site", "r1", finish: true), "/v1/maps/site/rescan/r1/finish")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(finishInfo().json))
    }

    func testKeyframeHeaderCarriesRescanID() {
        var h = LiveKeyframeHeader(seq: 1, streamID: "s", t: 0, wall: 0, T: [Double](repeating: 0, count: 16), K: [1, 1, 0, 0],
                                   imageSize: [1, 1])
        XCTAssertNil(LiveKeyframe.headerObject(h, blobs: [])["rescan_id"])
        h.rescanID = "r1"
        XCTAssertEqual(LiveKeyframe.headerObject(h, blobs: [])["rescan_id"] as? String, "r1")
        // the mode rules: leaving AR may turn the device surface / Scan view off
        XCTAssertTrue(ModeRules.teardown.contains("device_surface_toggle"))
        XCTAssertTrue(ModeRules.teardown.contains("scan_cloud"))
        XCTAssertTrue(ModeRules.isAROnly("scan_cloud_stats"))
    }

    func testDeepLinkAndPause() {
        let d = AppDeepLink.parse("snailsight://rescan")
        XCTAssertEqual(d?.mode, .ar)
        XCTAssertEqual(d?.rescan, true)
        XCTAssertEqual(d?.walk, false)
        XCTAssertEqual(LivePause.reason(recording: false, scansOpen: false, map3DOpen: false, thermalCritical: false,
                                        trackingNormal: true, scanViewOpen: true), "the 3D scan view")
        XCTAssertNil(LivePause.reason(recording: false, scansOpen: false, map3DOpen: false, thermalCritical: false,
                                      trackingNormal: true))
    }
}
