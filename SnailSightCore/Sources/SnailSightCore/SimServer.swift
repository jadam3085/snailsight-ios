import Foundation

// SnailSight 10.1 S2/S3 client side (plan §7 S2 "Shared, server-authoritative sim", S3 "sim agents are mock robots").
// Contract (plan §7 S2, coded against while the server lane builds it): WS /v1/maps/{map_id}/sim streams snapshots
// (~10 Hz) + events; POST …/sim/entities spawns, DELETE …/sim/entities/{id} despawns, POST …/sim/entities/{id}/cmd
// sends teleop {v, w, ttl} or a goal. Entities {id, kind, pose{x,y,z,theta}, vel, state, owner, t_mono} in the MAP frame.
// - Dead reckoning: every entity is extrapolated from its last snapshot by its velocity (≤ 0.5 s), and the drawn pose
//   eases out the snapshot-to-snapshot error (τ 0.15 s: gain × latency < 1, no ringing) — snailCOP measured 82 % frozen
//   frames without it (memory snailcop-wargame-two-tier).
// - Teleop commands carry ttl 0.5 s and are re-sent at 10 Hz while the stick is held; one zero command on release.
//   A dropped link stops the robot by itself (server side TTL, like the snailSIM cmdvel_relay 0.6 s deadman).
// - Authority: server mode only when the feature is on, online, localized and the stream is alive; local S1 sim is the
//   fallback (hysteresis: 1 s healthy to switch in, 3 s silent to switch back).
// Pure, Linux-tested (SimServerTests).

/// A pose in the map frame with a tolerant decoder (theta | yaw; arrays [x, y, z, theta] too).
public struct SimPose: Equatable {
    public var x: Double, y: Double, z: Double, theta: Double
    public init(x: Double, y: Double, z: Double, theta: Double) { self.x = x; self.y = y; self.z = z; self.theta = theta }
}

extension SimPose: Decodable {
    enum K: String, CodingKey { case x, y, z, theta, yaw }
    public init(from d: Decoder) throws {
        if var a = try? d.unkeyedContainer() {
            var v: [Double] = []
            while !a.isAtEnd { v.append(try a.decode(Double.self)) }
            guard v.count >= 2 else { throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "pose")) }
            x = v[0]; y = v[1]; z = v.count > 3 ? v[2] : 0; theta = v.count > 3 ? v[3] : (v.count == 3 ? v[2] : 0)
            return
        }
        let c = try d.container(keyedBy: K.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        z = (try? c.decodeIfPresent(Double.self, forKey: .z)) ?? 0
        let th: Double? = try? c.decodeIfPresent(Double.self, forKey: .theta)
        let yw: Double? = try? c.decodeIfPresent(Double.self, forKey: .yaw)
        theta = th ?? yw ?? 0
    }
}

/// Velocity: body frame {v, w} (unicycle) or world {vx, vy, vz, wz}; omega aliases.
public struct SimVel: Equatable {
    public var v: Double?, w: Double
    public var vx: Double?, vy: Double?, vz: Double
    public init(v: Double? = nil, w: Double = 0, vx: Double? = nil, vy: Double? = nil, vz: Double = 0) {
        self.v = v; self.w = w; self.vx = vx; self.vy = vy; self.vz = vz
    }
    public static let zero = SimVel(v: 0)
}

extension SimVel: Decodable {
    enum K: String, CodingKey { case v, w, omega, wz, vx, vy, vz }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func g(_ k: K) -> Double? { let x: Double? = try? c.decodeIfPresent(Double.self, forKey: k); return x }
        v = g(.v); vx = g(.vx); vy = g(.vy); vz = g(.vz) ?? 0
        w = g(.w) ?? g(.omega) ?? g(.wz) ?? 0
    }
}

public struct SimEntitySnap: Equatable {
    public var id: String
    public var kind: String
    public var pose: SimPose
    public var vel: SimVel
    public var state: String?
    public var owner: String?
    public var tMono: Double?
    public var name: String?
    public var agentType: String?                 // S3: sim-rover | sim-drone
    public var goal: [Double]?
    public var path: [[Double]]?
    public var cat: String?                       // robot | drone | animal | object (entity docs)
    public var dims: [Double]?                    // L, W, H metres (entity docs)
    // protocol snailsight-sim/2 (API §5.9.10): ONE master world; every client draws the same clip at the same phase
    public var scale: Double?                     // body sim scale (catalog size × scale)
    public var behaviour: String?                 // the order (entity docs)
    public var clip: String?                      // idle | walk | run | eat · drive | idle · fly | landed · rest | move
    public var clipT0: Double?                    // server time the clip started
    public var clipRate: Double?                  // playback rate (1.0)
    public var action: String?                    // flee | graze | walk | run | idle · goto | patrol | teleop | …
    public var t: Double?                         // server time of this state
    // API §5.9.11 (server 0.4.7): storey + planner status; `path` = [[x, y, z, level]] (level -1 = on a stair)
    public var level: Int?
    public var nav: SimNav?
}

extension SimEntitySnap: Decodable {
    enum K: String, CodingKey {
        case id, kind, pose, vel, state, owner, name, goal, path, cat, dims, scale, behaviour, clip, action, t, level, nav
        case tMono = "t_mono", agentType = "agent_type", clipT0 = "clip_t0", clipRate = "clip_rate"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s } else { id = String(try c.decode(Int.self, forKey: .id)) }
        func opt<T: Decodable>(_ t: T.Type, _ k: K) -> T? { let x: T? = try? c.decodeIfPresent(t, forKey: k); return x }
        kind = opt(String.self, .kind) ?? "robot"
        pose = try c.decode(SimPose.self, forKey: .pose)
        vel = opt(SimVel.self, .vel) ?? .zero
        state = opt(String.self, .state)
        owner = opt(String.self, .owner)
        tMono = opt(Double.self, .tMono)
        name = opt(String.self, .name)
        agentType = opt(String.self, .agentType)
        goal = opt([Double].self, .goal)
        path = opt([[Double]].self, .path)
        cat = opt(String.self, .cat)
        dims = opt([Double].self, .dims)
        scale = opt(Double.self, .scale)
        behaviour = opt(String.self, .behaviour)
        clip = opt(String.self, .clip)
        clipT0 = opt(Double.self, .clipT0)
        clipRate = opt(Double.self, .clipRate)
        action = opt(String.self, .action)
        t = opt(Double.self, .t)
        level = opt(Int.self, .level)
        nav = opt(SimNav.self, .nav)
    }

    /// The clip to draw: the server's shared clip (protocol 2), else its older `state` hint.
    public var serverClip: String? { clip ?? state }

    /// Keep what only the entity docs carry (name, cat, dims) when a 10 Hz snapshot (dynamic state only) arrives.
    public func merged(withStatic d: SimEntitySnap?) -> SimEntitySnap {
        guard let d else { return self }
        var s = self
        if s.name == nil { s.name = d.name }
        if s.cat == nil { s.cat = d.cat }
        if s.dims == nil { s.dims = d.dims }
        if s.agentType == nil { s.agentType = d.agentType }
        if s.scale == nil { s.scale = d.scale }
        if s.behaviour == nil { s.behaviour = d.behaviour }
        if s.path == nil { s.path = d.path }
        if s.level == nil { s.level = d.level }
        s.nav = SimNav.merged(snapshot: s.nav, doc: d.nav)
        return s
    }

    public var isDrone: Bool { cat == "drone" || kind.contains("drone") || (agentType ?? "").contains("drone") }
    public var isRover: Bool {
        cat == "robot" || kind == "robot" || kind.contains("rover") || (agentType ?? "").contains("rover")
    }
    public var isObject: Bool { cat == "object" }
}

public enum SimStreamMessage: Equatable {
    /// `full` = every entity is listed (absent ones are gone); otherwise sleeping objects are left out.
    case snapshot(tMono: Double?, entities: [SimEntitySnap], full: Bool)
    case entity(SimEntitySnap)                  // a static description changed (name, dims, …)
    case event(kind: String, text: String?, entityID: String?)
    case lease(entityID: String, owner: String?, granted: Bool?)
    case ack(ref: String, ok: Bool, status: Int?, detail: String?)   // the server's answer to a WS command with a ref
    case error(String)
    case other(String)

    struct Raw: Decodable {
        var type: String?
        var t_mono: Double?
        var full: Bool?
        var entity: SimEntitySnap?
        var entities: [SimEntitySnap]?
        var event: String?
        var kind: String?
        var text: String?
        var message: String?
        var id: String?
        var entity_id: String?
        var owner: String?
        var granted: Bool?
        var detail: LenientText?
        var ref: String?
        var ok: Bool?
        var status: Int?
        var reason: String?
    }

    /// A field that is text in some replies and an object in others (409 detail): never fails the message.
    struct LenientText: Decodable {
        var text: String?
        init(from d: Decoder) throws {
            if let c = try? d.singleValueContainer(), let s = try? c.decode(String.self) { text = s; return }
            text = "detail"
        }
    }

    public static func parse(_ data: Data) -> SimStreamMessage? {
        guard let r = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        switch r.type ?? (r.entities != nil ? "snapshot" : "") {
        case "snapshot", "state": return .snapshot(tMono: r.t_mono, entities: r.entities ?? [], full: r.full ?? true)
        case "hello": return .snapshot(tMono: nil, entities: r.entities ?? [], full: true)   // the world on connect
        case "entity": return r.entity.map { .entity($0) } ?? .other("entity")
        case "event": return .event(kind: r.event ?? r.kind ?? "event", text: r.text ?? r.message, entityID: r.entity_id ?? r.id)
        case "lease": return .lease(entityID: r.entity_id ?? r.id ?? "", owner: r.owner, granted: r.granted)
        case "ack": return .ack(ref: r.ref ?? "", ok: r.ok ?? false, status: r.status, detail: r.reason ?? r.detail?.text)
        case "error": return .error(r.detail?.text ?? r.message ?? "?")
        case let t: return .other(t)
        }
    }
}

/// Client-side track of one server entity: extrapolate + ease out the correction error.
public struct RemoteTrack: Equatable {
    public private(set) var snap: SimEntitySnap
    public private(set) var recvAt: Double                 // local clock when the snapshot arrived
    private var errX = 0.0, errY = 0.0, errZ = 0.0, errT = 0.0
    private var errAt = 0.0
    public static let maxExtrapolate = 0.5
    public static let tau = 0.15
    public static let snapMetres = 1.0                     // teleports (spawn / respawn) are not eased

    public init(_ s: SimEntitySnap, now: Double) { snap = s; recvAt = now; errAt = now }

    /// Pure extrapolation of `s` by `dt` seconds.
    public static func extrapolate(_ s: SimEntitySnap, dt rawDt: Double) -> SimPose {
        let dt = max(0, min(rawDt, maxExtrapolate))
        var p = s.pose
        if let vx = s.vel.vx, let vy = s.vel.vy {
            p.x += vx * dt; p.y += vy * dt
        } else if let v = s.vel.v {
            let w = s.vel.w
            if abs(w) < 1e-6 {
                p.x += v * cos(p.theta) * dt; p.y += v * sin(p.theta) * dt
            } else {
                let th1 = p.theta + w * dt
                p.x += v / w * (sin(th1) - sin(p.theta)); p.y -= v / w * (cos(th1) - cos(p.theta))
            }
        }
        p.z += s.vel.vz * dt
        p.theta = atan2(sin(p.theta + s.vel.w * dt), cos(p.theta + s.vel.w * dt))
        return p
    }

    /// The pose to draw at local time `now`.
    public func pose(now: Double) -> SimPose {
        var p = Self.extrapolate(snap, dt: now - recvAt)
        let k = exp(-max(0, now - errAt) / Self.tau)
        p.x += errX * k; p.y += errY * k; p.z += errZ * k
        p.theta = atan2(sin(p.theta + errT * k), cos(p.theta + errT * k))
        return p
    }

    /// A new snapshot: what was being drawn becomes the starting error, so nothing jumps.
    public mutating func update(_ s: SimEntitySnap, now: Double) {
        let drawn = pose(now: now)
        snap = s
        recvAt = now
        errAt = now
        let dx = drawn.x - s.pose.x, dy = drawn.y - s.pose.y, dz = drawn.z - s.pose.z
        if (dx * dx + dy * dy + dz * dz).squareRoot() > Self.snapMetres {
            errX = 0; errY = 0; errZ = 0; errT = 0
        } else {
            errX = dx; errY = dy; errZ = dz
            errT = atan2(sin(drawn.theta - s.pose.theta), cos(drawn.theta - s.pose.theta))
        }
    }
}

/// Local S1 vs server S2.
public struct SimAuthority: Equatable {
    public enum Mode: String, Equatable { case local, server }
    public private(set) var mode: Mode = .local
    public private(set) var reason = "off"
    private var healthySince: Double?
    public static let switchInS = 1.0
    public static let silentOutS = 3.0
    public init() {}

    /// `lastMessageAt`: local time of the newest sim stream message (nil = none since connect).
    /// `blocked`: why the server may not (or may no longer) be authoritative although the stream is healthy — e.g. its
    /// world lacks this phone's bodies (SimHandoff.blocker): the phone stays / falls back to its local sim.
    @discardableResult
    public mutating func update(enabled: Bool, online: Bool, localized: Bool, connected: Bool, lastMessageAt: Double?,
                                now: Double, blocked: String? = nil) -> Bool {
        let old = mode
        let alive = connected && (lastMessageAt.map { now - $0 <= Self.silentOutS } ?? false)
        var why: String?
        if !enabled { why = "off" } else if !online { why = "offline" } else if !localized { why = "not localized" }
        else if !alive { why = connected ? "stream silent" : "not connected" }
        else if let b = blocked { why = b }
        if let w = why {
            mode = .local; reason = w; healthySince = nil
        } else {
            if healthySince == nil { healthySince = now }
            if mode == .local, now - healthySince! >= Self.switchInS { mode = .server }
            reason = mode == .server ? "server" : "connecting"
        }
        return mode != old
    }
}

/// 10.5: handing the sim to the server never makes the owner's bodies vanish. Before the switch the server world must
/// hold every local body (by id; the phone uploads the missing ones first: POST …/sim/import); once the server is in
/// charge, an EMPTY server world (while the phone has bodies) sends it back to the local sim. nil = may be / stay
/// server-authoritative.
public enum SimHandoff {
    public static func blocker(local: Set<String>, server: Set<String>, serverMode: Bool, uploading: Bool) -> String? {
        if local.isEmpty { return nil }                       // nothing of ours to lose
        if serverMode { return server.isEmpty ? "server world empty" : nil }
        let missing = local.subtracting(server).count
        if missing == 0 { return nil }
        if uploading { return "uploading \(missing) bod\(missing == 1 ? "y" : "ies")" }
        return server.isEmpty ? "server world empty" : "server lacks \(missing) of \(local.count) bodies"
    }
}

/// Teleop deadman: what to send for the stick right now (nil = nothing).
public struct TeleopSender: Equatable {
    public static let ttl = 0.5
    public static let every = 0.1
    public static let deadband = 0.02
    private var lastSent = -1e9
    private var lastWasZero = true
    public init() {}

    public mutating func next(v: Double, w: Double, now: Double) -> (v: Double, w: Double, ttl: Double)? {
        let zero = abs(v) < Self.deadband && abs(w) < Self.deadband
        if zero {
            if lastWasZero { return nil }
            lastWasZero = true
            lastSent = now
            return (0, 0, Self.ttl)                   // one explicit stop on release
        }
        guard now - lastSent >= Self.every || lastWasZero else { return nil }
        lastWasZero = false
        lastSent = now
        return (v, w, Self.ttl)
    }
}

/// Request bodies + paths (one place to adapt if the server lane names things differently).
public enum SimServerAPI {
    public static func streamPath(map: String) -> String { "/v1/maps/\(map)/sim" }
    public static func entitiesPath(map: String) -> String { "/v1/maps/\(map)/sim/entities" }
    public static func entityPath(map: String, id: String) -> String { "/v1/maps/\(map)/sim/entities/\(id)" }
    public static func cmdPath(map: String, id: String) -> String { "/v1/maps/\(map)/sim/entities/\(id)/cmd" }
    public static func taskPath(map: String, id: String) -> String { "/v1/maps/\(map)/sim/entities/\(id)/task" }
    public static func importPath(map: String) -> String { "/v1/maps/\(map)/sim/import" }

    /// POST …/sim/import: this phone's local bodies (map frame) that the server world lacks; the server writes them to
    /// the map entities (the one store) and spawns them with the same ids.
    public static func importBody(_ list: [MapEntity], agentID: String) throws -> Data {
        struct B: Encodable { let agent_id: String; let entities: [MapEntity] }
        return try JSONEncoder().encode(B(agent_id: agentID, entities: list))
    }

    /// S3 tasks on a sim rover (POST …/task): drone_assist (the target demo: a drone flies ahead to `goal`), deter
    /// (herd deer away), goto_label, patrol.
    public static func taskBody(task: String, goal: [Double]? = nil, label: String? = nil, kinds: [String]? = nil,
                                agentID: String) -> Data {
        var o: [String: Any] = ["task": task, "agent_id": agentID]
        if let g = goal { o["goal"] = g.prefix(3).map(r) }
        if let l = label { o["label"] = l }
        if let k = kinds { o["kinds"] = k }
        return json(o)
    }

    public enum Command: Equatable {
        case teleop(v: Double, w: Double, ttl: Double)
        case goal(x: Double, y: Double, z: Double?)
        case goTo(label: String, objectID: String?, x: Double, y: Double)
        case goToLabel(String)
        case patrol([[Double]])
        case stop
        case place(x: Double, y: Double, z: Double?)         // move (drag / Move): the server puts it there
        case kick(fromX: Double, fromY: Double)              // animals: bolt away from this map point
        case behaviour(String)                               // an order without params (roam, graze, hold, wander)
        case flee(fromX: Double, fromY: Double, seconds: Double)   // Flee: run from the person
        case followAgent(String)                             // Follow me: follow this client's published pose
        // 12.0 drone missions (API §5.16, server flag `drone_missions`): exactly one of hold / climb_above / return / land
        case droneOp(String)
        case mission(goal: [Double], mode: String, canopy: String)   // mode normal | explore; canopy auto | under | above

        /// Short name for logs (sim_cmd).
        public var name: String {
            switch self {
            case .teleop: return "teleop"
            case .goal: return "goto"
            case .goTo, .goToLabel: return "goto_label"
            case .patrol: return "patrol"
            case .stop: return "stop"
            case .place: return "place"
            case .kick: return "kick"
            case .behaviour(let b): return b
            case .flee: return "flee"
            case .followAgent: return "follow"
            case .droneOp(let o): return o
            case .mission(_, let mode, _): return "mission_\(mode)"
            }
        }
    }

    static func json(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data() }

    public static func body(_ c: Command, agentID: String) -> Data { json(fields(c, agentID: agentID)) }

    /// WS command (protocol snailsight-sim/2): {type: cmd, id, ref, agent_id, …the REST body…}; the server acks the ref.
    public static func wsCommand(_ c: Command, id: String, agentID: String, ref: String?) -> Data {
        var o = fields(c, agentID: agentID)
        o["type"] = "cmd"; o["id"] = id; o["agent_id"] = agentID
        if let ref { o["ref"] = ref }
        return json(o)
    }

    public static func wsDelete(id: String, agentID: String, ref: String) -> Data {
        json(["type": "delete", "id": id, "agent_id": agentID, "ref": ref])
    }

    public static func wsSpawn(kind: String, x: Double, y: Double, z: Double, theta: Double, scale: Double?,
                               agentID: String, ref: String) -> Data {
        var o = (try? JSONSerialization.jsonObject(with: spawnBody(kind: kind, x: x, y: y, z: z, theta: theta,
                                                                    agentID: agentID))) as? [String: Any] ?? [:]
        if let scale { o["scale"] = min(2, max(0.1, scale)) }
        o["type"] = "spawn"; o["agent_id"] = agentID; o["ref"] = ref
        return json(o)
    }

    /// Follow me: this client's own map pose (~2 Hz while something follows it).
    public static func wsAgentPose(agentID: String, x: Double, y: Double, z: Double) -> Data {
        json(["type": "agent_pose", "agent_id": agentID, "pose": ["x": r(x), "y": r(y), "z": r(z)]])
    }

    static func fields(_ c: Command, agentID: String) -> [String: Any] {
        switch c {
        case .teleop(let v, let w, let ttl):
            return ["v": r(v), "w": r(w), "ttl": ttl, "owner": agentID]
        case .goal(let x, let y, let z):
            return ["goal": z.map { [r(x), r(y), r($0)] } ?? [r(x), r(y)], "owner": agentID]
        case .goTo(let label, let oid, let x, let y):
            // the client's own pick (objects API) as a plain goal beside the object + the semantic target
            var t: [String: Any] = ["label": label]
            if let oid { t["object_id"] = oid }
            return ["goal": [r(x), r(y)], "target": t, "owner": agentID]
        case .goToLabel(let label):
            // S3 "go to the lamp": the server resolves the label (objects API) and plans
            return ["target": ["label": label], "owner": agentID]
        case .patrol(let pts):
            return ["patrol": pts.map { [r($0[0]), r($0[1])] }, "loop": true, "owner": agentID]
        case .stop:
            return ["v": 0, "w": 0, "ttl": TeleopSender.ttl, "stop": true, "owner": agentID]
        case .place(let x, let y, let z):
            return ["place": z.map { [r(x), r(y), r($0)] } ?? [r(x), r(y)], "owner": agentID]
        case .kick(let x, let y):
            return ["kick": [r(x), r(y)], "owner": agentID]
        case .behaviour(let b):
            return ["behaviour": b, "params": [String: Any](), "owner": agentID]
        case .flee(let x, let y, let sec):
            return ["flee": [r(x), r(y)], "seconds": min(10, max(0.5, sec)), "owner": agentID]
        case .followAgent(let a):
            return ["follow": ["agent": a], "owner": agentID]
        case .droneOp(let o):
            return [o: true, "owner": agentID]
        case .mission(let g, let mode, let canopy):
            return ["mission": ["goal": g.prefix(3).map { r($0) }, "mode": mode, "canopy": canopy], "owner": agentID]
        }
    }

    /// Spawn body: {kind, pose{x,y,z,theta}, agent_type?, owner}.
    public static func spawnBody(kind: String, x: Double, y: Double, z: Double, theta: Double, agentID: String) -> Data {
        var o: [String: Any] = ["kind": kind, "pose": ["x": r(x), "y": r(y), "z": r(z), "theta": r(theta)], "owner": agentID]
        if kind == "sim-rover" || kind == "sim-drone" { o["agent_type"] = kind }
        return json(o)
    }

    static func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// "Go to the lamp": pick the object nearest to `from` whose label / name matches (API §8.6 robot use), and a goal on
/// the floor beside its box, on the side facing `from`.
public enum SemanticGoal {
    public static func pick(_ objs: [ARObject], query: String, from p: [Double]) -> ARObject? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return objs.filter { $0.centroid.count >= 3 }
            .filter { $0.label.lowercased().contains(q) || ($0.name ?? "").lowercased().contains(q) }
            .min { hypot($0.centroid[0] - p[0], $0.centroid[1] - p[1]) < hypot($1.centroid[0] - p[0], $1.centroid[1] - p[1]) }
    }

    /// A point `clearance` m outside the object's footprint toward `from` (map XY).
    public static func standoff(_ o: ARObject, from p: [Double], clearance: Double = 0.5) -> [Double] {
        let c = o.box?.center.count == 3 ? o.box!.center : o.centroid
        let half = (o.box?.size.count == 3) ? max(o.box!.size[0], o.box!.size[1]) / 2 : 0.15
        var dx = p[0] - c[0], dy = p[1] - c[1]
        let n = hypot(dx, dy)
        if n < 1e-6 { dx = 1; dy = 0 } else { dx /= n; dy /= n }
        return [c[0] + dx * (half + clearance), c[1] + dy * (half + clearance)]
    }
}


// MARK: - protocol snailsight-sim/2: one master world, shared clips (API §5.9.10)

/// Server clock estimate: offset = server − local. Each snapshot gives `t − receivedAt` (true offset minus the
/// delivery delay); the largest recent sample is the least delayed, so keep the max over a window and let it decay
/// slowly (a server clock step backwards is followed within `window` s).
public struct SimServerClock: Equatable {
    public private(set) var offset: Double?
    private var samples: [(at: Double, off: Double)] = []
    public static let window = 5.0
    public init() {}

    public static func == (a: SimServerClock, b: SimServerClock) -> Bool { a.offset == b.offset }

    public mutating func observe(serverTime t: Double, receivedAt local: Double) {
        samples.append((local, t - local))
        samples.removeAll { local - $0.at > Self.window }
        offset = samples.map(\.off).max()
    }

    /// Server time now (nil until the first snapshot).
    public func serverNow(local: Double) -> Double? { offset.map { local + $0 } }
}

/// Which clip file to show for the server's clip, and where in it (the same phase on every client).
public enum SimSharedClip {
    /// Server clip name → the app's clip key among those loaded (eat / idle / walk / run / static), with the local
    /// sim's fallbacks (SimClips.candidates).
    public static func key(_ serverClip: String?, available: Set<String>) -> String? {
        let gait: AnimalGait
        switch serverClip ?? "idle" {
        case "eat", "graze": gait = .graze
        case "walk", "move", "drive": gait = .walk
        case "run", "flee": gait = .run
        default: gait = .still
        }
        return SimClips.pick(gait, available: available) ?? available.sorted().first
    }

    /// Seconds into the clip: ((serverNow − clipT0) × rate) mod duration; 0 when unknown.
    public static func time(clipT0: Double?, rate: Double?, serverNow: Double?, duration: Double) -> Double {
        guard let t0 = clipT0, let now = serverNow, duration > 1e-6 else { return 0 }
        let x = (now - t0) * (rate ?? 1)
        let m = x.truncatingRemainder(dividingBy: duration)
        return m < 0 ? m + duration : m
    }
}

/// What a server body is drawn as (the local sim's own models; a box only for an unknown kind).
public enum SimServerVisual: Equatable {
    case animal(key: String, scale: Double)
    case object(key: String, scale: Double)
    case robot(scale: Double)
    case drone
    case box

    /// `animalKeys` / `objectKeys`: the bundled catalog's keys.
    public static func of(_ s: SimEntitySnap, animalKeys: Set<String>, objectKeys: Set<String>) -> SimServerVisual {
        let sc = min(2.0, max(0.1, s.scale ?? SimServerVisual.defaultScale(s)))
        if s.isDrone { return .drone }
        if s.isRover { return .robot(scale: sc) }
        if animalKeys.contains(s.kind) { return .animal(key: s.kind, scale: sc) }
        if objectKeys.contains(s.kind) { return .object(key: s.kind, scale: sc) }
        return .box
    }

    /// An older server without `scale`: 1.0 (what it simulated with).
    static func defaultScale(_ s: SimEntitySnap) -> Double { 1.0 }
}


// MARK: - 10.6: one selection / command path (local + server), acks, trash, spawn mode

public extension SimCommand {
    /// The commands the selection bar offers for a body. ONE list for the local and the server sim (10.6: the server
    /// bar had none for animals). Owner list: Go to / Roam / Stay / Flee / Follow me / Delete.
    static func offered(role: SimKind.Role, drone: Bool = false, server: Bool) -> [SimCommand] {
        switch role {
        case .animal:
            return server ? [.goTo, .roam, .stay, .flee, .follow, .graze, .wander, .delete] : available(for: SimKind(key: "a", role: .animal))
        case .robot:
            if drone { return [.goTo, .patrol, .stop, .delete] }
            return server ? [.goTo, .follow, .stop, .patrol, .delete] : available(for: .robot)
        case .object:
            return server ? [.delete] : available(for: .block)
        }
    }

    /// The server command for a bar command that needs no floor point (nil = needs a point / handled elsewhere).
    /// `phone`: this phone's map position (Flee runs away from it; Follow me follows this agent).
    func serverCommand(agentID: String, phone: [Double]?) -> SimServerAPI.Command? {
        switch self {
        case .stop, .stay: return .stop
        case .roam: return .behaviour("roam")
        case .graze: return .behaviour("graze")
        case .wander: return .behaviour("wander")
        case .flee:
            guard let p = phone, p.count >= 2 else { return nil }
            return .flee(fromX: p[0], fromY: p[1], seconds: 4)
        case .follow: return .followAgent(agentID)
        default: return nil
        }
    }
}

public extension SimEntitySnap {
    /// Role for the bar (robot / animal / object), drones as robots.
    var role: SimKind.Role {
        if isRover || isDrone { return .robot }
        if isObject { return .object }
        return .animal
    }
}

/// Commands sent over the WebSocket wait for the server's ack (sim_cmd {cmd, id, ack} in the log).
public struct SimAcks: Equatable {
    public struct Pending: Equatable {
        public var cmd: String, id: String, sentAt: Double
    }
    private var pending: [String: Pending] = [:]
    private var seq = 0
    public static let timeout = 3.0
    public init() {}

    public var count: Int { pending.count }

    public mutating func register(cmd: String, id: String, now: Double) -> String {
        seq += 1
        let ref = "c\(seq)"
        pending[ref] = Pending(cmd: cmd, id: id, sentAt: now)
        return ref
    }

    public mutating func resolve(_ ref: String) -> Pending? { pending.removeValue(forKey: ref) }

    /// Commands with no ack after `timeout` (removed).
    public mutating func expired(now: Double) -> [(ref: String, Pending)] {
        let old = pending.filter { now - $0.value.sentAt > Self.timeout }
        for k in old.keys { pending[k] = nil }
        return old.map { ($0.key, $0.value) }.sorted { $0.ref < $1.ref }
    }
}

/// Drag a body onto the trash can (bottom centre) to delete it.
public enum SimTrash {
    public static let width = 150.0, height = 150.0
    public static func hit(x: Double, y: Double, viewWidth: Double, viewHeight: Double) -> Bool {
        abs(x - viewWidth / 2) <= width / 2 && y >= viewHeight - height
    }
}
