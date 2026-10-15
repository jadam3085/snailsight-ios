import Foundation

/// The real robot's size and limits (not game numbers; plan §7 S "Robot size and limits").
/// Geometry (9.4, owner 9.3.65 "spawns about double its actual size"): the REAL base, not the URDF placeholder.
/// RoboSnailBob is a Quantum Q6 Edge 2.0 power-chair base (snailserve/robot/hardware.yml: overall 32.23 × 24.4 in =
/// 0.82 × 0.62 m, 14 in mid drive wheels with true radius 0.178 m, 6 in casters front and rear, 2.7 in ground
/// clearance) with the sensor head on top (L1 lidar top ≈ 0.61 m). The URDF (tank_robot.xacro: hull 0.76 × 0.60 m,
/// wheels r 0.19 at y ±0.34 → 0.76 m wide) is the tracked-tank era model and stays the source for sensor POSES only.
/// The drawn model is generated from `RobotModel.parts(profile)` so the unit test pins the spawned bounding box.
/// Limits: Nav2 0.30 m/s · 1.2 rad/s · 0.5 m/s² (robosnailbob-navigation/config/nav2_params.yaml), bringup yaw accel
/// 2.0 rad/s², the robot's own teleop MAX_LIN 0.4 m/s (robosnailbob-brain server_gui.py). The snailCOP game twin's
/// 1.6 m/s (services/wargame/spec.py TELEOP_DEFAULTS) is deliberately NOT used.
public struct RobotProfile: Equatable {
    public var name: String
    public var length: Double            // footprint along x (m)
    public var width: Double             // footprint across, wheels included (m)
    public var height: Double            // top of the sensor mast (m)
    public var trackWidth: Double        // wheel centre to wheel centre (m)
    public var wheelRadius: Double
    public var maxSpeed: Double          // forward stick limit (m/s)
    public var reverseScale: Double      // reverse = maxSpeed × this
    public var maxYawRate: Double        // rad/s
    public var maxWheelSpeed: Double     // per-track ground speed limit (m/s)
    public var accel: Double             // m/s²
    public var brake: Double             // m/s² (releasing the stick)
    public var yawAccel: Double          // rad/s²
    public var yawBrake: Double          // rad/s²
    public var maxStep: Double           // climbable step (m)
    public var maxDrop: Double           // deeper than this = cliff (m)
    /// Autonomous (Go to / Follow / Patrol) speed: the Nav2 cap, slower than the 0.4 m/s joystick.
    public var navSpeed: Double = 0.30

    public init(name: String, length: Double, width: Double, height: Double, trackWidth: Double, wheelRadius: Double,
                maxSpeed: Double, reverseScale: Double, maxYawRate: Double, maxWheelSpeed: Double, accel: Double,
                brake: Double, yawAccel: Double, yawBrake: Double, maxStep: Double, maxDrop: Double) {
        self.name = name; self.length = length; self.width = width; self.height = height
        self.trackWidth = trackWidth; self.wheelRadius = wheelRadius; self.maxSpeed = maxSpeed
        self.reverseScale = reverseScale; self.maxYawRate = maxYawRate; self.maxWheelSpeed = maxWheelSpeed
        self.accel = accel; self.brake = brake; self.yawAccel = yawAccel; self.yawBrake = yawBrake
        self.maxStep = maxStep; self.maxDrop = maxDrop
    }

    public static let robosnailbob = RobotProfile(
        name: "RobosnailBob", length: 0.82, width: 0.62, height: 0.61, trackWidth: 0.55, wheelRadius: 0.178,
        maxSpeed: 0.40, reverseScale: 0.6, maxYawRate: 1.2, maxWheelSpeed: 0.60, accel: 0.5, brake: 1.0,
        yawAccel: 2.0, yawBrake: 4.0, maxStep: 0.06, maxDrop: 0.10)

    /// Radius of the circle that contains the footprint.
    public var boundingRadius: Double { 0.5 * (length * length + width * width).squareRoot() }

    /// Spacing radius for other agents and the planner's inflation (half the width plus a margin; the footprint
    /// sweep against the scene mesh handles the long axis).
    public var agentRadius: Double { 0.5 * min(length, width) + 0.06 }
}

public struct DriveCommand: Equatable {
    public var v: Double                 // m/s, + forward
    public var omega: Double             // rad/s, + counter-clockwise (left)
    public init(v: Double, omega: Double) { self.v = v; self.omega = omega }
    public static let stop = DriveCommand(v: 0, omega: 0)
}

/// On-screen joystick → (v, ω). Stick: x right, y up, in the unit disc.
public struct StickShaper: Equatable {
    public var deadzone: Double = 0.12
    public var expo: Double = 0.45       // 0 = linear; higher = finer control near the centre
    public init(deadzone: Double = 0.12, expo: Double = 0.45) { self.deadzone = deadzone; self.expo = expo }

    /// Clamp to the unit disc, radial deadzone (rescaled so output starts at 0), expo per axis.
    public func shape(_ raw: V2) -> V2 {
        var s = raw
        let r = SimMath.length(s)
        if r > 1 { s /= r }
        let rr = min(r, 1)
        guard rr > deadzone else { return .zero }
        let k = (rr - deadzone) / (1 - deadzone) / rr      // rescale the magnitude, keep the direction
        s *= k
        func ex(_ v: Double) -> Double { (1 - expo) * v + expo * v * v * v }
        return V2(ex(s.x), ex(s.y))
    }

    /// Stick up = forward, stick right = turn right (clockwise, negative ω).
    public func command(_ raw: V2, profile p: RobotProfile) -> DriveCommand {
        let s = shape(raw)
        let v = s.y >= 0 ? s.y * p.maxSpeed : s.y * p.maxSpeed * p.reverseScale
        return DriveCommand(v: v, omega: -s.x * p.maxYawRate)
    }
}

public struct DrivePose: Equatable {
    public var x: Double, y: Double, theta: Double
    public init(x: Double, y: Double, theta: Double) { self.x = x; self.y = y; self.theta = theta }
    public var position: V2 { V2(x, y) }
}

/// Differential-drive (tracked) kinematics at fixed steps. Usage per tick: `setCommand` → `updateVelocities(dt)` →
/// `propose(dt)` → (app checks collisions against the real house) → `commit(pose)` or `bump()`.
public struct DiffDrive: Equatable {
    public var profile: RobotProfile
    public var pose: DrivePose
    public private(set) var v: Double = 0
    public private(set) var omega: Double = 0
    public private(set) var target = DriveCommand.stop
    public private(set) var commandAge: Double = .infinity
    /// No fresh command for this long → stop (link loss / app stall; S2 commands carry the same TTL).
    public var deadman: Double = 0.5

    public init(profile: RobotProfile = .robosnailbob, pose: DrivePose) { self.profile = profile; self.pose = pose }

    public mutating func setCommand(_ c: DriveCommand) {
        target = Self.limitWheels(c, profile: profile)
        commandAge = 0
    }

    /// Scale (v, ω) together so neither track exceeds `maxWheelSpeed` (a hard turn at speed slows down instead of
    /// asking the outer track for more than it has); also clamps to the stick limits.
    public static func limitWheels(_ c: DriveCommand, profile p: RobotProfile) -> DriveCommand {
        var v = SimMath.clamp(c.v, -p.maxSpeed * p.reverseScale, p.maxSpeed)
        var w = SimMath.clamp(c.omega, -p.maxYawRate, p.maxYawRate)
        let half = p.trackWidth / 2
        let peak = max(abs(v - w * half), abs(v + w * half))
        if peak > p.maxWheelSpeed && peak > 0 {
            let s = p.maxWheelSpeed / peak
            v *= s; w *= s
        }
        return DriveCommand(v: v, omega: w)
    }

    /// Track ground speeds (left, right) in m/s for the current (v, ω).
    public var wheelSpeeds: (left: Double, right: Double) {
        let half = profile.trackWidth / 2
        return (v - omega * half, v + omega * half)
    }

    /// Ramp (v, ω) toward the target with accel / brake limits; the deadman zeroes the target.
    public mutating func updateVelocities(dt: Double) {
        guard dt > 0 else { return }
        commandAge += dt
        let goal = commandAge > deadman ? DriveCommand.stop : target
        // braking = the goal is slower than now or on the other side of zero
        let vBrake = abs(goal.v) < abs(v) || goal.v * v < 0
        v = SimMath.approach(v, goal.v, (vBrake ? profile.brake : profile.accel) * dt)
        let wBrake = abs(goal.omega) < abs(omega) || goal.omega * omega < 0
        omega = SimMath.approach(omega, goal.omega, (wBrake ? profile.yawBrake : profile.yawAccel) * dt)
    }

    /// Exact unicycle integration of the current (v, ω) over dt; does not change state.
    public func propose(dt: Double) -> DrivePose {
        Self.integrate(pose, v: v, omega: omega, dt: dt)
    }

    public static func integrate(_ p: DrivePose, v: Double, omega: Double, dt: Double) -> DrivePose {
        if abs(omega) < 1e-9 {
            return DrivePose(x: p.x + v * cos(p.theta) * dt, y: p.y + v * sin(p.theta) * dt, theta: p.theta)
        }
        let th2 = p.theta + omega * dt
        let r = v / omega
        return DrivePose(x: p.x + r * (sin(th2) - sin(p.theta)), y: p.y - r * (cos(th2) - cos(p.theta)),
                         theta: SimMath.wrap(th2))
    }

    public mutating func commit(_ p: DrivePose) { pose = DrivePose(x: p.x, y: p.y, theta: SimMath.wrap(p.theta)) }

    /// Hit something it cannot slide along: stop translating (rotation keeps its rate so you can turn away).
    public mutating func bump() { v = 0 }
}
