import Foundation

// SnailSight 12.7 gamepad (owner's GameSir G8 Galileo; any MFi / extended gamepad via the GameController framework),
// with the RoboSnailBob HUD's data-driven mapping: ONE function list + presets (default / southpaw / triggers / dpadcam)
// drive the live loop, the help card and the remap. A / B are fixed (select / E-stop + cancel); L2 hold = the
// selection wheel, R2 hold = turbo, L3 = drive mode on / off, R3 = turret centre, Select = controller mode,
// Start = menu (the wheel, sticky). Deadzone 0.15 default. Persisted in UserDefaults (GamepadConfig.encoded()).
// Button numbering = the W3C standard gamepad (the HUD's), so a config means the same on both.
// Pure, Linux-tested (GamepadMapTests); the GCController glue is Sources/Drive/GamepadInput.swift.

public enum GamepadButton: Int, CaseIterable, Codable, Equatable {
    case a = 0, b, x, y, l1, r1, l2, r2, select, start, l3, r3, dUp, dDown, dLeft, dRight, home

    public var label: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .select: return "Select"
        case .start: return "Start"
        case .l3: return "L3"
        case .r3: return "R3"
        case .dUp: return "D-Up"
        case .dDown: return "D-Down"
        case .dLeft: return "D-Left"
        case .dRight: return "D-Right"
        case .home: return "Home"
        }
    }

    /// A / B are reserved (select / E-stop + cancel), as in the HUD.
    public var reserved: Bool { self == .a || self == .b }
    public var isTrigger: Bool { self == .l2 || self == .r2 }
}

public enum GamepadFunction: String, CaseIterable, Codable, Equatable {
    case select, estop
    case viewNext, takeOver, prevBody, nextBody
    case wheel, turbo                         // hold
    case controllerMode, menu, driveMode, turretCentre
    case pitchUp, pitchDown, yawLeft, yawRight
    case tank, follow

    public var label: String {
        switch self {
        case .select: return "Select"
        case .estop: return "E-stop / cancel"
        case .viewNext: return "View AR / FPV / Chase"
        case .takeOver: return "Take over"
        case .prevBody: return "Previous body"
        case .nextBody: return "Next body"
        case .wheel: return "Quick wheel (hold)"
        case .turbo: return "Turbo (hold)"
        case .controllerMode: return "Controller mode"
        case .menu: return "Menu"
        case .driveMode: return "Drive mode on / off"
        case .turretCentre: return "Turret centre"
        case .pitchUp: return "Turret up 10°"
        case .pitchDown: return "Turret down 10°"
        case .yawLeft: return "Turret left 15°"
        case .yawRight: return "Turret right 15°"
        case .tank: return "Tank steering"
        case .follow: return "Follow me"
        }
    }

    /// Held (fires while pressed) instead of on the rising edge.
    public var isHold: Bool { self == .wheel || self == .turbo }
}

public enum GamepadPreset: String, CaseIterable, Codable, Equatable {
    case standard = "default", southpaw, triggers, dpadcam

    public var label: String {
        switch self {
        case .standard: return "DEFAULT"
        case .southpaw: return "SOUTHPAW"
        case .triggers: return "TRIGGERS"
        case .dpadcam: return "D-PAD CAM"
        }
    }

    public var layout: StickLayout {
        switch self {
        case .southpaw: return .southpaw
        case .triggers: return .triggers
        default: return .standard
        }
    }

    static let base: [GamepadFunction: GamepadButton] = [
        .select: .a, .estop: .b, .viewNext: .x, .takeOver: .y, .prevBody: .l1, .nextBody: .r1, .wheel: .l2,
        .turbo: .r2, .controllerMode: .select, .menu: .start, .driveMode: .l3, .turretCentre: .r3,
        .pitchUp: .dUp, .pitchDown: .dDown, .yawLeft: .dLeft, .yawRight: .dRight,
    ]

    /// function → button. triggers: R2 − L2 is the throttle, so turbo moves to L1 and the wheel to R1 (the HUD moves
    /// turbo to L1 too). dpadcam: the D-pad picks views / bodies / tank and the shoulders nudge the turret.
    public var map: [GamepadFunction: GamepadButton] {
        var m = Self.base
        switch self {
        case .standard, .southpaw: break
        case .triggers:
            m[.prevBody] = nil; m[.nextBody] = nil
            m[.turbo] = .l1; m[.wheel] = .r1
        case .dpadcam:
            m[.pitchUp] = nil; m[.pitchDown] = nil
            m[.viewNext] = .dUp; m[.tank] = .dDown; m[.prevBody] = .dLeft; m[.nextBody] = .dRight
            m[.yawLeft] = .l1; m[.yawRight] = .r1; m[.follow] = .x
        }
        return m
    }

    public var next: GamepadPreset {
        let all = GamepadPreset.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// The persisted controller config (UserDefaults `drive.gamepad`).
public struct GamepadConfig: Codable, Equatable {
    public static let version = 1
    public static let defaultsKey = "drive.gamepad"
    public var v: Int = GamepadConfig.version
    public var enabled = true
    public var deadzone = TeleopFeel.padDeadzone
    public var driveSens = 1.0
    public var turretSens = 1.0
    public var rumble = true
    public var preset = GamepadPreset.standard.rawValue         // or "custom"
    public var layout = StickLayout.standard
    public var map: [String: Int] = [:]                          // function raw → button raw
    /// nil = never decided (auto-on at the first pairing, as the HUD's rsb_ctrlmode null).
    public var controllerMode: Bool?

    public init() { apply(.standard) }

    public static func decode(_ d: Data?) -> GamepadConfig {
        guard let d, var c = try? JSONDecoder().decode(GamepadConfig.self, from: d), c.v == version else { return GamepadConfig() }
        c.deadzone = SimMath.clamp(c.deadzone, 0, 0.5)
        if c.map.isEmpty { c.apply(GamepadPreset(rawValue: c.preset) ?? .standard) }
        return c
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public var presetLabel: String { GamepadPreset(rawValue: preset)?.label ?? "CUSTOM" }

    public mutating func apply(_ p: GamepadPreset) {
        preset = p.rawValue
        layout = p.layout
        map = Dictionary(uniqueKeysWithValues: p.map.map { ($0.key.rawValue, $0.value.rawValue) })
    }

    /// Rebind (press-to-bind): one button, one function; A / B refused. Returns false when refused.
    @discardableResult
    public mutating func bind(_ f: GamepadFunction, to b: GamepadButton) -> Bool {
        guard !b.reserved, f != .select, f != .estop else { return false }
        for (k, v) in map where v == b.rawValue { map[k] = nil }
        map[f.rawValue] = b.rawValue
        preset = "custom"
        return true
    }

    public func button(for f: GamepadFunction) -> GamepadButton? { map[f.rawValue].flatMap(GamepadButton.init(rawValue:)) }

    public func function(for b: GamepadButton) -> GamepadFunction? {
        map.first { $0.value == b.rawValue }.flatMap { GamepadFunction(rawValue: $0.key) }
    }

    /// The help card: "A Select · B E-stop / cancel · …" in button order.
    public var legend: [(button: String, function: String)] {
        GamepadButton.allCases.compactMap { b in function(for: b).map { (b.label, $0.label) } }
    }
}

/// One polled gamepad state (GCExtendedGamepad read into the standard layout). Sticks x right / y UP.
public struct GamepadFrame: Equatable {
    public var left: V2
    public var right: V2
    public var pressed: Set<GamepadButton>
    public var l2: Double
    public var r2: Double
    public init(left: V2 = .zero, right: V2 = .zero, pressed: Set<GamepadButton> = [], l2: Double = 0, r2: Double = 0) {
        self.left = left; self.right = right; self.pressed = pressed; self.l2 = l2; self.r2 = r2
    }

    public static let triggerThreshold = 0.4

    /// A hold function's button is down (analog triggers past 0.4, as the HUD).
    public func held(_ b: GamepadButton) -> Bool {
        switch b {
        case .l2: return l2 > Self.triggerThreshold || pressed.contains(.l2)
        case .r2: return r2 > Self.triggerThreshold || pressed.contains(.r2)
        default: return pressed.contains(b)
        }
    }
}

/// What one poll means: the axes for the twin-stick sender, turbo / wheel holds, functions fired on a rising edge.
public struct GamepadOutput: Equatable {
    public var axes: TwinStickAxes
    public var turbo: Bool
    public var wheelHeld: Bool
    public var fired: [GamepadFunction]
    public init(axes: TwinStickAxes = TwinStickAxes(), turbo: Bool = false, wheelHeld: Bool = false, fired: [GamepadFunction] = []) {
        self.axes = axes; self.turbo = turbo; self.wheelHeld = wheelHeld; self.fired = fired
    }
}

/// Rising-edge detection + the function map (HUD `edge()` + the actions loop).
public struct GamepadRouter: Equatable {
    private var prev: Set<GamepadButton> = []
    public init() {}

    public mutating func step(_ f: GamepadFrame, config c: GamepadConfig) -> GamepadOutput {
        var down = Set<GamepadButton>()
        for b in GamepadButton.allCases where f.held(b) { down.insert(b) }
        let rising = down.subtracting(prev)
        prev = down
        let triggersDrive = c.layout == .triggers
        var fired: [GamepadFunction] = []
        for b in GamepadButton.allCases where rising.contains(b) {
            if triggersDrive && b.isTrigger { continue }          // R2 − L2 is the throttle there
            guard let fn = c.function(for: b), !fn.isHold else { continue }
            fired.append(fn)
        }
        func hold(_ fn: GamepadFunction) -> Bool {
            guard let b = c.button(for: fn) else { return false }
            if triggersDrive && b.isTrigger { return false }
            return down.contains(b)
        }
        let input = TwinStickInput(left: f.left, right: f.right, l2: f.l2, r2: f.r2)
        var axes = TwinStick.resolve(input, layout: c.layout, deadzone: c.deadzone)
        axes.drive *= c.driveSens
        axes.turret *= c.turretSens
        return GamepadOutput(axes: axes, turbo: hold(.turbo), wheelHeld: hold(.wheel), fired: fired)
    }

    /// Forget the held buttons (a pad reconnected): nothing fires from a button already down.
    public mutating func reset(pressed: Set<GamepadButton> = []) { prev = pressed }
}

/// The selection wheel (HUD weapon wheel): items clockwise from the top; a stick (or finger offset) past 0.45 picks
/// the nearest item, centred = no pick (release cancels).
public enum QuickWheel {
    public static let deadRadius = 0.45

    /// Index picked by a vector (x right, y UP) among `count` items, nil when centred.
    public static func pick(_ v: V2, count: Int) -> Int? {
        guard count > 0, SimMath.length(v) >= deadRadius else { return nil }
        var a = atan2(v.x, v.y)                         // 0 = up, clockwise positive
        if a < 0 { a += 2 * .pi }
        return Int((a / (2 * .pi) * Double(count)).rounded()) % count
    }

    /// Item i's unit offset on screen (x right, y DOWN) for drawing.
    public static func offset(_ i: Int, count: Int) -> V2 {
        let a = Double(i) / Double(max(1, count)) * 2 * .pi
        return V2(sin(a), -cos(a))
    }
}
