import Foundation

// SnailSight S1 selection + commands (owner 9.3.65: "tap to select any sim entity → highlight + label; move, rotate,
// delete, duplicate; animal behaviours; robot Go to / Follow me / Stop / Patrol").

/// A pickable body: oriented box in the ARKit world frame (y up), yaw about +y = ground heading θ.
public struct PickBody: Equatable {
    public var id: Int
    public var center: SIMD3<Double>
    public var size: SIMD3<Double>          // (length along heading, height, width)
    public var yaw: Double
    public init(id: Int, center: SIMD3<Double>, size: SIMD3<Double>, yaw: Double) {
        self.id = id; self.center = center; self.size = size; self.yaw = yaw
    }
}

public enum SimPick {
    /// Small things are hard to hit with a finger: boxes are grown to at least this size for picking.
    public static let minPickSize = 0.25

    /// Distance along the ray to an oriented box (slab test in the box frame), nil = miss.
    public static func rayBox(origin: SIMD3<Double>, dir: SIMD3<Double>, body b: PickBody) -> Double? {
        // world → box frame: undo the yaw about +y (θ is CCW seen from above in the ground frame, where ground
        // y = −world z; RealityKit's yaw(θ) about +y maps local +x to (cos θ, 0, −sin θ)).
        let c = cos(b.yaw), s = sin(b.yaw)
        func toLocal(_ v: SIMD3<Double>) -> SIMD3<Double> {
            // inverse of R_y(θ): x' = c·x − s·z, z' = s·x + c·z
            SIMD3(c * v.x - s * v.z, v.y, s * v.x + c * v.z)
        }
        let o = toLocal(origin - b.center), d = toLocal(dir)
        let half = SIMD3(max(b.size.x, minPickSize), max(b.size.y, minPickSize), max(b.size.z, minPickSize)) / 2
        var tmin = -Double.infinity, tmax = Double.infinity
        for k in 0..<3 {
            if abs(d[k]) < 1e-12 {
                if o[k] < -half[k] || o[k] > half[k] { return nil }
            } else {
                var t1 = (-half[k] - o[k]) / d[k], t2 = (half[k] - o[k]) / d[k]
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1); tmax = min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        if tmax < 0 { return nil }
        return max(tmin, 0)
    }

    /// Nearest body hit by the ray, nil = none.
    public static func pick(origin: SIMD3<Double>, dir: SIMD3<Double>, bodies: [PickBody]) -> Int? {
        var best: (Int, Double)?
        for b in bodies {
            if let t = rayBox(origin: origin, dir: dir, body: b), best == nil || t < best!.1 { best = (b.id, t) }
        }
        return best?.0
    }

    /// The local x axis of a body with ground heading θ, in world coordinates (sanity for the yaw convention).
    public static func forward(yaw: Double) -> SIMD3<Double> { SIMD3(cos(yaw), 0, -sin(yaw)) }
}

public enum SimCommand: String, CaseIterable, Equatable {
    // everyone
    case move, rotateLeft, rotateRight, duplicate, delete
    // agents
    case goTo, follow, stop, patrol
    // 12.5 drivable bodies (robot, rc_car): opens the joystick
    case drive
    // animals
    case flee, graze, stay, wander
    // animals, P2a: live in the room they were put in
    case roam, pace

    public var label: String {
        switch self {
        case .move: return "Move"
        case .rotateLeft: return "⟲ 45°"
        case .rotateRight: return "⟳ 45°"
        case .duplicate: return "Duplicate"
        case .delete: return "Delete"
        case .goTo: return "Go to"
        case .follow: return "Follow me"
        case .stop: return "Stop"
        case .patrol: return "Patrol"
        case .flee: return "Flee"
        case .graze: return "Graze"
        case .stay: return "Stay"
        case .wander: return "Wander"
        case .roam: return "Roam room"
        case .pace: return "Pace here"
        case .drive: return "Drive"
        }
    }

    public var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotateLeft: return "rotate.left"
        case .rotateRight: return "rotate.right"
        case .duplicate: return "plus.square.on.square"
        case .delete: return "trash"
        case .goTo: return "mappin.and.ellipse"
        case .follow: return "figure.walk"
        case .stop: return "stop.fill"
        case .patrol: return "point.topleft.down.to.point.bottomright.curvepath"
        case .flee: return "hare"
        case .graze: return "leaf"
        case .stay: return "hand.raised"
        case .wander: return "shuffle"
        case .roam: return "square.dashed"
        case .pace: return "arrow.triangle.2.circlepath"
        case .drive: return "gamecontroller"
        }
    }

    /// Commands that wait for a tap on the floor (Patrol collects several, then Start).
    public var needsPoint: Bool { self == .move || self == .goTo || self == .patrol }

    public static func available(for kind: SimKind) -> [SimCommand] {
        switch kind.role {
        case .robot: return [.drive, .goTo, .follow, .stop, .patrol, .move, .rotateLeft, .rotateRight, .delete]
        case .animal:
            return [.pace, .roam, .goTo, .follow, .flee, .graze, .stay, .wander, .move, .rotateLeft, .rotateRight,
                    .duplicate, .delete]
        case .object: return [.move, .rotateLeft, .rotateRight, .duplicate, .delete]
        }
    }
}

/// What the robot is doing (behaviour state machine; the app turns goals into A* paths and the PathFollower).
public enum RobotTask: Equatable {
    case manual                       // joystick
    case goTo(V2)
    case follow                       // the phone, keeping `followDistance`
    case patrol([V2], next: Int)
    case stopped

    public var name: String {
        switch self {
        case .manual: return "manual"
        case .goTo: return "goto"
        case .follow: return "follow"
        case .patrol: return "patrol"
        case .stopped: return "stopped"
        }
    }
}

public struct RobotAgenda: Equatable {
    public private(set) var task: RobotTask = .manual
    public static let followDistance = 1.2
    public init() {}

    public mutating func goTo(_ p: V2) { task = .goTo(p) }
    public mutating func follow() { task = .follow }
    public mutating func stop() { task = .stopped }
    /// Needs at least two points (a single point is a Go to).
    public mutating func patrol(_ pts: [V2]) {
        if pts.count >= 2 { task = .patrol(pts, next: 0) } else if let p = pts.first { task = .goTo(p) }
    }

    /// Moving the joystick takes manual control back from any task.
    public mutating func stickMoved() { task = .manual }

    /// The current goal (ground frame); `phone` is the person's ground position for Follow me.
    public func goal(phone: V2) -> V2? {
        switch task {
        case .goTo(let p): return p
        case .follow: return phone
        case .patrol(let pts, let i): return pts[i]
        case .manual, .stopped: return nil
        }
    }

    public var stopDistance: Double { task == .follow ? Self.followDistance : 0 }

    /// The follower reached its goal: Go to ends (stopped), Patrol advances (wraps), Follow keeps following.
    public mutating func arrived() {
        switch task {
        case .goTo: task = .stopped
        case .patrol(let pts, let i): task = .patrol(pts, next: (i + 1) % pts.count)
        default: break
        }
    }

    /// Autonomous tasks drive the robot; manual / stopped leave it to the stick.
    public var isAutonomous: Bool {
        switch task {
        case .goTo, .follow, .patrol: return true
        default: return false
        }
    }
}
