import Foundation

// Animal behaviours for SnailSight S1, ported from the snailCOP wargame engine (services/wargame/entities.py) with
// indoor numbers (plan §7 S table):
//   Graze  (entities.py:319)  dwell 6–14 s head-down / move 2–5 s on a persistent (OU) wander heading
//   StopGo (entities.py:544)  stand 5–12 s / shuffle 1–3 m on a ±90° turn (gz kernel sim_actors._b_stopgo)
//   Flee._step_bounded (entities.py:879)  threat inside scare radius → bounded dash (flee_dist ± jitter) away,
//          deflecting around obstacles → settle facing the threat → resume only when the threat is past
//          scare + resume_extra
//   _Base._advance deflect fan (entities.py:235, _DEFLECT = ±30…±150, 180)
// Threats are the sim robot AND the phone (the person holding it). Same phase names as the Python so S2 can run the
// Python module server-side and both stay comparable.

public enum CalmBehavior: String, Equatable { case graze, stopgo }

public struct SpeciesProfile: Equatable {
    public var name: String              // also the model file prefix: <name>_<clip>.usdz
    public var radius: Double            // body radius for spacing / clearance (m)
    public var calm: CalmBehavior
    public var dwell: ClosedRange<Double> = 6...14      // graze: head-down seconds
    public var moveTime: ClosedRange<Double> = 2...5    // graze: walking seconds
    public var pause: ClosedRange<Double> = 5...12      // stopgo: standing seconds
    public var hop: ClosedRange<Double> = 1...3         // stopgo: shuffle metres
    public var walkSpeed: Double
    public var turnSigmaDeg: Double = 60                // OU turn-rate noise (deg/s/√s), entities.py turn_sigma
    public var turnTheta: Double = 1.2                  // OU mean reversion (1/s), entities.py turn_theta
    public var scareRobot: Double                       // m
    public var scarePerson: Double                      // m
    public var fleeSpeed: Double
    public var fleeDist: Double
    public var fleeJitter: Double
    public var settle: Double = 3
    public var resumeExtra: Double = 1
    public var calmTurnRate: Double = 2.5               // rad/s
    public var fleeTurnRate: Double = 6.0               // rad/s
    public var accel: Double = 2.0                      // m/s² calm
    public var fleeAccel: Double = 6.0                  // m/s² bolting
    public var runAbove: Double                         // clip: run above this speed (hysteresis below)
    public var lookahead: Double = 0.45                 // free-space probe ahead of the body (m)

    public init(name: String, radius: Double, calm: CalmBehavior, walkSpeed: Double, scareRobot: Double,
                scarePerson: Double, fleeSpeed: Double, fleeDist: Double, fleeJitter: Double, runAbove: Double) {
        self.name = name; self.radius = radius; self.calm = calm; self.walkSpeed = walkSpeed
        self.scareRobot = scareRobot; self.scarePerson = scarePerson; self.fleeSpeed = fleeSpeed
        self.fleeDist = fleeDist; self.fleeJitter = fleeJitter; self.runAbove = runAbove
    }

    /// Quaternius Stag (1.5 m long). snailCOP outdoor deer: scare 12 m, flee 8 m/s for 14 m; indoors that would cross
    /// the basement in a second, so: scare 1.8 m (robot) / 1.2 m (you), bolt 2.5 m/s for 3 m ± 0.8.
    public static let deer: SpeciesProfile = {
        var p = SpeciesProfile(name: "deer", radius: 0.35, calm: .graze, walkSpeed: 0.5, scareRobot: 1.8,
                               scarePerson: 1.2, fleeSpeed: 2.5, fleeDist: 3.0, fleeJitter: 0.8, runAbove: 1.2)
        p.lookahead = 0.6
        return p
    }()

    public static let fox: SpeciesProfile = {
        var p = SpeciesProfile(name: "fox", radius: 0.22, calm: .stopgo, walkSpeed: 0.6, scareRobot: 1.5,
                               scarePerson: 1.0, fleeSpeed: 2.2, fleeDist: 2.5, fleeJitter: 0.6, runAbove: 1.1)
        p.turnSigmaDeg = 55
        return p
    }()

    public static let rabbit: SpeciesProfile = {
        var p = SpeciesProfile(name: "rabbit", radius: 0.15, calm: .graze, walkSpeed: 0.35, scareRobot: 1.2,
                               scarePerson: 0.9, fleeSpeed: 1.8, fleeDist: 1.8, fleeJitter: 0.5, runAbove: 0.9)
        p.dwell = 4...10
        p.moveTime = 1...3
        p.turnSigmaDeg = 80
        p.lookahead = 0.3
        return p
    }()

    public static let all: [SpeciesProfile] = [.deer, .fox, .rabbit]
}

public enum ThreatKind: String, Equatable { case robot, person }

public struct Threat: Equatable {
    public var pos: V2
    public var kind: ThreatKind
    public init(pos: V2, kind: ThreatKind) { self.pos = pos; self.kind = kind }
}

/// Phases, named as in entities.py: graze (dwell/move), stopgo (stand/walk), flee (dash/settle); plus the commanded
/// phases (9.4): `go` (walking a path or following the phone) and `hold` (Stay).
public enum AnimalPhase: String, Equatable { case dwell, move, stand, walk, dash, settle, go, hold }

/// Owner commands (9.4 command bar). `wander` = the autonomous snailCOP behaviour (graze or stop-go per species).
public enum AnimalOrder: Equatable {
    case wander
    case graze                 // stay put, head down (still bolts from threats)
    case stay                  // stand still, ignores everything
    case flee                  // bolt away from you now, then back to wandering
    case goTo([V2])            // walk a planned path, then graze there
    case follow                // keep ~1 m from you (you are no longer a threat)
    case roam                  // P2a "Roam this room": wander (graze / stop-go) but never leave the home area
    case pace([V2])            // P2a "Pace here": walk this loop round the home area, short pauses at each point

    public var isPace: Bool { if case .pace = self { return true } else { return false } }

    public var name: String {
        switch self {
        case .wander: return "wander"
        case .graze: return "graze"
        case .stay: return "stay"
        case .flee: return "flee"
        case .goTo: return "goto"
        case .follow: return "follow"
        case .roam: return "roam"
        case .pace: return "pace"
        }
    }
}

/// What the animation should show.
public enum AnimalGait: String, Equatable { case still, graze, alert, walk, run }

public struct AnimalState: Equatable {
    public var pos: V2
    public var heading: Double
    public var speed: Double = 0
    public var phase: AnimalPhase
    public var phaseLeft: Double
    public var omegaDeg: Double = 0          // OU wander turn rate
    public var hopHeading: Double = 0
    public var dashLeft: Double = 0
    public var threat: V2?
    public var gait: AnimalGait = .still
}

public struct AnimalBrain {
    public private(set) var profile: SpeciesProfile
    public private(set) var state: AnimalState
    private var rng: SplitMix64
    /// True when the last step found every heading of the deflect fan blocked (boxed in).
    public private(set) var lastBlocked = false
    public private(set) var order: AnimalOrder = .wander
    private var pathIndex = 0
    /// P2a home area (world ground frame): .roam and .pace keep the animal inside it (a scare may still chase it out;
    /// it walks back afterwards).
    public private(set) var home: [V2]?
    private var paceStuck = 0.0
    public static let followDistance = 1.0
    public static let paceStuckLimit = 3.0
    public static let waypointReach = 0.25

    public static let deflect: [Double] = ([30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180] as [Double]).map { $0 * Double.pi / 180 }

    public init(profile: SpeciesProfile, pos: V2, heading: Double, seed: UInt64) {
        self.profile = profile
        let calmPhase: AnimalPhase = profile.calm == .graze ? .dwell : .stand
        var r = SplitMix64(seed: seed)
        let left = profile.calm == .graze ? r.uniform(profile.dwell) : r.uniform(profile.pause)
        rng = r
        state = AnimalState(pos: pos, heading: SimMath.wrap(heading), phase: calmPhase, phaseLeft: left)
    }

    /// P2a: set (or clear) the home area, world ground frame.
    public mutating func setHome(_ polygon: [V2]?) {
        home = (polygon?.count ?? 0) >= 3 ? polygon : nil
    }

    /// Index of the current pace waypoint (tests / logs).
    public var paceIndex: Int { pathIndex }

    /// True when the order keeps the animal inside its home area.
    public var homeBound: Bool { home != nil && (order == .roam || order.isPace) }

    /// Apply an owner command. `person` = the phone's ground position (Flee runs from it).
    public mutating func setOrder(_ o: AnimalOrder, person: V2? = nil) {
        order = o
        pathIndex = 0
        paceStuck = 0
        switch o {
        case .wander, .graze, .roam: startCalm()
        case .pace(let loop):
            pathIndex = loop.indices.min(by: { SimMath.length(loop[$0] - state.pos) < SimMath.length(loop[$1] - state.pos) }) ?? 0
            state.phase = .go
            state.threat = nil
        case .stay:
            state.phase = .hold
            state.threat = nil
        case .flee:
            state.phase = .dash
            state.threat = person ?? (state.pos - SimMath.unit(state.heading))
            state.dashLeft = max(1.0, profile.fleeDist + rng.uniform(-1, 1) * profile.fleeJitter)
        case .goTo(let path):
            pathIndex = path.count > 1 ? 1 : 0
            state.phase = .go
            state.threat = nil
        case .follow:
            state.phase = .go
            state.threat = nil
        }
    }

    /// Owner Move / Rotate: put it somewhere else (keeps its order; a dash or Go to path is dropped).
    public mutating func teleport(to pos: V2, heading: Double? = nil) {
        state.pos = pos
        if let h = heading { state.heading = SimMath.wrap(h) }
        state.speed = 0
        if case .goTo = order { order = .graze; startCalm() }
        if state.phase == .dash || state.phase == .settle { resume() }
    }

    /// 9.9 knocked / standing back up: the rigid body moves it; the brain only follows (order, phase and path are kept,
    /// speed 0, standing still). A Go to path is replanned by nobody, so it simply resumes toward its next waypoint.
    public mutating func place(at pos: V2, heading: Double? = nil) {
        state.pos = pos
        if let h = heading { state.heading = SimMath.wrap(h) }
        state.speed = 0
        state.gait = .still
    }

    /// 9.9: running from something (it may hop down from a table edge, ElevatedNav).
    public var isFleeing: Bool { state.phase == .dash }

    /// 9.8 Sim scale: swap in the profile at a new scale (speeds, radius, distances); state and order are kept, a
    /// current speed above the new limits is clamped.
    public mutating func setProfile(_ p: SpeciesProfile) {
        profile = p
        state.speed = min(state.speed, max(p.fleeSpeed, p.walkSpeed))
        if state.phase == .dash { state.dashLeft = min(state.dashLeft, p.fleeDist + p.fleeJitter) }
    }

    /// 9.8: something hit it (a thrown ball, a falling cup): a short bolt away from `from` that does NOT change the
    /// owner's order (a pacing animal goes back to pacing afterwards). Stay ignores it.
    public mutating func startle(from p: V2) {
        guard order != .stay else { return }
        state.phase = .dash
        state.threat = p
        state.dashLeft = max(0.3, profile.fleeDist * 0.5)
    }

    /// Re-route a Go to without restarting the order (a fresh plan from the app).
    public mutating func replaceRoute(_ path: [V2]) {
        guard case .goTo = order else { return }
        order = .goTo(path)
        pathIndex = path.count > 1 ? 1 : 0
    }

    /// The threat that spooks it now (nearest one inside its radius for that kind), if any.
    public func trigger(_ threats: [Threat]) -> Threat? {
        var best: (Threat, Double)?
        for t in threats {
            let d = SimMath.length(t.pos - state.pos)
            let r = t.kind == .robot ? profile.scareRobot : profile.scarePerson
            if d < r, best == nil || d < best!.1 { best = (t, d) }
        }
        return best?.0
    }

    /// One fixed step. `others` = other agents (positions + radii) to keep clear of.
    public mutating func step(dt: Double, world: SimWorld, threats allThreats: [Threat],
                              others: [(pos: V2, radius: Double)] = [], leader: V2? = nil) {
        guard dt > 0 else { return }
        lastBlocked = false
        // Stay ignores everything; Follow me does not fear the person it follows (the robot still scares it).
        let threats: [Threat]
        switch order {
        case .stay: threats = []
        case .follow: threats = allThreats.filter { $0.kind != .person }
        default: threats = allThreats
        }
        if let t = trigger(threats) {
            if state.phase != .dash {
                state.dashLeft = max(1.0, profile.fleeDist + rng.uniform(-1, 1) * profile.fleeJitter)
            }
            state.phase = .dash
            state.threat = t.pos
        }
        let p = profile
        // P2a: calm movement under .roam / .pace may not leave the home area (a dash may; it walks back after)
        let calm: SimWorld = homeBound ? HomeWorld(base: world, home: home!) : world
        switch state.phase {
        case .dash:
            let away: Double
            if let t = state.threat, SimMath.length(state.pos - t) > 1e-6 { away = SimMath.heading(state.pos - t) }
            else { away = state.heading }
            let before = state.pos
            let moved = advance(speed: p.fleeSpeed, desired: away, accel: p.fleeAccel, turnRate: p.fleeTurnRate,
                                dt: dt, world: world, others: others)
            state.dashLeft -= SimMath.length(state.pos - before)
            if state.dashLeft <= 0 || !moved {
                state.phase = .settle
                state.phaseLeft = p.settle
            }
            updateGait()
        case .settle:
            // stand alert facing the nearest threat; resume only once every threat is comfortably far
            brake(dt: dt, accel: p.fleeAccel, world: world, others: others)
            if let t = nearest(threats) {
                state.heading = SimMath.turnToward(state.heading, SimMath.heading(t.pos - state.pos),
                                                   maxStep: p.calmTurnRate * dt)
            }
            state.phaseLeft -= dt
            if state.phaseLeft <= 0 {
                if allFar(threats) { resume() } else { state.phaseLeft = p.settle }
            }
            state.gait = state.speed > 0.05 ? .run : .alert
        case .dwell:
            brake(dt: dt, accel: p.accel, world: calm, others: others)
            state.phaseLeft -= dt
            if state.phaseLeft <= 0 {
                if order.isPace { state.phase = .go }                               // Pace: pause over, walk on
                else if order == .graze { state.phaseLeft = rng.uniform(p.dwell) }  // Graze: stays put
                else {
                    state.phase = .move
                    state.phaseLeft = rng.uniform(p.moveTime)
                }
            }
            state.gait = state.speed > 0.05 ? .walk : .graze
        case .move:
            var h = wanderHeading(dt: dt)
            if let back = homeward() { h = back; state.omegaDeg = 0 }          // outside (after a scare): walk back
            advance(speed: p.walkSpeed, desired: h, accel: p.accel, turnRate: p.calmTurnRate,
                    dt: dt, world: calm, others: others)
            state.phaseLeft -= dt
            if state.phaseLeft <= 0 {
                state.phase = .dwell
                state.phaseLeft = rng.uniform(p.dwell)
            }
            updateGait()
        case .stand:
            brake(dt: dt, accel: p.accel, world: calm, others: others)
            state.phaseLeft -= dt
            if state.phaseLeft <= 0 && order == .graze { state.phaseLeft = rng.uniform(p.pause) }   // Idle: stays put
            if state.phaseLeft <= 0 && order.isPace { state.phase = .go }
            else if state.phaseLeft <= 0 {
                state.phase = .walk
                state.hopHeading = SimMath.wrap(state.heading + rng.uniform(-Double.pi / 2, Double.pi / 2))
                if let back = homeward() { state.hopHeading = back }
                state.phaseLeft = rng.uniform(p.hop) / max(p.walkSpeed, 1e-3)
            }
            state.gait = state.speed > 0.05 ? .walk : .still
        case .walk:
            if let back = homeward() { state.hopHeading = back }
            let moved = advance(speed: p.walkSpeed, desired: state.hopHeading, accel: p.accel,
                                turnRate: p.calmTurnRate, dt: dt, world: calm, others: others)
            if !moved { state.hopHeading = SimMath.wrap(state.hopHeading + .pi * 0.75) }
            state.phaseLeft -= dt
            if state.phaseLeft <= 0 {
                state.phase = .stand
                state.phaseLeft = rng.uniform(p.pause)
            }
            updateGait()
        case .hold:
            brake(dt: dt, accel: p.fleeAccel, world: world, others: others)
            state.gait = state.speed > 0.05 ? .walk : .still
        case .go:
            stepGo(dt: dt, world: order.isPace ? calm : world, others: others, leader: leader)
        }
    }

    /// Heading back into the home area when a home-bound animal is outside it (nil when inside / not home-bound).
    private func homeward() -> Double? {
        guard homeBound, let h = home, !Poly.contains(h, state.pos) else { return nil }
        return SimMath.heading(Poly.centroid(h) - state.pos)
    }

    /// Commanded walking: along the Go to path (then graze there) or after the phone (stop at followDistance).
    private mutating func stepGo(dt: Double, world: SimWorld, others: [(pos: V2, radius: Double)], leader: V2?) {
        let p = profile
        switch order {
        case .goTo(let path):
            guard !path.isEmpty else { order = .graze; startCalm(); return }
            while pathIndex < path.count - 1 && SimMath.length(path[pathIndex] - state.pos) < Self.waypointReach {
                pathIndex += 1
            }
            let target = path[pathIndex]
            if pathIndex == path.count - 1 && SimMath.length(target - state.pos) < Self.waypointReach {
                order = .graze                                   // arrived: graze there
                startCalm()
                return
            }
            advance(speed: p.walkSpeed, desired: SimMath.heading(target - state.pos), accel: p.accel,
                    turnRate: p.calmTurnRate, dt: dt, world: world, others: others)
            updateGait()
        case .pace(let loop):
            guard !loop.isEmpty else { order = home != nil ? .roam : .wander; startCalm(); return }
            if pathIndex >= loop.count { pathIndex = 0 }
            let target = loop[pathIndex]
            if SimMath.length(target - state.pos) < Self.waypointReach || paceStuck > Self.paceStuckLimit {
                pathIndex = (pathIndex + 1) % loop.count               // next corner (or skip one it cannot reach)
                paceStuck = 0
                state.speed = 0
                if profile.calm == .graze { state.phase = .dwell } else { state.phase = .stand }
                state.phaseLeft = rng.uniform(1.0...2.5)                // short look-round at each corner
                state.gait = .still
                return
            }
            let before = state.pos
            let moved = advance(speed: p.walkSpeed, desired: SimMath.heading(target - state.pos), accel: p.accel,
                                turnRate: p.calmTurnRate, dt: dt, world: world, others: others)
            if !moved || SimMath.length(state.pos - before) < 0.02 * p.walkSpeed * dt * 30 { paceStuck += dt }
            else { paceStuck = max(0, paceStuck - dt) }
            updateGait()
        case .follow:
            guard let l = leader else { brake(dt: dt, accel: p.accel, world: world, others: others); state.gait = .still; return }
            let d = SimMath.length(l - state.pos)
            if d <= Self.followDistance {
                brake(dt: dt, accel: p.accel, world: world, others: others)
                state.heading = SimMath.turnToward(state.heading, SimMath.heading(l - state.pos), maxStep: p.calmTurnRate * dt)
                state.gait = state.speed > 0.05 ? .walk : .alert
            } else {
                let speed = d > 3 ? min(p.walkSpeed * 2.5, p.fleeSpeed) : p.walkSpeed   // trot to catch up
                advance(speed: speed, desired: SimMath.heading(l - state.pos), accel: p.accel,
                        turnRate: p.calmTurnRate, dt: dt, world: world, others: others)
                updateGait()
            }
        default:
            resume()
        }
    }

    /// Back to what the current order wants after a scare.
    private mutating func resume() {
        state.threat = nil
        switch order {
        case .flee: order = .wander; startCalm()
        case .wander, .graze, .roam: startCalm()
        case .stay: state.phase = .hold
        case .goTo, .follow, .pace: state.phase = .go
        }
    }

    // MARK: internals

    private mutating func startCalm() {
        state.threat = nil
        if profile.calm == .graze {
            state.phase = .dwell
            state.phaseLeft = rng.uniform(profile.dwell)
        } else {
            state.phase = .stand
            state.phaseLeft = rng.uniform(profile.pause)
        }
    }

    private func nearest(_ threats: [Threat]) -> Threat? {
        threats.min { SimMath.length($0.pos - state.pos) < SimMath.length($1.pos - state.pos) }
    }

    private func allFar(_ threats: [Threat]) -> Bool {
        threats.allSatisfy { t in
            let r = (t.kind == .robot ? profile.scareRobot : profile.scarePerson) + profile.resumeExtra
            return SimMath.length(t.pos - state.pos) >= r
        }
    }

    /// OU-style persistent wander heading (entities.py `_wander_heading`).
    private mutating func wanderHeading(dt: Double) -> Double {
        let o = state.omegaDeg
        state.omegaDeg = o - profile.turnTheta * o * dt + profile.turnSigmaDeg * dt.squareRoot() * rng.normal()
        return SimMath.wrap(state.heading + state.omegaDeg * .pi / 180 * dt)
    }

    /// Slow down to a stop, still collision-checked while coasting.
    private mutating func brake(dt: Double, accel: Double, world: SimWorld, others: [(pos: V2, radius: Double)]) {
        state.speed = SimMath.approach(state.speed, 0, accel * dt)
        if state.speed > 0 { _ = stepForward(dt: dt, world: world, others: others) }
    }

    private mutating func updateGait() {
        // hysteresis: run above runAbove, back to walk below 75 % of it
        let run = state.gait == .run ? state.speed > profile.runAbove * 0.75 : state.speed > profile.runAbove
        if state.speed < 0.05 { state.gait = state.phase == .dash ? .alert : .still }
        else { state.gait = run ? .run : .walk }
    }

    /// Pick a free heading near `desired` (deflect fan), turn toward it at a bounded rate, ramp the speed and move.
    /// Returns false when every heading is blocked (boxed in).
    @discardableResult
    private mutating func advance(speed: Double, desired: Double, accel: Double, turnRate: Double, dt: Double,
                                  world: SimWorld, others: [(pos: V2, radius: Double)]) -> Bool {
        var chosen: Double?
        for off in [0.0] + Self.deflect {
            let h = SimMath.wrap(desired + off)
            let probe = state.pos + SimMath.unit(h) * max(profile.lookahead, speed * dt)
            if world.isFree(from: state.pos, to: probe, radius: profile.radius),
               !SimCollide.agentBlocked(from: state.pos, to: probe, radius: profile.radius, others: others) {
                chosen = h
                break
            }
        }
        guard let target = chosen else {
            lastBlocked = true
            state.speed = 0
            return false
        }
        state.heading = SimMath.turnToward(state.heading, target, maxStep: turnRate * dt)
        // walk only roughly where it is facing; turn in place first on sharp turns (no moonwalking)
        let facing = abs(SimMath.wrap(target - state.heading)) < .pi / 3
        state.speed = SimMath.approach(state.speed, facing ? speed : 0, accel * dt)
        return stepForward(dt: dt, world: world, others: others) || !facing
    }

    /// Move along the current heading at the current speed if the short step is free.
    private mutating func stepForward(dt: Double, world: SimWorld, others: [(pos: V2, radius: Double)]) -> Bool {
        let d = state.speed * dt
        guard d > 0 else { return true }
        let next = state.pos + SimMath.unit(state.heading) * d
        let probe = state.pos + SimMath.unit(state.heading) * (d + profile.radius)
        guard world.isFree(from: state.pos, to: probe, radius: profile.radius * 0.8),
              !SimCollide.agentBlocked(from: state.pos, to: next, radius: profile.radius, others: others) else {
            state.speed = 0
            return false
        }
        state.pos = next
        return true
    }
}


/// P2a: the scene answers "is it free", the home polygon adds "and still inside". Stepping out is refused unless the
/// body is already outside and the step brings it closer to the centre (so a scared animal can walk home).
struct HomeWorld: SimWorld {
    let base: SimWorld
    let home: [V2]
    let centre: V2

    init(base: SimWorld, home: [V2]) {
        self.base = base
        self.home = home
        centre = Poly.centroid(home)
    }

    func isFree(from a: V2, to b: V2, radius: Double) -> Bool {
        if !Poly.contains(home, b) {
            if Poly.contains(home, a) || SimMath.length(b - centre) >= SimMath.length(a - centre) { return false }
        }
        return base.isFree(from: a, to: b, radius: radius)
    }
}
