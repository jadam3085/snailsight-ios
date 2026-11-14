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
        var openRescan: String?          // §5.17: one open rescan per agent + map
        var cancelled: [String] = []

        struct Down: Error {}

        func handle(_ m: String, _ p: String, _ b: Data?) async throws -> (Data, Int) {
            let body = b.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            calls.append((m, p, body))
            if offline { throw Down() }
            func j(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
            if !supported { return (j(["detail": "Not Found"]), 404) }
            switch (m, p) {
            case ("POST", "/v1/maps/site/rescan"):
                guard (body?["agent_id"] as? String)?.isEmpty == false, body?["kind"] as? String == "area" else {
                    return (j(["detail": "agent_id is required"]), 422)
                }
                if let o = openRescan { return (j(["detail": "open rescan", "rescan_id": o]), 409) }
                openRescan = "r1"
                return (j(["rescan_id": "r1", "state": "open", "guide": ["max_range_m": 2.5]]), 201)
            case ("POST", let path) where path.hasSuffix("/cancel"):
                let id = path.split(separator: "/")[4]   // ["v1", "maps", "site", "rescan", id, "cancel"]
                cancelled.append(String(id))
                if openRescan == String(id) { openRescan = nil }
                return (j(["rescan_id": String(id), "state": "cancelled"]), 200)
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
        let id = await c.create(&s, RescanRequest(setting: .indoor, name: "Kitchen", appVersion: "12.27", lat: 45.1, lon: -75.2, hAccM: 8,
                                                  agentID: "phone-x"))
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
        XCTAssertEqual(delays, [5, 5])
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
        _ = await c.create(&s, RescanRequest(setting: .outdoor, agentID: "phone-x"))
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
        let id = await c.create(&s, RescanRequest(setting: .indoor, agentID: "phone-x"))
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
        let none = await c.create(&s, RescanRequest(setting: .indoor, agentID: "phone-x"))
        XCTAssertNil(none)
        XCTAssertEqual(s.phase, .scanning)
        XCTAssertTrue(s.localReason?.hasPrefix("server unreachable") ?? false)
        // created online, the finish call drops: it keeps building and the poll decides
        let srv2 = MockServer()
        let c2 = RescanClient(transport: srv2.handle)
        var s2 = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        _ = await c2.create(&s2, RescanRequest(setting: .indoor, agentID: "phone-x"))
        s2.finishing(finishInfo(), now: 10)
        srv2.offline = true
        await c2.finish(&s2)
        XCTAssertEqual(s2.phase, .building)
        let d = await c2.poll(&s2, now: 14)
        XCTAssertEqual(d, 5, "an unreachable poll retries")
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
        XCTAssertEqual(s.polled(http: 200, body: b, now: 30), 5)
        XCTAssertEqual(s.polled(http: 200, body: b, now: 120), 15)
        XCTAssertEqual(s.polled(http: 200, body: b, now: 600), 15)
        XCTAssertEqual(s.polled(http: 200, body: b, now: 2 * 3600), 60, "a long build polls slower")
        XCTAssertEqual(s.polled(http: 200, body: b, now: 6 * 3600), 300)
        XCTAssertFalse(s.stale, "hours of building are normal (§5.17: place -> tile first, then the rescan job)")
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
        XCTAssertNotNil(RescanSession.resume(o, now: 400 + 5 * 3600), "a build hours later is still watched")
        XCTAssertNil(RescanSession.resume(o, now: 400 + RescanSession.resumeWindowS + 1), "too old")
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

    /// The §5.17 status example (held) as the server documents it.
    func testServer517HeldShape() {
        let doc: [String: Any] = [
            "rescan_id": "rs-20261114-153012-a1b2c3", "map_id": "site", "kind": "area", "name": "basement den", "level": 0,
            "state": "held", "stage": "score",
            "coverage": ["live": false, "good_m2": 41.2, "area_m2": 38.0, "blocks": 2210,
                         "cells": [["cell": "L0:-2,3", "cover": 0.81, "good_m2": 12.4, "in_area": true],
                                   ["cell": "L0:-2,4", "cover": 0.2, "good_m2": 1.0, "in_area": false]]],
            "quality": ["checks": [["name": "self_loop", "value": 3.1, "limit": 5.0, "unit": "cm", "pass": true],
                                   ["name": "seam", "value": 4.8, "limit": 3.0, "unit": "cm", "pass": false]]],
            "before_after": ["cells": ["L0:-2,3": ["before": ["dup_m2": 2.6, "ghost_pct": 9.1, "res_p90_cm": 8.5, "holes_pct": 22.0],
                                                    "after": ["dup_m2": 0.3, "ghost_pct": 1.2, "res_p90_cm": 1.9, "holes_pct": 6.0]]]],
            "preview": ["tileset": "abc", "portal": "/?preview=abc"],
            "result": ["decision": "held", "rev": NSNull(), "rev_before": 177,
                       "why": "seam p90 4.8 cm > 3.0 cm at the doorway (L0:-2,4)",
                       "rescan_advice": [["cell": "L0:-2,4", "do": "include the doorway and 1 m of the next room's walls in the scan"]],
                       "island": NSNull()],
        ]
        let s = RescanStatus.parse(doc)
        XCTAssertEqual(s.id, "rs-20261114-153012-a1b2c3")
        XCTAssertEqual(s.phase, .held)
        XCTAssertEqual(s.coveragePct ?? 0, 81, accuracy: 1e-6, "mean cover of the in-area cells")
        XCTAssertEqual(s.goodM2, 41.2)
        XCTAssertEqual(s.areaM2, 38.0)
        XCTAssertEqual(s.failedChecks, ["seam 4.8 (limit 3 cm)"])
        XCTAssertEqual(s.quality, "1 of 2 checks pass")
        XCTAssertEqual(s.reason, "seam p90 4.8 cm > 3.0 cm at the doorway (L0:-2,4)")
        XCTAssertNil(s.publishedRev)
        XCTAssertEqual(s.portalPath, "/?preview=abc")
        XCTAssertEqual(s.advice.first, "L0:-2,4: include the doorway and 1 m of the next room's walls in the scan")
        XCTAssertEqual(s.beforeAfter, "duplicate 2.6 → 0.3 m² · ghost 9.1 → 1.2 % · residual p90 8.5 → 1.9 cm · holes 22.0 → 6.0 %")
        // the states
        XCTAssertEqual(RescanStatus.phase(of: "waiting"), .building)
        XCTAssertEqual(RescanStatus.phase(of: "publishing"), .building)
        XCTAssertEqual(RescanStatus.phase(of: "island"), .published)
        XCTAssertEqual(RescanStatus.phase(of: "rolled-back"), .held)
        XCTAssertEqual(RescanStatus.phase(of: "expired"), .failed)
        XCTAssertEqual(RescanStatus.phase(of: "cancelled"), .cancelled)
        // published as an island
        let i = RescanStatus.parse(["state": "island", "result": ["decision": "island", "rev": 180, "island": "isl-3"]])
        XCTAssertEqual(i.phase, .published)
        XCTAssertEqual(i.islandID, "isl-3")
        XCTAssertEqual(i.publishedRev, 180)
    }

    func testOpenRescanIsCancelledThenRetried() async {
        let srv = MockServer()
        srv.openRescan = "r0"                                  // left open by a killed app run
        let c = RescanClient(transport: srv.handle)
        var s = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        let id = await c.create(&s, RescanRequest(setting: .indoor, agentID: "phone-x"))
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(srv.cancelled, ["r0"])
        XCTAssertNotNil(srv.calls[0].2?["client_rescan_id"] as? String)
        // live coverage while scanning does not move the phase
        await c.pollLive(&s)
        XCTAssertEqual(s.phase, .scanning)
        XCTAssertNotNil(s.live)
        // cancel route
        let st = await c.cancel(map: "site", id: "r1", why: "owner")
        XCTAssertEqual(st, 200)
        XCTAssertEqual(srv.cancelled, ["r0", "r1"])
        // a missing agent id is refused by the server -> a walk
        var t = RescanSession(setting: .indoor, name: nil, map: "site", now: 0)
        let none = await c.create(&t, RescanRequest(setting: .indoor))
        XCTAssertNil(none)
        XCTAssertEqual(t.localReason, "the server refused the rescan (HTTP 422)")
    }

    // MARK: contract: the server's documented responses (snailCOP docs/SNAILSIGHT-API.md §5.17), raw JSON text

    static let doc201 = #"{"rescan_id": "rs-20261114-153012-a1b2c3", "map_id": "site", "kind": "area", "name": "basement den", "level": 0, "state": "open", "created": 1794600000.0, "status": "/v1/maps/site/rescan/rs-20261114-153012-a1b2c3", "guide": {"max_range_m": 2.5, "min_conf": 2, "min_cos": 0.3, "block_m": 0.25, "cell_m": 4.0}}"#
    static let doc409 = #"{"detail": "this agent has an open rescan on this map: finish or cancel it first", "rescan_id": "rs-20261114-140000-ffffff"}"#
    static let doc202 = #"{"rescan_id": "rs-20261114-153012-a1b2c3", "map_id": "site", "kind": "area", "state": "waiting", "created": 1794600000.0, "finished": 1794600400.0}"#
    /// The §5.17 status example ("…" placeholders filled with valid values).
    static let docStatus = #"""
    {"rescan_id": "rs-20261114-153012-a1b2c3", "map_id": "site", "kind": "area", "name": "basement den", "level": 0,
     "state": "held", "stage": "score", "created": 0.0, "finished": 0.0, "updated": 0.0,
     "agent_id": "phone-x", "streams": ["phone-x/ar-1"], "sessions": ["s-1"],
     "coverage": {"live": false, "good_m2": 41.2, "area_m2": 38.0, "blocks": 2210,
                  "cells": [{"cell": "L0:-2,3", "cover": 0.81, "good_m2": 12.4, "in_area": true}],
                  "capture": {"conf2_share": 0.62, "grazing_share": 0.12, "far_share": 0.21}},
     "quality": {"checks": [{"name": "self_loop", "value": 3.1, "limit": 5.0, "unit": "cm", "pass": true},
                            {"name": "seam", "value": 4.8, "limit": 3.0, "unit": "cm", "pass": false}],
                 "self": {"loop_cm": 3.1, "loop_deg": 0.21, "pair_res_p90_cm": 1.8},
                 "fused": {"holes_pct": 6.2, "res_p90_cm": 1.9},
                 "tie": {"mode": "overlap", "band_m2": 14.2, "fit_cm": 1.4, "seam_p90_cm": 1.6, "step_max_cm": 0.4,
                         "orient_deg": 0.12, "sigma": {"x_cm": 0.6, "y_cm": 0.9, "z_cm": 0.3, "yaw_deg": 0.05},
                         "weak_dof": [], "gps": {"used": false}}},
     "before_after": {"cells": {"L0:-2,3": {"before": {"dup_m2": 2.6, "dup_wall_m2": 1.2, "ghost_pct": 9.1, "res_p90_cm": 8.5, "holes_pct": 22.0},
                                            "after":  {"dup_m2": 0.3, "dup_wall_m2": 0.1, "ghost_pct": 1.2, "res_p90_cm": 1.9, "holes_pct": 6.0}}},
                      "rooms": {"L0r1": {"before": {}, "after": {}}}},
     "preview": {"tileset": "0123abcd", "portal": "/?preview=0123abcd"},
     "result": {"decision": "held", "rev": null, "rev_before": 177, "why": "seam p90 4.8 cm > 3.0 cm at the doorway (L0:-2,4)",
                "rescan_advice": [{"cell": "L0:-2,4", "do": "include the doorway and 1 m of the next room's walls in the scan"}],
                "island": null},
     "epoch": null}
    """#

    func testContractDocumentedResponses() {
        // 201 create
        var s = RescanSession(setting: .indoor, name: "basement den", map: "site", now: 0)
        s.creating()
        XCTAssertEqual(s.created(http: 201, body: Data(Self.doc201.utf8)), "rs-20261114-153012-a1b2c3")
        XCTAssertEqual(s.phase, .scanning)
        // the create body the server's RescanIn reads
        let body = RescanRequest(setting: .indoor, name: "basement den", agentID: "phone-x").json
        XCTAssertEqual(body["kind"] as? String, "area")
        XCTAssertEqual(body["agent_id"] as? String, "phone-x")
        XCTAssertNotNil(body["client_rescan_id"] as? String)
        // 409 names the open rescan (the client cancels it and retries)
        XCTAssertEqual(RescanStatus.parse(Data(Self.doc409.utf8))?.id, "rs-20261114-140000-ffffff")
        // 202 finish -> building ("waiting")
        s.finishing(RescanFinish(streamIDs: ["ar-1"], keyframes: 10, durationS: 60, coverage: ScanCoverage.Summary(),
                                 points: 1, locked: true, queueLeft: 0), now: 10)
        let fj = s.finish!.json
        XCTAssertNotNil(fj["stream_ids"] as? [String])
        XCTAssertNotNil(fj["recorded"] as? Bool)
        s.finished(http: 202, body: Data(Self.doc202.utf8))
        XCTAssertEqual(s.phase, .building)
        XCTAssertEqual(s.status?.state, "waiting")
        // the status example: held with the why, the failed check, the advice, before / after, the preview
        XCTAssertNil(s.polled(http: 200, body: Data(Self.docStatus.utf8), now: 3 * 3600))
        XCTAssertEqual(s.phase, .held)
        let st = s.status!
        XCTAssertEqual(st.reason, "seam p90 4.8 cm > 3.0 cm at the doorway (L0:-2,4)")
        XCTAssertEqual(st.failedChecks, ["seam 4.8 (limit 3 cm)"])
        XCTAssertEqual(st.advice, ["L0:-2,4: include the doorway and 1 m of the next room's walls in the scan"])
        XCTAssertEqual(st.portalPath, "/?preview=0123abcd")
        XCTAssertEqual(st.goodM2, 41.2)
        XCTAssertEqual(st.coveragePct ?? 0, 81, accuracy: 1e-6)
        XCTAssertNil(st.publishedRev)
        XCTAssertNotNil(st.beforeAfter)
        XCTAssertTrue(s.lines.contains("Why: seam p90 4.8 cm > 3.0 cm at the doorway (L0:-2,4)"))
        XCTAssertTrue(s.lines.contains { $0.hasPrefix("Re-scan L0:-2,4") })
        XCTAssertTrue(s.lines.contains { $0.hasPrefix("Failed: seam") })
        XCTAssertTrue(s.next?.contains("in one go") ?? false)
    }
}
