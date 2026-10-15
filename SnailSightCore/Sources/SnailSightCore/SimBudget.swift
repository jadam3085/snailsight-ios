import Foundation

// SnailSight 9.8 heat budget for the AR view + sim (owner on 9.7.75: "thermal SERIOUS" during the sim, the sim froze as
// "Sim waiting: tracking / heat", and "the app is over-judging the heat, the phone did not feel that hot").
// iOS's ProcessInfo.thermalState is the only signal we have; it says SERIOUS long before the case feels hot, and our
// own load is a large part of it: 60 fps rendering, the wireframe mesh rebuilds, RealityKit grounding shadows on every
// model, people segmentation, and the sim's raycasts. So instead of freezing the sim at SERIOUS (9.7) the app sheds
// THAT load step by step and keeps the sim running; only CRITICAL pauses it.

public enum SimPerfMode: String, CaseIterable, Identifiable, Equatable {
    case auto, full, eco
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Auto (by heat)"
        case .full: return "Full quality"
        case .eco: return "Battery saver"
        }
    }
}

public struct SimBudget: Equatable {
    public enum Tier: String, Equatable { case full, light, eco, paused }
    public var tier: Tier
    public var arFPS: Int                    // the AR frame rate to expect (iOS drops ARKit to 30 fps when warm)
    public var animalHz: Double
    public var robotHz: Double
    public var maxActiveObjects: Int         // awake rigid bodies (SleepPolicy.maxActive)
    public var maxObjects: Int               // spawn cap
    public var groundingShadows: Bool        // RealityKit's automatic grounding shadows (our contact shadows stay)
    public var meshRebuildS: Double          // wireframe per-anchor rebuild spacing (not recording)
    public var sweepEveryS: Double           // support backstop sweep
    public var running: Bool { tier != .paused }

    /// One-line reason for the status detail (nil when nothing is reduced).
    public var note: String? {
        switch tier {
        case .full: return nil
        case .light: return "Warm: lighter shadows, slower mesh updates"
        case .eco: return "Saving heat: AR 30 fps, slower sim and mesh updates"
        case .paused: return "Too hot: sim paused until the phone cools"
        }
    }
}

public enum SimBudgets {
    public static func budget(mode: SimPerfMode, thermal: ThermalLevel) -> SimBudget {
        if thermal == .critical {
            return SimBudget(tier: .paused, arFPS: 30, animalHz: 0, robotHz: 0, maxActiveObjects: 0, maxObjects: 12,
                             groundingShadows: false, meshRebuildS: 8, sweepEveryS: 6)
        }
        let tier: SimBudget.Tier
        switch mode {
        case .full: tier = .full
        case .eco: tier = .eco
        case .auto: tier = thermal == .serious ? .eco : thermal == .fair ? .light : .full
        }
        switch tier {
        case .full:
            return SimBudget(tier: .full, arFPS: 60, animalHz: 30, robotHz: 60, maxActiveObjects: 24, maxObjects: 40,
                             groundingShadows: true, meshRebuildS: 1, sweepEveryS: 2)
        case .light:
            return SimBudget(tier: .light, arFPS: 60, animalHz: 30, robotHz: 60, maxActiveObjects: 16, maxObjects: 30,
                             groundingShadows: false, meshRebuildS: 3, sweepEveryS: 3)
        default:
            return SimBudget(tier: .eco, arFPS: 30, animalHz: 15, robotHz: 30, maxActiveObjects: 10, maxObjects: 20,
                             groundingShadows: false, meshRebuildS: 6, sweepEveryS: 4)
        }
    }
}

/// HUD wording for the frame rate and heat (owner: the red "AR 30 fps" should explain itself; no alarm at fair).
public enum StatusText {
    /// Colour of the fps figure: normal at/above what we asked for (30 is the target in eco), warn only when clearly
    /// below it.
    public enum Tone: Equatable { case normal, warn }

    public static func fpsTone(fps: Double, target: Int) -> Tone {
        fps == 0 || fps >= Double(target) * 0.9 ? .normal : .warn
    }

    /// Short explanation of the AR frame rate (status detail). iOS itself runs ARKit's camera at 30 fps while the chip
    /// is warm (the 9.7.75 "AR 30 fps" in red at SERIOUS): that is expected, not a fault.
    public static func fpsExplain(fps: Double, target: Int, thermal: ThermalLevel) -> String {
        let f = Int(fps.rounded())
        if fps == 0 { return "AR is starting" }
        if fps < Double(target) * 0.9 {
            return thermal >= .serious ? "AR \(f) fps: iOS slowed the camera because the chip is hot"
                                       : "AR \(f) fps: below the \(target) fps target (busy)"
        }
        if fps < 50 { return "AR \(f) fps: iOS runs the camera at 30 fps while the phone is warm — expected" }
        return "AR \(f) fps: smooth"
    }

    /// The thermal chip: nil at nominal / fair (no alarm), a calm word + one-line detail at serious / critical.
    public static func thermalChip(_ t: ThermalLevel, recording: Bool, recRateHz: Double) -> (label: String, detail: String)? {
        switch t {
        case .nominal, .fair: return nil
        case .serious:
            let rec = recording ? String(format: " — recording slowed to %.0f fps", recRateHz) : " — sim and AR eased off to cool"
            return ("Warm", "iOS reports the chip is hot" + rec)
        case .critical:
            return ("Hot", recording ? "iOS reports critical heat — recording stops and saves" : "iOS reports critical heat — sim paused")
        }
    }
}

/// Thermal transitions with how long each state lasted (log evidence: how often iOS says serious, for how long).
public struct ThermalHistory: Equatable {
    public private(set) var state: ThermalLevel
    public private(set) var since: Double
    public private(set) var secondsIn: [ThermalLevel: Double] = [:]
    public private(set) var entries: [ThermalLevel: Int] = [:]

    public init(state: ThermalLevel, at t: Double) { self.state = state; since = t; entries[state] = 1 }

    /// Record a change; returns (previous state, seconds it lasted) or nil when unchanged.
    @discardableResult
    public mutating func change(to s: ThermalLevel, at t: Double) -> (from: ThermalLevel, lasted: Double)? {
        guard s != state else { return nil }
        let lasted = max(0, t - since)
        secondsIn[state, default: 0] += lasted
        let from = state
        state = s; since = t
        entries[s, default: 0] += 1
        return (from, lasted)
    }

    /// Total seconds spent in `s` up to `t` (including the current stretch).
    public func total(_ s: ThermalLevel, at t: Double) -> Double {
        (secondsIn[s] ?? 0) + (s == state ? max(0, t - since) : 0)
    }
}
