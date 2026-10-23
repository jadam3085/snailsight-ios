import Foundation

// SnailSight 12.7 twin-stick teleop with RoboSnailBob HUD parity (robosnailbob-bringup hud/static/index.html:
// setupStick, driveVec / driveRelease / turretVec, the gamepad module's dz() deadzone and stick layouts).
// - LEFT stick drives (throttle / steer; Tank toggle for the rc_car), RIGHT stick aims the turret (yaw from the
//   horizontal, pitch from the vertical, RATE control: the turret holds where it is when the stick is let go;
//   double-tap recentres). Layouts: default · southpaw (sticks swapped) · triggers (throttle = R2 − L2, steer =
//   left stick x, turret = right stick).
// - HUD feel: the HUD sends linear = −ny × 0.5 m/s (turbo 0.75: +50 %) and angular = −nx × 1.2 rad/s (turbo 1.8).
//   The app sends the server's normalised `drive {throttle, steer}` instead, keeping the HUD's normal / turbo RATIO:
//   normal = 0.5 / 0.75 = 0.667 of full, turbo = 1.0 of full (on both axes). Robot: v = throttle × v_teleop × scale
//   (0.4 m/s × 0.5 = 0.2 m/s full at the default scale → 0.133 m/s normal), w = −steer × w_max (1.2 rad/s → 0.8 normal).
//   rc_car: target speed = throttle × v_max (3 m/s → 2 m/s normal).
// - Release: no instant stop — the last stick values decay ×0.6 every 50 ms until both are < 0.03 (HUD driveRelease),
//   then one explicit zero. E-stop skips the ramp (zero + `stop` now, the lease is kept).
// - ONE 10 Hz WS message carries drive + turret when both sticks are held (API §5.9.10), ttl 0.5 s; each channel
//   gets one explicit zero when its stick is released (the turret stops at once instead of turning on for the TTL).
// Pure, Linux-tested (TeleopMapTests).

public enum TeleopFeel {
    /// The HUD's linear scales (m/s per full stick): normal / turbo.
    public static let hudNormal = 0.5
    public static let hudTurbo = 0.75
    /// Fraction of the server's full throttle / steer: normal = 0.5 / 0.75, turbo = 1.
    public static let normalFraction = hudNormal / hudTurbo
    public static let turboFraction = 1.0
    public static func fraction(turbo: Bool) -> Double { turbo ? turboFraction : normalFraction }

    // release decel ramp (HUD driveRelease)
    public static let decelFactor = 0.6
    public static let decelStep = 0.05
    public static let decelStop = 0.03

    /// Touch sticks: a small radial-free per-axis deadzone; the gamepad uses its configured one (0.15).
    public static let touchDeadzone = 0.08
    public static let padDeadzone = 0.15
}

/// The HUD's `dz()`: per-axis deadzone, rescaled so the output starts at 0 just past it.
public enum StickDeadzone {
    public static func apply(_ v: Double, _ d: Double) -> Double {
        let x = SimMath.clamp(v, -1, 1)
        guard d > 0 else { return x }
        guard abs(x) >= d else { return 0 }
        return (x - (x < 0 ? -d : d)) / (1 - d)
    }

    public static func apply(_ v: V2, _ d: Double) -> V2 { V2(apply(v.x, d), apply(v.y, d)) }
}

/// Which stick does what (HUD GP.stick).
public enum StickLayout: String, CaseIterable, Codable, Equatable {
    case standard = "default", southpaw, triggers
    public var label: String {
        switch self {
        case .standard: return "Default"
        case .southpaw: return "Southpaw"
        case .triggers: return "Triggers"
        }
    }
}

/// Raw twin-stick input: sticks x right / y UP (unit disc), analog triggers 0…1.
public struct TwinStickInput: Equatable {
    public var left: V2
    public var right: V2
    public var l2: Double
    public var r2: Double
    public init(left: V2 = .zero, right: V2 = .zero, l2: Double = 0, r2: Double = 0) {
        self.left = left; self.right = right; self.l2 = l2; self.r2 = r2
    }
}

/// After the layout + deadzone: what drives (x = steer right, y = throttle forward) and what aims (x right, y up).
public struct TwinStickAxes: Equatable {
    public var drive: V2
    public var turret: V2
    public init(drive: V2 = .zero, turret: V2 = .zero) { self.drive = drive; self.turret = turret }
}

public enum TwinStick {
    /// HUD readVec: default = left drives / right aims; southpaw swaps; triggers = throttle R2 − L2, steer left x.
    public static func resolve(_ i: TwinStickInput, layout: StickLayout, deadzone: Double) -> TwinStickAxes {
        let l = StickDeadzone.apply(i.left, deadzone), r = StickDeadzone.apply(i.right, deadzone)
        switch layout {
        case .standard: return TwinStickAxes(drive: l, turret: r)
        case .southpaw: return TwinStickAxes(drive: r, turret: l)
        case .triggers:
            let th = SimMath.clamp(i.r2, 0, 1) - SimMath.clamp(i.l2, 0, 1)
            return TwinStickAxes(drive: V2(l.x, StickDeadzone.apply(th, min(deadzone, 0.05))), turret: r)
        }
    }

    /// Drive axes → the server's `drive` command (HUD turbo ratio, sensitivity, unit-disc clamp).
    public static func drive(_ a: V2, turbo: Bool, tank: Bool, sensitivity: Double = 1) -> DriveInput {
        var s = a * max(0.1, sensitivity)
        let r = SimMath.length(s)
        if r > 1 { s /= r }
        let k = TeleopFeel.fraction(turbo: turbo)
        return DriveInput(throttle: s.y * k, steer: s.x * k, tank: tank)
    }

    /// Turret axes → rate command: stick right = turn right (yaw −), stick up = pitch up.
    public static func turret(_ a: V2, sensitivity: Double = 1) -> TurretCommand {
        let k = max(0.1, sensitivity)
        return .rate(yaw: SimMath.clamp(-a.x * k, -1, 1), pitch: SimMath.clamp(a.y * k, -1, 1))
    }
}

/// HUD driveRelease: the last drive values decay ×0.6 every 50 ms until both are < 0.03.
public struct DecelRamp: Equatable {
    private var from: DriveInput?
    private var t0 = 0.0
    public init() {}

    public var isActive: Bool { from != nil }

    public mutating func start(from d: DriveInput, now: Double) {
        guard !d.isZero else { from = nil; return }
        from = d; t0 = now
    }

    public mutating func cancel() { from = nil }

    /// The ramped command at `now`; nil once it has decayed (then the sender sends its one zero).
    public mutating func value(now: Double) -> DriveInput? {
        guard let f = from else { return nil }
        let steps = max(0, Int(((now - t0) / TeleopFeel.decelStep).rounded(.down)))
        let k = pow(TeleopFeel.decelFactor, Double(steps))
        let th = f.throttle * k, st = f.steer * k
        if abs(th) < TeleopFeel.decelStop && abs(st) < TeleopFeel.decelStop { from = nil; return nil }
        return DriveInput(throttle: th, steer: st, tank: f.tank)
    }

    /// Steps until the ramp is done from a given magnitude (≈ 7 from full stick = 350 ms).
    public static func steps(from m: Double) -> Int {
        var v = abs(m), n = 0
        while v >= TeleopFeel.decelStop && n < 100 { v *= TeleopFeel.decelFactor; n += 1 }
        return n
    }
}

/// One twin-stick message (drive and / or turret), sent as one WS `cmd`.
public struct TeleopMessage: Equatable {
    public var drive: DriveInput?
    public var turret: TurretCommand?
    public var ttl: Double
    public init(drive: DriveInput? = nil, turret: TurretCommand? = nil, ttl: Double = TeleopFrameSender.ttl) {
        self.drive = drive; self.turret = turret; self.ttl = ttl
    }
    public var isEmpty: Bool { drive == nil && turret == nil }
}

/// 10 Hz while either stick is held, a channel that starts goes out at once, each channel's release gets ONE zero.
/// `nil` for a channel = not applicable (no turret on this body, or the right stick pans the app's own view).
public struct TeleopFrameSender: Equatable {
    public static let ttl = 0.5
    public static let every = 0.1
    public static let deadband = 0.02
    private var lastSent = -1e9
    private var driveIdle = true
    private var turretIdle = true
    public init() {}

    public mutating func next(drive: DriveInput?, turret: TurretCommand?, now: Double) -> TeleopMessage? {
        let dOn = drive.map { !$0.isZero } ?? false
        let tOn = turret.map { !$0.isZeroRate } ?? false
        let dZero = drive != nil && !dOn && !driveIdle
        let tZero = turret != nil && !tOn && !turretIdle
        guard dOn || tOn || dZero || tZero else { return nil }
        let started = (dOn && driveIdle) || (tOn && turretIdle)
        guard dZero || tZero || started || now - lastSent >= Self.every - 1e-9 else { return nil }
        var m = TeleopMessage()
        if dOn { m.drive = drive } else if dZero { m.drive = DriveInput(throttle: 0, steer: 0, tank: drive?.tank ?? false) }
        if tOn { m.turret = turret } else if tZero { m.turret = .rate(yaw: 0, pitch: 0) }
        if drive != nil { driveIdle = !dOn }
        if turret != nil { turretIdle = !tOn }
        lastSent = now
        return m
    }

    /// Selection changed / drive mode left mid-drive: the next zeros go out again.
    public mutating func reset() { driveIdle = false; turretIdle = false; lastSent = -1e9 }
    public var idle: Bool { driveIdle && turretIdle }
}

/// Two touch-downs within `window` s = a double tap (right stick: recentre the turret).
public struct DoubleTapDetector: Equatable {
    public var window: Double
    private var last: Double?
    public init(window: Double = 0.3) { self.window = window }

    public mutating func touchDown(at t: Double) -> Bool {
        if let l = last, t - l <= window { last = nil; return true }
        last = t
        return false
    }
}

/// The HUD speed indicator: "0.21 m/s" from the snapshot velocity (+ the throttle in % while driving).
public enum SpeedReadout {
    public static func speed(v: Double?, vx: Double?, vy: Double?) -> Double {
        if let v, v.isFinite { return abs(v) }
        if let vx, let vy { return (vx * vx + vy * vy).squareRoot() }
        return 0
    }

    public static func text(speed: Double, throttle: Double?, turbo: Bool) -> String {
        var s = String(format: "%.2f m/s", speed)
        if let t = throttle, abs(t) >= 0.01 { s += String(format: " · %d%%", Int((abs(t) * 100).rounded())) }
        if turbo { s += " · TURBO" }
        return s
    }
}
