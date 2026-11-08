import Foundation

// 12.25 snailCOP mode (owner 2026-11-07: "make this the actual snailcop output so that we don't need two apps ... I can
// just go to snailcop without localizing"). The app hosts the cop.snail portal in a web view as its own mode; AR explore
// (camera, ARSession, localizer, Live map) starts only on demand. Pure decisions here: launch mode, deep links, portal
// address candidates, the bridge wire (docs/SNAILSIGHT-COP-MODE-2026-11-07.md §3), reachability text, the AR handoff guide.

/// What the app is showing: AR explore (camera + map) or snailCOP (the common operational picture, no camera).
public enum AppMode: String, CaseIterable, Codable {
    case ar, cop

    public var title: String { self == .ar ? "AR explore" : "snailCOP" }
}

// MARK: - launch

/// What to show at launch. A deep link wins; else the remembered mode unless the owner asked to choose every launch;
/// a first launch (nothing remembered) shows the chooser.
public struct LaunchDecision: Equatable {
    public var mode: AppMode?
    public var chooser: Bool
    public var reason: String
    public init(mode: AppMode?, chooser: Bool, reason: String) { self.mode = mode; self.chooser = chooser; self.reason = reason }
}

public enum LaunchMode {
    public static let rememberedKey = "app.mode.last"
    public static let askKey = "app.mode.ask"

    public static func decide(remembered: String?, askEveryLaunch: Bool, deepLink: AppDeepLink? = nil) -> LaunchDecision {
        if let d = deepLink { return LaunchDecision(mode: d.mode, chooser: false, reason: "deep_link") }
        if askEveryLaunch { return LaunchDecision(mode: nil, chooser: true, reason: "ask") }
        if let r = remembered, let m = AppMode(rawValue: r) { return LaunchDecision(mode: m, chooser: false, reason: "remembered") }
        return LaunchDecision(mode: nil, chooser: true, reason: "first_launch")
    }
}

// MARK: - a viewed spot (portal `#at=` hash)

/// The portal's orbit view: target in the map frame (z up), distance, heading (0 = +x, CCW toward +y) and pitch (< 0 looks down).
public struct CopView: Equatable {
    public var target: [Double]
    public var dist: Double
    public var yawDeg: Double
    public var pitchDeg: Double
    public init(target: [Double], dist: Double = 12, yawDeg: Double = 0, pitchDeg: Double = -35) {
        self.target = target; self.dist = dist; self.yawDeg = yawDeg; self.pitchDeg = pitchDeg
    }

    static func f2(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        return String(format: "%.2f", r).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    /// `x,y,z,dist,yaw,pitch` (2 decimals), the value of the portal's `#at=`.
    public var atValue: String { ([target[0], target[1], target[2], dist, yawDeg, pitchDeg]).map(Self.f2).joined(separator: ",") }

    /// From `x,y,z[,dist[,yaw[,pitch]]]`; nil if not 3..6 finite numbers or wild values.
    public static func parse(_ s: String) -> CopView? {
        let p = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (3...6).contains(p.count), p.allSatisfy({ $0 != nil && $0!.isFinite }) else { return nil }
        let v = p.map { $0! }
        guard v[0...2].allSatisfy({ abs($0) < 100_000 }) else { return nil }
        let d = v.count > 3 ? min(3000, max(0.5, v[3])) : 12
        return CopView(target: Array(v[0...2]), dist: d, yawDeg: v.count > 4 ? v[4] : 0,
                       pitchDeg: v.count > 5 ? min(89, max(-89, v[5])) : -35)
    }

    public var json: [String: Any] { ["target": target, "dist": dist, "yaw_deg": yawDeg, "pitch_deg": pitchDeg] }
}

// MARK: - deep links

/// `snailsight://cop[?at=x,y,z,d,yaw,pitch][&map=site]` opens snailCOP (at a view); `snailsight://ar[?target=x,y,z&label=…]`
/// opens AR explore (with a target to walk to). A portal share URL (`http(s)://…/?map=…#at=…`) opens snailCOP at that view.
public struct AppDeepLink: Equatable {
    public var mode: AppMode
    public var view: CopView?
    public var target: [Double]?
    public var label: String?
    public var map: String?
    public init(mode: AppMode, view: CopView? = nil, target: [Double]? = nil, label: String? = nil, map: String? = nil) {
        self.mode = mode; self.view = view; self.target = target; self.label = label; self.map = map
    }

    public static let scheme = "snailsight"

    public static func parse(_ raw: String) -> AppDeepLink? {
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased() else { return nil }
        let q = Dictionary((c.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        let map = q["map"].flatMap { AgentID.isValidName($0) ? $0 : nil }
        let frag = c.fragment.map { f in
            Dictionary(f.split(separator: "&").compactMap { kv -> (String, String)? in
                let p = kv.split(separator: "=", maxSplits: 1)
                return p.count == 2 ? (String(p[0]), String(p[1])) : nil
            }, uniquingKeysWith: { a, _ in a })
        } ?? [:]
        if scheme == Self.scheme {
            let host = (c.host ?? c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
            switch host {
            case "cop", "snailcop":
                return AppDeepLink(mode: .cop, view: (q["at"] ?? frag["at"]).flatMap(CopView.parse), map: map)
            case "ar", "explore":
                var t: [Double]?
                if let s = q["target"], let v = CopView.parse(s) { t = v.target }
                let label = q["label"].map { String($0.prefix(60)) }
                return AppDeepLink(mode: .ar, target: t, label: t == nil ? nil : label, map: map)
            default:
                return nil
            }
        }
        if scheme == "http" || scheme == "https", let at = frag["at"], let v = CopView.parse(at) {
            return AppDeepLink(mode: .cop, view: v, map: map)
        }
        return nil
    }

    /// `snailsight://cop?at=…` for a view (what the app shares next to the portal URL).
    public static func copURL(_ v: CopView?, map: String? = nil) -> String {
        var s = "\(scheme)://cop"
        var q: [String] = []
        if let v { q.append("at=\(v.atValue)") }
        if let m = map, m != "site" { q.append("map=\(m)") }
        if !q.isEmpty { s += "?" + q.joined(separator: "&") }
        return s
    }
}

// MARK: - where the portal is

public enum CopPortal {
    public static let portalPort = 8945
    public static let gatePort = 8946
    /// The stable name (Caddy on the ops node; Tailscale split-DNS). Falls through to the power gate when the stack is off.
    public static let stableName = "http://cop.snail"
    public static let overrideKey = "cop.portal_override"
    public static let lastGoodKey = "cop.portal_last_good"

    /// Host of a server base ("http://h:8904" -> "h"), nil if none.
    public static func host(of base: String?) -> String? {
        guard let b = ServerConfig.normalise(base), let u = URLComponents(string: b), let h = u.host, !h.isEmpty else { return nil }
        return h
    }

    /// Probe order: override → last good → the map server's host on the portal port → the stable name. The map
    /// server's host goes before the name because the app already reached it (the name needs split DNS).
    public static func candidates(override: String?, lastGood: String?, serverBase: String?,
                                  tailnet: String = ServerConfig.tailnet, lan: String = ServerConfig.lan) -> [ServerCandidate] {
        var out: [ServerCandidate] = []
        func add(_ label: String, _ b: String?) {
            guard let n = ServerConfig.normalise(b), !out.contains(where: { $0.base == n }) else { return }
            out.append(ServerCandidate(label: label, base: n))
        }
        add("override", override)
        add("last", lastGood)
        for (label, b) in [("server", serverBase), ("tailnet", tailnet), ("lan", lan)] {
            if let h = host(of: b) { add(label, "http://\(h):\(portalPort)") }
        }
        add("name", stableName)
        return out
    }

    /// The power gate for a portal base on a host (":8945" → ":8946"); nil for a name (Caddy already falls through).
    public static func gateBase(forPortal base: String) -> String? {
        guard var c = URLComponents(string: base), c.port == portalPort else { return nil }
        c.port = gatePort
        c.path = ""
        return c.string
    }

    /// The page the web view loads.
    public static func pageURL(base: String, appVersion: String, map: String = "site", view: CopView? = nil,
                               lite: Bool = false) -> String {
        var q = ["app=1", "appv=\(appVersion.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-"))) ?? "")"]
        if map != "site" { q.append("map=\(map)") }
        if lite { q.append("preset=low") }
        var s = base + "/?" + q.joined(separator: "&")
        if let v = view { s += "#at=\(v.atValue)" }
        return s
    }
}

// MARK: - reachability: what to tell the owner

public enum CopProbe: Equatable {
    case portal                 // the portal answered (200 on its own page)
    case gate(String)           // the power gate answered: stack state ("off", "starting", "stopping", …)
    case refused                // TCP refused / connection reset (host up, nothing listening)
    case timeout
    case dns                    // name did not resolve
    case other(String)
}

public struct CopReach: Equatable {
    public enum Kind: String { case ready, off, waking, noNetwork, noTailnet, unreachable }
    public var kind: Kind
    public var title: String
    public var detail: String
    public var retryS: Double
    /// The owner can turn the stack on from here (the gate answered).
    public var canTurnOn: Bool

    public init(kind: Kind, title: String, detail: String, retryS: Double, canTurnOn: Bool) {
        self.kind = kind; self.title = title; self.detail = detail; self.retryS = retryS; self.canTurnOn = canTurnOn
    }

    /// One verdict from the network path and every probe answer (portal candidates + gates).
    /// `vpn` = an "other" (VPN / utun) interface is up: Tailscale on iOS shows as one.
    public static func diagnose(network: Bool, vpn: Bool, onHomeWiFi: Bool, probes: [CopProbe]) -> CopReach {
        if probes.contains(.portal) {
            return CopReach(kind: .ready, title: "snailCOP", detail: "", retryS: 0, canTurnOn: false)
        }
        if let g = probes.compactMap({ p -> String? in if case .gate(let s) = p { return s }; return nil }).first {
            if g == "starting" || g == "on" || g == "waking" {
                return CopReach(kind: .waking, title: "snailCOP is starting",
                                detail: "The map server stack is starting up. This takes about a minute.", retryS: 3, canTurnOn: false)
            }
            return CopReach(kind: .off, title: "snailCOP is off",
                            detail: "The COP and map server stack is switched off to save the server's resources. Turn it on to open snailCOP.",
                            retryS: 15, canTurnOn: true)
        }
        if !network {
            return CopReach(kind: .noNetwork, title: "No network",
                            detail: "This phone is offline. snailCOP opens as soon as Wi-Fi or mobile data is back.", retryS: 5, canTurnOn: false)
        }
        if !vpn && !onHomeWiFi {
            return CopReach(kind: .noTailnet, title: "Tailscale is off",
                            detail: "snailCOP lives on the home server. Away from home it is reached over Tailscale: turn Tailscale on, then retry.",
                            retryS: 10, canTurnOn: false)
        }
        let allDNS = !probes.isEmpty && probes.allSatisfy { $0 == .dns }
        let detail = allDNS ? "The server's name did not resolve. Check that Tailscale is connected (MagicDNS), or set the snailCOP address in Settings."
            : "The home server is not answering. It may be asleep or restarting. AR explore still works offline."
        return CopReach(kind: .unreachable, title: "Can't reach snailCOP", detail: detail, retryS: 10, canTurnOn: false)
    }
}

// MARK: - bridge: portal → app

/// A message the portal posts (`window.webkit.messageHandlers.snailsight.postMessage`). Protocol v1.
public enum CopBridgeIn: Equatable {
    case ready(proto: Int, map: String?, rev: Int?)
    case view(CopView, mode: String, level: String)
    case openAR(target: [Double], label: String, source: String, id: String?)
    case share(url: String, title: String)
    case drive(active: Bool, id: String?)
    case fly(active: Bool)
    case log(ev: String, data: [String: Double])
    case unknown(String)

    /// Web log events the app copies into its session log (as `cop_web_<ev>`), nothing else.
    public static let logEvents: Set<String> = ["gl_lost", "error", "mem", "tab", "world"]

    static func nums(_ a: Any?) -> [Double]? {
        guard let arr = a as? [Any], arr.count == 3 else { return nil }
        let v = arr.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
        return v.count == 3 && v.allSatisfy({ $0.isFinite && abs($0) < 100_000 }) ? v : nil
    }

    static func num(_ a: Any?) -> Double? { (a as? NSNumber)?.doubleValue ?? (a as? Double) }

    public static func parse(_ body: Any) -> CopBridgeIn? {
        guard let o = body as? [String: Any], let t = o["type"] as? String else { return nil }
        switch t {
        case "ready":
            return .ready(proto: (o["proto"] as? NSNumber)?.intValue ?? 0, map: o["map"] as? String, rev: (o["rev"] as? NSNumber)?.intValue)
        case "view":
            guard let tg = nums(o["target"]) else { return nil }
            let v = CopView(target: tg, dist: num(o["dist"]) ?? 12, yawDeg: num(o["yaw_deg"]) ?? 0, pitchDeg: num(o["pitch_deg"]) ?? -35)
            let lv: String = (o["level"] as? String) ?? ((o["level"] as? NSNumber).map { "\($0.intValue)" } ?? "all")
            return .view(v, mode: (o["mode"] as? String) ?? "3d", level: lv)
        case "open_ar":
            guard let tg = nums(o["target"]) else { return nil }
            return .openAR(target: tg, label: String(((o["label"] as? String) ?? "").prefix(60)),
                           source: (o["source"] as? String) ?? "view", id: (o["id"] as? String).map { String($0.prefix(80)) })
        case "share":
            guard let u = o["url"] as? String, let c = URLComponents(string: u), ["http", "https"].contains(c.scheme ?? "") else { return nil }
            return .share(url: u, title: String(((o["title"] as? String) ?? "snailCOP").prefix(80)))
        case "drive":
            return .drive(active: (o["active"] as? Bool) ?? false, id: o["id"] as? String)
        case "fly":
            return .fly(active: (o["active"] as? Bool) ?? false)
        case "log":
            guard let ev = o["ev"] as? String, logEvents.contains(ev) else { return nil }
            var d: [String: Double] = [:]
            for (k, v) in ((o["data"] as? [String: Any]) ?? [:]).prefix(16) where k.count <= 32 {
                if let n = num(v), n.isFinite { d[k] = n }
            }
            return .log(ev: ev, data: d)
        default:
            return .unknown(String(t.prefix(32)))
        }
    }
}

// MARK: - bridge: app → portal

/// Messages for `window.SnailApp.receive(msg)`; built as JSON text here so the web view call is one string.
public enum CopBridgeOut {
    public static func js(_ msg: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(msg),
              let d = try? JSONSerialization.data(withJSONObject: msg, options: [.sortedKeys]) else { return nil }
        return "window.SnailApp&&window.SnailApp.receive(\(String(decoding: d, as: UTF8.self)))"
    }

    public static func insets(top: Double, right: Double, bottom: Double, left: Double) -> [String: Any] {
        ["type": "insets", "top": top.rounded(), "right": right.rounded(), "bottom": bottom.rounded(), "left": left.rounded()]
    }

    /// "You are here": the camera in the map frame + where it looks. `forward` is a map-frame direction; yaw from its
    /// horizontal part (0 = +x, CCW toward +y). nil pose = clear the marker.
    public static func pose(_ p: PhonePose?) -> [String: Any] {
        guard let p else { return ["type": "pose", "pose": NSNull()] }
        var o: [String: Any] = ["x": r2(p.position[0]), "y": r2(p.position[1]), "z": r2(p.position[2]),
                                "yaw_deg": r2(p.yawDeg), "age_s": p.ageS.rounded(), "live": p.live,
                                "quality": p.live ? "locked" : "last"]
        o["level"] = p.level.map { $0 as Any } ?? NSNull()
        return ["type": "pose", "pose": o]
    }

    public static func mem(level: MemLevel, footprintMB: Double?, thermal: String) -> [String: Any] {
        var o: [String: Any] = ["type": "mem", "level": level.label, "thermal": thermal]
        if let f = footprintMB { o["footprint_mb"] = f.rounded() }
        return o
    }

    public static func paused(_ on: Bool) -> [String: Any] { ["type": "paused", "on": on] }
    public static func goto(_ v: CopView) -> [String: Any] { ["type": "goto", "at": v.json] }

    /// Gamepad state for the portal (sticks y up, dead zone applied by the portal).
    public static func pad(_ f: GamepadFrame?) -> [String: Any] {
        guard let f else { return ["type": "pad", "connected": false] }
        let names: [GamepadButton: String] = [.a: "a", .b: "b", .x: "x", .y: "y", .l1: "l1", .r1: "r1", .l3: "l3", .r3: "r3",
                                              .dUp: "dUp", .dDown: "dDown", .dLeft: "dLeft", .dRight: "dRight",
                                              .start: "start", .select: "select"]
        let b = f.pressed.compactMap { names[$0] }.sorted()
        return ["type": "pad", "connected": true, "lx": r3(f.left.x), "ly": r3(f.left.y), "rx": r3(f.right.x), "ry": r3(f.right.y),
                "l2": r3(f.l2), "r2": r3(f.r2), "buttons": b]
    }

    static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// The phone in the map frame, for the portal's "you are here".
public struct PhonePose: Equatable {
    public var position: [Double]
    public var yawDeg: Double
    public var ageS: Double
    public var live: Bool
    public var level: Int?
    public init(position: [Double], yawDeg: Double, ageS: Double, live: Bool, level: Int? = nil) {
        self.position = position; self.yawDeg = yawDeg; self.ageS = ageS; self.live = live; self.level = level
    }

    /// From a camera position and a point ahead of it (both map frame). Looking straight down keeps the previous yaw.
    public static func from(camera c: [Double], ahead a: [Double], at t: Double, now: Double, live: Bool, level: Int? = nil,
                            fallbackYaw: Double = 0) -> PhonePose {
        let dx = a[0] - c[0], dy = a[1] - c[1]
        let yaw = hypot(dx, dy) < 1e-4 ? fallbackYaw : atan2(dy, dx) * 180 / .pi
        return PhonePose(position: c, yawDeg: yaw, ageS: max(0, now - t), live: live, level: level)
    }
}

// MARK: - "Open AR here": the guide to the viewed spot

/// A spot handed from snailCOP to AR explore. The HUD says how far and which way until you arrive.
public struct ARHandoffTarget: Equatable {
    public var target: [Double]
    public var label: String
    public var since: Double
    public init(target: [Double], label: String, since: Double) { self.target = target; self.label = label; self.since = since }

    public static let arriveM = 1.5
    /// A target is dropped after this long (the owner moved on).
    public static let maxAgeS = 20.0 * 60

    public struct Guide: Equatable {
        public var distanceM: Double
        public var relativeDeg: Double      // + = to the left (CCW), − = to the right
        public var arrived: Bool
        public var text: String
    }

    /// From the camera position and forward direction in the map frame.
    public func guide(camera c: [Double], forward f: [Double]) -> Guide {
        let dx = target[0] - c[0], dy = target[1] - c[1], dz = target[2] - c[2]
        let d = hypot(dx, dy)
        let fy = atan2(f[1], f[0]), ty = atan2(dy, dx)
        var rel = (ty - fy) * 180 / .pi
        while rel > 180 { rel -= 360 }
        while rel < -180 { rel += 360 }
        let name = label.isEmpty ? "Target" : label
        if d < Self.arriveM {
            let up = abs(dz) > 1.8 ? (dz > 0 ? " · upstairs" : " · downstairs") : ""
            return Guide(distanceM: d, relativeDeg: rel, arrived: true, text: "\(name) is here\(up)")
        }
        let way: String
        switch abs(rel) {
        case ..<20: way = "ahead"
        case ..<60: way = rel > 0 ? "ahead left" : "ahead right"
        case ..<120: way = rel > 0 ? "to your left" : "to your right"
        default: way = "behind you"
        }
        let dist = d < 10 ? String(format: "%.1f m", d) : "\(Int(d.rounded())) m"
        let storey = abs(dz) > 1.8 ? (dz > 0 ? " · a floor up" : " · a floor down") : ""
        return Guide(distanceM: d, relativeDeg: rel, arrived: false, text: "\(name): \(dist) \(way)\(storey)")
    }
}

// MARK: - mode switch rules

/// What may run in each mode. snailCOP mode never starts the camera, the ARSession, the localizer or Live map.
public enum ModeRules {
    /// Log events that prove the AR stack (camera, ARSession, localizer, Live map, AR tiles) ran. None may appear while
    /// the app is in snailCOP mode, except the teardown of leaving AR. The check tool
    /// services/snailsight/tools/snailsight_check_1225.py (snailCOP repo) uses the same lists.
    public static let arOnlyExact: Set<String> = [
        "boot", "tracking", "mapping", "fps", "anchor_shift", "ar_resumed", "ar_rerun", "ar_mesh_reset", "loc_warm",
        "mesh_frozen", "mesh_restored", "heat_budget", "render", "interrupted",
    ]
    public static let arOnlyPrefixes: [String] = [
        "maploc_", "live_", "tile_", "tiles_", "device_surface", "layerb_", "geo_", "island", "mapfollow_", "armap_",
        "reloc_", "sim_server_", "sim_content_", "meshmap_", "roomscan_", "nav_layer_", "terrain_", "record_",
    ]
    /// The teardown when leaving AR for snailCOP (allowed right after the switch).
    public static let teardown: Set<String> = [
        "ar_paused", "live_state", "live_off", "live_bye", "live_bye_ack", "live_drain_end", "live_stats", "geo_off",
        "geo_stats", "island_state", "live_down_stats", "layerb_stats", "device_surface",
    ]

    public static func isAROnly(_ ev: String) -> Bool {
        arOnlyExact.contains(ev) || arOnlyPrefixes.contains(where: { ev.hasPrefix($0) })
    }

    /// Leaving AR for snailCOP: Live map and recording must stop first (recording asks; Live map stops with this cause).
    public static func canLeaveAR(recording: Bool) -> Bool { !recording }

    /// Keep the hidden snailCOP web view alive while in AR (quick return) unless memory is tight or it has been unused long.
    public static func keepWebInAR(level: MemLevel, awayS: Double) -> Bool { level < .shed && awayS < 10 * 60 }
}
