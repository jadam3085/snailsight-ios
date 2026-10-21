import Foundation

// SnailSight 12.5 drivable bodies (owner: "If I select a RC car, let me control it like I do the robot").
// Server contract (API §5.9.10 "Drivable bodies", protocol snailsight-sim/2):
// - catalog items carry `drivable` + `drive` (diff | ackermann); a client falls back to kind ∈ {robot, rc_car}.
// - WS `cmd` {"drive": {"throttle": -1…1, "steer": -1…1, "tank": bool}, "ttl": 0.5}: throttle +1 = full forward,
//   steer +1 = turn RIGHT (stick right). ~10 Hz while the stick is held, one zero command on release.
// - rc_car = a 1/10 RC car (0.45 L × 0.16 H × 0.25 W m) drawn with the bundled Kenney toy car, scaled to that size.
// Also: the robot path tool's footprint at the body's sim scale, the selection-scoped overlay set, and the Follow me
// pose sender (12.5 owner items from a 12.4 screenshot).
// Pure, Linux-tested (DrivableTests).

public enum DriveKind: String, Equatable {
    case diff                  // robot: v / w
    case ackermann             // rc_car: bicycle model, cannot turn in place
}

public enum Drivable {
    public static let fallbackKinds: Set<String> = ["robot", "rc_car"]

    /// Drivable with the joystick: the catalog says so (when known), else robot / rc_car / sim rovers (not drones).
    public static func isDrivable(kind: String, cat: String? = nil, agentType: String? = nil,
                                  catalogDrivable: Bool? = nil) -> Bool {
        if let c = catalogDrivable { return c }
        if fallbackKinds.contains(kind) { return true }
        let drone = cat == "drone" || kind.contains("drone") || (agentType ?? "").contains("drone")
        if drone { return false }
        return kind.contains("rover") || (agentType ?? "").contains("rover") || cat == "robot"
    }

    /// How it steers (catalog `drive` when known): rc_car = ackermann, everything else = diff.
    public static func driveKind(kind: String, catalogDrive: String? = nil) -> DriveKind {
        if let d = catalogDrive, let k = DriveKind(rawValue: d) { return k }
        return kind == RCCar.key ? .ackermann : .diff
    }
}

/// The RC car body (server catalog item `rc_car`, group Vehicles).
public enum RCCar {
    public static let key = "rc_car"
    public static let label = "RC car"
    public static let group = "Vehicles"
    public static let symbol = "car.side.fill"
    public static let modelFile = "toycar.usdz"
    public static let thumb = "toycar.png"
    /// [length, height, width] at scale 1 (glTF y-up).
    public static let sizeM: [Double] = [0.45, 0.16, 0.25]
    /// The bundled toy car's own measured size (catalog.json `toycar`), used when the catalog row is missing.
    public static let toycarSizeM: [Double] = [0.25, 0.129, 0.15]
    public static let steerMaxRad = 0.41
    public static let vMax = 3.0

    /// Per-axis factor that turns the toy car model (measured `model` size) into the RC car at body `scale`.
    public static func modelScale(model: [Double]? = nil, scale: Double = 1) -> [Double] {
        let m = (model?.count == 3 ? model! : toycarSizeM)
        let s = scale.isFinite && scale > 0 ? scale : 1
        return (0..<3).map { m[$0] > 1e-6 ? sizeM[$0] / m[$0] * s : s }
    }

    /// Front wheel visual yaw (rad, + = left) from the snapshot's `steer`, clamped to the car's lock.
    public static func wheelYaw(steer: Double?) -> Double {
        guard let s = steer, s.isFinite else { return 0 }
        return SimMath.clamp(s, -steerMaxRad, steerMaxRad)
    }

    /// The spawn picker row when the server catalog is not on the phone (it is code-defined on the server).
    public static func catalogItem(physicsFrom toycar: SimCatalogItem? = nil) -> SimCatalogItem {
        SimCatalogItem(key: key, label: label, category: .object, group: group, symbol: symbol, sizeM: sizeM,
                       files: ["static": modelFile], physics: toycar?.physics, thumb: thumb)
    }
}

/// Stick (x right, y up, unit disc) → the `drive` command's throttle / steer.
public struct DriveStick: Equatable {
    public var deadzone: Double
    public var expo: Double
    public init(deadzone: Double = 0.12, expo: Double = 0.35) { self.deadzone = deadzone; self.expo = expo }

    /// Per-axis dead zone (a straight push does not also steer), rescaled so output starts at 0, then expo.
    public func map(_ raw: V2) -> (throttle: Double, steer: Double) {
        var s = raw
        let r = SimMath.length(s)
        if r > 1 { s /= r }
        func axis(_ v: Double) -> Double {
            let a = abs(v)
            guard a > deadzone else { return 0 }
            let k = min(1, (a - deadzone) / (1 - deadzone))
            let e = (1 - expo) * k + expo * k * k * k
            return v < 0 ? -e : e
        }
        return (axis(s.y), axis(s.x))
    }
}

/// One `drive` command (what goes on the wire).
public struct DriveInput: Equatable {
    public var throttle: Double
    public var steer: Double
    public var tank: Bool
    public init(throttle: Double, steer: Double, tank: Bool = false) {
        self.throttle = SimMath.clamp(throttle, -1, 1); self.steer = SimMath.clamp(steer, -1, 1); self.tank = tank
    }
    public static let zero = DriveInput(throttle: 0, steer: 0)
    public var isZero: Bool { abs(throttle) < DriveSender.deadband && abs(steer) < DriveSender.deadband }
}

/// 10 Hz while held, ttl 0.5 s deadman, one zero on release (the same lease as teleop server side).
public struct DriveSender: Equatable {
    public static let ttl = 0.5
    public static let every = 0.1
    public static let deadband = 0.02
    private var lastSent = -1e9
    private var lastWasZero = true
    public init() {}

    public mutating func next(_ d: DriveInput, now: Double) -> DriveInput? {
        if d.isZero {
            if lastWasZero { return nil }
            lastWasZero = true
            lastSent = now
            return DriveInput(throttle: 0, steer: 0, tank: d.tank)      // one explicit brake on release
        }
        guard now - lastSent >= Self.every || lastWasZero else { return nil }
        lastWasZero = false
        lastSent = now
        return d
    }

    /// Selection changed / joystick closed mid-drive: the next zero is sent again.
    public mutating func reset() { lastWasZero = false; lastSent = -1e9 }
}

/// What the joystick drives for the selected body: robot keeps its proven v / w teleop, the rc_car sends `drive`.
public enum DriveRoute: Equatable {
    case teleop(v: Double, w: Double)
    case drive(DriveInput)

    public static func make(stick: V2, kind: DriveKind, tank: Bool, robotShaper: StickShaper = StickShaper(),
                            driveStick: DriveStick = DriveStick(), profile: RobotProfile = .robosnailbob) -> DriveRoute {
        switch kind {
        case .diff:
            let c = robotShaper.command(stick, profile: profile)
            return .teleop(v: c.v, w: c.omega)
        case .ackermann:
            let m = driveStick.map(stick)
            return .drive(DriveInput(throttle: m.throttle, steer: m.steer, tank: tank))
        }
    }
}

// MARK: - robot path tool footprint (owner 12.4: "robot footprint is way too big and should be half that size")

public enum BodyFootprint {
    /// Drawn footprint [length, width] (m) for the body the robot path tool plans for. Entity docs' `dims` [L, W, H]
    /// are already scaled server side and win; else the profile × the body's sim scale (the server's planning
    /// footprint scales the same way). Before 12.5 the tool always drew 0.82 × 0.62 (scale 1).
    public static func size(dims: [Double]? = nil, scale: Double?, kind: String = "robot") -> [Double] {
        if let d = dims, d.count >= 2, d[0] > 0, d[1] > 0 { return [d[0], d[1]] }
        let s = (scale.map { $0.isFinite && $0 > 0 ? $0 : 1 }) ?? 1
        if kind == RCCar.key { return [RCCar.sizeM[0] * s, RCCar.sizeM[2] * s] }
        let p = RobotProfile.robosnailbob
        return [p.length * s, p.width * s]
    }

    /// The scale the tool plans for: the selected server body's, else the local sim robot's, else the global Sim
    /// scale while the sim is on, else 1 (the real robot).
    public static func planScale(selected: Double?, localRobot: Double?, simOn: Bool, global: Double) -> Double {
        if let s = selected, s > 0 { return s }
        if let s = localRobot, s > 0 { return s }
        return simOn ? SimScale.clampGlobal(global) : 1
    }
}

// MARK: - selection-scoped overlays (owner 12.4: selecting the chicken left the robot's path overlay drawn)

public enum SelectionOverlay: String, CaseIterable, Equatable {
    case pathPreview           // the selected body's planned route ribbon
    case goalMarkers           // Go to / patrol markers dropped for it
    case robotPathResult       // the Robot path tool's footprint ghost + dotted path
    case homeOutline           // an animal's home area
    case highlight             // selection box
    case ring                  // the command ring
    case joystick              // the drive joystick
}

/// Who owns which overlay; a selection change returns every overlay drawn for anything else.
public struct SelectionOverlays: Equatable {
    public private(set) var selected: String?
    private var owners: [SelectionOverlay: String?] = [:]
    public init() {}

    /// An overlay was drawn for `owner` (nil = no body: e.g. the tool planned from where you stand).
    public mutating func drew(_ o: SelectionOverlay, for owner: String?) { owners[o] = .some(owner) }
    public mutating func cleared(_ o: SelectionOverlay) { owners[o] = nil }
    public var drawn: Set<SelectionOverlay> { Set(owners.keys) }

    /// The selection changed (nil = deselected): the overlays to remove now. A different body, or none, clears
    /// everything that was drawn for the previous one (and body-less results); re-selecting the same body keeps them.
    public mutating func select(_ id: String?) -> Set<SelectionOverlay> {
        defer { selected = id }
        guard id != selected else { return [] }
        var out = Set<SelectionOverlay>()
        for (o, owner) in owners where owner != id || id == nil { out.insert(o) }
        for o in out { owners[o] = nil }
        return out
    }
}

// MARK: - Follow me pose sender (owner 12.4: "lost your position (no pose for 15 s)" while LOCALIZED)

/// Bodies following this phone and whether to send `agent_pose` now. 12.4 dropped a follower as soon as ANY snapshot
/// said behaviour != follow — including the snapshot already in flight when Follow was sent, and the stale entity-doc
/// behaviour merged into a snapshot that has none — so the pose stopped and the server reported "lost". Now a
/// follower is dropped only by another command from this phone, by the body going away, or by the server's OWN
/// snapshot behaviour saying it stopped following after a grace period.
public struct FollowPoseTracker: Equatable {
    public static let grace = 3.0
    public static let every = 0.5               // ~2 Hz
    public static let maxAge = 1800.0
    private var since: [String: Double] = [:]
    private var confirmed: Set<String> = []
    private var lastSent = -1e9
    public init() {}

    public var followers: Set<String> { Set(since.keys) }
    public var isEmpty: Bool { since.isEmpty }

    public mutating func follow(_ id: String, now: Double) { since[id] = now; confirmed.remove(id) }
    /// Another command for this body from this phone (goto, stop, drive …), a refused follow, or a delete.
    public mutating func drop(_ id: String) { since[id] = nil; confirmed.remove(id) }
    public mutating func dropAll() { since = [:]; confirmed = [] }

    /// A snapshot of `id` with the server's own (raw, unmerged) behaviour; nil behaviour = says nothing.
    public mutating func observe(_ id: String, behaviour: String?, now: Double) {
        guard let t0 = since[id], let b = behaviour else { return }
        if b == "follow" { confirmed.insert(id); return }
        if confirmed.contains(id) || now - t0 > Self.grace { drop(id) }
    }

    /// Send `agent_pose` now? (`alive`: ids the server world still has; `localized`: the phone knows its map pose).
    public mutating func shouldSend(now: Double, alive: Set<String>, localized: Bool) -> Bool {
        since = since.filter { alive.contains($0.key) && now - $0.value < Self.maxAge }
        confirmed.formIntersection(Set(since.keys))
        guard localized, !since.isEmpty, now - lastSent >= Self.every - 0.05 else { return false }
        lastSent = now
        return true
    }
}

/// GET …/sim/nav/query?x&y&z&scale&kind: the sim body's footprint cost at a point at ITS scale (the value the
/// server's motion check uses). 12.4 asked only the full-size terrain query, so the red "can't stand" ghost was the
/// 0.82 × 0.62 robot's answer for a half-size sim body.
public struct SimNavQueryAnswer: Decodable, Equatable {
    public var level: Int?
    public var known: Bool?
    public var cost: Double?
    public var lethal: Bool?
    public var floorZ: Double?
    public var blockedBody: Bool?
    public var scale: Double?
    enum CodingKeys: String, CodingKey {
        case level, known, cost, lethal, scale
        case floorZ = "floor_z", blockedBody = "blocked_body"
    }

    /// May the body stand there (nil = the server does not know the cell).
    public var fits: Bool? {
        guard known == true else { return nil }
        return lethal != true && blockedBody != true
    }

    public static func query(x: Double, y: Double, z: Double?, scale: Double, kind: String) -> [(String, String)] {
        var q: [(String, String)] = [("x", String(format: "%.3f", x)), ("y", String(format: "%.3f", y))]
        if let z { q.append(("z", String(format: "%.3f", z))) }
        q.append(("scale", String(format: "%.3f", SimMath.clamp(scale, 0.1, 2.0))))
        q.append(("kind", kind == RCCar.key ? RCCar.key : "robot"))
        return q
    }
}
