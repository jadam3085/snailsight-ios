import XCTest
@testable import SnailSightCore

/// 12.25 snailCOP mode: launch choice, deep links, portal candidates, bridge wire, reachability, AR handoff guide.
final class CopModeTests: XCTestCase {
    func testLaunchDecision() {
        XCTAssertEqual(LaunchMode.decide(remembered: nil, askEveryLaunch: false), LaunchDecision(mode: nil, chooser: true, reason: "first_launch"))
        XCTAssertEqual(LaunchMode.decide(remembered: "cop", askEveryLaunch: false).mode, .cop)
        XCTAssertEqual(LaunchMode.decide(remembered: "ar", askEveryLaunch: false).mode, .ar)
        XCTAssertTrue(LaunchMode.decide(remembered: "cop", askEveryLaunch: true).chooser)
        XCTAssertTrue(LaunchMode.decide(remembered: "bogus", askEveryLaunch: false).chooser)
        let d = AppDeepLink(mode: .ar)
        XCTAssertEqual(LaunchMode.decide(remembered: "cop", askEveryLaunch: true, deepLink: d), LaunchDecision(mode: .ar, chooser: false, reason: "deep_link"))
    }

    func testViewRoundTrip() {
        let v = CopView(target: [-6.674, 6.871, 1.36], dist: 8.5, yawDeg: 123.456, pitchDeg: -30)
        XCTAssertEqual(v.atValue, "-6.67,6.87,1.36,8.5,123.46,-30")
        let p = CopView.parse(v.atValue)!
        XCTAssertEqual(p.target[0], -6.67, accuracy: 1e-9)
        XCTAssertEqual(p.yawDeg, 123.46, accuracy: 1e-9)
        XCTAssertEqual(CopView.parse("1,2,3")?.dist, 12)
        XCTAssertNil(CopView.parse("1,2"))
        XCTAssertNil(CopView.parse("1,2,nan"))
        XCTAssertNil(CopView.parse("1,2,3,4,5,6,7"))
        XCTAssertNil(CopView.parse("1e9,2,3"))
        XCTAssertEqual(CopView.parse("0,0,0,99999,0,-120")?.dist, 3000)
        XCTAssertEqual(CopView.parse("0,0,0,10,0,-120")?.pitchDeg, -89)
    }

    func testDeepLinks() {
        let a = AppDeepLink.parse("snailsight://cop?at=1,2,3,10,90,-20")!
        XCTAssertEqual(a.mode, .cop)
        XCTAssertEqual(a.view?.target, [1, 2, 3])
        XCTAssertEqual(AppDeepLink.parse("snailsight://cop")?.view, nil)
        XCTAssertEqual(AppDeepLink.parse("snailsight://cop")?.mode, .cop)
        let b = AppDeepLink.parse("snailsight://ar?target=4,5,1.2&label=Front%20door")!
        XCTAssertEqual(b.mode, .ar)
        XCTAssertEqual(b.target, [4, 5, 1.2])
        XCTAssertEqual(b.label, "Front door")
        XCTAssertEqual(AppDeepLink.parse("snailsight://ar")?.target, nil)
        let c = AppDeepLink.parse("http://cop.snail/?map=site#at=1,2,3,4,5,6")!
        XCTAssertEqual(c.mode, .cop)
        XCTAssertEqual(c.view?.pitchDeg, 6)
        XCTAssertEqual(c.map, "site")
        XCTAssertNil(AppDeepLink.parse("http://cop.snail/"))          // a plain page is not a deep link
        XCTAssertNil(AppDeepLink.parse("snailsight://nope"))
        XCTAssertNil(AppDeepLink.parse("mailto:x@y"))
        XCTAssertNil(AppDeepLink.parse("snailsight://cop?map=../../etc")?.map)
        XCTAssertEqual(AppDeepLink.copURL(CopView(target: [1, 2, 3], dist: 10, yawDeg: 0, pitchDeg: -30)), "snailsight://cop?at=1,2,3,10,0,-30")
        XCTAssertEqual(AppDeepLink.parse(AppDeepLink.copURL(CopView(target: [1.5, -2, 3])))?.view?.target, [1.5, -2, 3])
    }

    func testPortalCandidates() {
        let c = CopPortal.candidates(override: nil, lastGood: nil, serverBase: "http://10.0.0.5:8904", tailnet: "http://10.0.0.5:8904", lan: "http://192.168.0.9:8904")
        XCTAssertEqual(c.map(\.base), ["http://10.0.0.5:8945", "http://192.168.0.9:8945", "http://cop.snail"])
        XCTAssertEqual(c.map(\.label), ["server", "lan", "name"])
        let o = CopPortal.candidates(override: "https://h.example:8947/", lastGood: "http://10.0.0.5:8945", serverBase: nil, tailnet: "", lan: "")
        XCTAssertEqual(o.map(\.base), ["https://h.example:8947", "http://10.0.0.5:8945", "http://cop.snail"])
        XCTAssertEqual(CopPortal.candidates(override: nil, lastGood: nil, serverBase: nil, tailnet: "", lan: "").map(\.base), ["http://cop.snail"])
        XCTAssertEqual(CopPortal.gateBase(forPortal: "http://10.0.0.5:8945"), "http://10.0.0.5:8946")
        XCTAssertNil(CopPortal.gateBase(forPortal: "http://cop.snail"))
        XCTAssertEqual(CopPortal.pageURL(base: "http://h:8945", appVersion: "12.25.320"), "http://h:8945/?app=1&appv=12.25.320")
        XCTAssertEqual(CopPortal.pageURL(base: "http://h:8945", appVersion: "12.25", map: "m2", view: CopView(target: [1, 2, 3], dist: 5, yawDeg: 0, pitchDeg: -10), lite: true),
                       "http://h:8945/?app=1&appv=12.25&map=m2&preset=low#at=1,2,3,5,0,-10")
    }

    func testReach() {
        XCTAssertEqual(CopReach.diagnose(network: true, vpn: true, onHomeWiFi: false, probes: [.refused, .portal]).kind, .ready)
        let off = CopReach.diagnose(network: true, vpn: true, onHomeWiFi: false, probes: [.refused, .gate("off"), .dns])
        XCTAssertEqual(off.kind, .off)
        XCTAssertTrue(off.canTurnOn)
        XCTAssertEqual(CopReach.diagnose(network: true, vpn: true, onHomeWiFi: true, probes: [.gate("starting")]).kind, .waking)
        XCTAssertEqual(CopReach.diagnose(network: false, vpn: false, onHomeWiFi: false, probes: [.timeout]).kind, .noNetwork)
        XCTAssertEqual(CopReach.diagnose(network: true, vpn: false, onHomeWiFi: false, probes: [.timeout, .dns]).kind, .noTailnet)
        let u = CopReach.diagnose(network: true, vpn: true, onHomeWiFi: false, probes: [.dns, .dns])
        XCTAssertEqual(u.kind, .unreachable)
        XCTAssertTrue(u.detail.contains("did not resolve"))
        XCTAssertEqual(CopReach.diagnose(network: true, vpn: false, onHomeWiFi: true, probes: [.timeout]).kind, .unreachable)
        XCTAssertGreaterThan(u.retryS, 0)
    }

    func testBridgeIn() {
        XCTAssertEqual(CopBridgeIn.parse(["type": "ready", "proto": 1, "map": "site", "rev": 74]), .ready(proto: 1, map: "site", rev: 74))
        let v = CopBridgeIn.parse(["type": "view", "target": [1, 2.5, 3], "dist": 9, "yaw_deg": 45, "pitch_deg": -20, "mode": "plan", "level": 1])
        XCTAssertEqual(v, .view(CopView(target: [1, 2.5, 3], dist: 9, yawDeg: 45, pitchDeg: -20), mode: "plan", level: "1"))
        XCTAssertNil(CopBridgeIn.parse(["type": "view", "target": [1, 2]]))
        XCTAssertNil(CopBridgeIn.parse(["type": "open_ar", "target": [1, Double.nan, 2]]))
        XCTAssertEqual(CopBridgeIn.parse(["type": "open_ar", "target": [1, 2, 3], "label": "Garage cam", "source": "placement", "id": "cam-1"]),
                       .openAR(target: [1, 2, 3], label: "Garage cam", source: "placement", id: "cam-1"))
        XCTAssertEqual(CopBridgeIn.parse(["type": "share", "url": "http://h:8945/?map=site#at=1,2,3", "title": "x"]), .share(url: "http://h:8945/?map=site#at=1,2,3", title: "x"))
        XCTAssertNil(CopBridgeIn.parse(["type": "share", "url": "javascript:alert(1)"]))
        XCTAssertEqual(CopBridgeIn.parse(["type": "log", "ev": "mem", "data": ["geo": 12, "preset": "low", "tex": 3]]), .log(ev: "mem", data: ["geo": 12, "tex": 3]))
        XCTAssertNil(CopBridgeIn.parse(["type": "log", "ev": "anything"]))
        XCTAssertEqual(CopBridgeIn.parse(["type": "zap"]), .unknown("zap"))
        XCTAssertNil(CopBridgeIn.parse("nope"))
        XCTAssertEqual(CopBridgeIn.parse(["type": "drive", "active": true, "id": "b1"]), .drive(active: true, id: "b1"))
    }

    func testBridgeOut() throws {
        let js = CopBridgeOut.js(CopBridgeOut.insets(top: 59.4, right: 0, bottom: 34, left: 0))!
        XCTAssertEqual(js, #"window.SnailApp&&window.SnailApp.receive({"bottom":34,"left":0,"right":0,"top":59,"type":"insets"})"#)
        let pose = PhonePose.from(camera: [1, 2, 1.5], ahead: [1, 3, 1.5], at: 100, now: 112, live: false, level: 1)
        XCTAssertEqual(pose.yawDeg, 90, accuracy: 1e-9)
        XCTAssertEqual(pose.ageS, 12)
        let o = CopBridgeOut.pose(pose)["pose"] as! [String: Any]
        XCTAssertEqual(o["quality"] as? String, "last")
        XCTAssertEqual(o["level"] as? Int, 1)
        XCTAssertNotNil(CopBridgeOut.js(CopBridgeOut.pose(nil)))
        XCTAssertEqual(PhonePose.from(camera: [0, 0, 2], ahead: [0, 0, 1], at: 0, now: 0, live: true, fallbackYaw: 33).yawDeg, 33)
        let pad = CopBridgeOut.pad(GamepadFrame(left: V2(0.5, -1), right: .zero, pressed: [.a, .r1, .home], l2: 0, r2: 0.75))
        XCTAssertEqual(pad["buttons"] as? [String], ["a", "r1"])
        XCTAssertEqual(pad["ly"] as? Double, -1)
        XCTAssertEqual(CopBridgeOut.pad(nil)["connected"] as? Bool, false)
        XCTAssertEqual(CopBridgeOut.mem(level: .shed, footprintMB: 412.4, thermal: "fair")["level"] as? String, "shed")
        XCTAssertNotNil(CopBridgeOut.js(CopBridgeOut.goto(CopView(target: [1, 2, 3]))))
    }

    func testHandoffGuide() {
        let t = ARHandoffTarget(target: [10, 0, 0], label: "Garage", since: 0)
        let ahead = t.guide(camera: [0, 0, 0], forward: [1, 0, 0])
        XCTAssertEqual(ahead.text, "Garage: 10 m ahead")
        XCTAssertFalse(ahead.arrived)
        XCTAssertEqual(t.guide(camera: [0, 0, 0], forward: [0, -1, 0]).text, "Garage: 10 m to your left")
        XCTAssertEqual(t.guide(camera: [0, 0, 0], forward: [0, 1, 0]).text, "Garage: 10 m to your right")
        XCTAssertEqual(t.guide(camera: [5, 0, 0], forward: [-1, 0, 0]).text, "Garage: 5.0 m behind you")
        XCTAssertEqual(t.guide(camera: [5, 0, 0], forward: [1, 1, 0]).text, "Garage: 5.0 m ahead right")
        XCTAssertEqual(t.guide(camera: [9.5, 0.5, 0], forward: [1, 0, 0]).text, "Garage is here")
        XCTAssertEqual(t.guide(camera: [9.5, 0.5, -2.6], forward: [1, 0, 0]).text, "Garage is here · upstairs")
        XCTAssertEqual(t.guide(camera: [0, 0, 2.7], forward: [1, 0, 0]).text, "Garage: 10 m ahead · a floor down")
        XCTAssertEqual(ARHandoffTarget(target: [3, 0, 0], label: "", since: 0).guide(camera: [0, 0, 0], forward: [1, 0, 0]).text, "Target: 3.0 m ahead")
    }

    func testModeRules() {
        for ev in ["boot", "maploc_try", "live_kf", "tile_fetch", "tiles_start", "device_surface", "layerb_first", "geo_on",
                   "island_feed", "islands_world", "loc_warm", "mapfollow_head", "record_start", "sim_server_connect"] {
            XCTAssertTrue(ModeRules.isAROnly(ev), ev)
        }
        for ev in ["app_mode", "cop_open", "cop_web_mem", "mem", "foreground", "launch", "features", "send_log", "drive_open", "map3d_open"] {
            XCTAssertFalse(ModeRules.isAROnly(ev), ev)
        }
        for ev in ModeRules.teardown { XCTAssertTrue(ModeRules.isAROnly(ev) || ev == "ar_paused", ev) }
        XCTAssertFalse(ModeRules.canLeaveAR(recording: true))
        XCTAssertTrue(ModeRules.keepWebInAR(level: .trim, awayS: 60))
        XCTAssertFalse(ModeRules.keepWebInAR(level: .shed, awayS: 60))
        XCTAssertFalse(ModeRules.keepWebInAR(level: .normal, awayS: 11 * 60))
    }
}
