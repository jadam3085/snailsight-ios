import Foundation

// SnailSight 9.8 Sim scale (owner on 9.7.75: "I need everything cut in half size, robot, and animals"). One global
// factor (default 50 %, 25–100 %, remembered) multiplies every sim body uniformly: the drawn model, its collision /
// selection box, its navigation footprint and step limits, and its speeds (a half-size robot drives at half speed,
// like a scale model). A body may override it (selection bar, 10–200 %). Distances that are about the PERSON, not the
// body (how close you may walk before an animal bolts), shrink less: never below 60 % of their real value.

public enum SimScale {
    public static let globalRange: ClosedRange<Double> = 0.25...1.0
    public static let overrideRange: ClosedRange<Double> = 0.1...2.0
    public static let defaultGlobal = 0.5
    /// Steps of the selection bar −/+ buttons.
    public static let overrideSteps: [Double] = [0.1, 0.15, 0.25, 0.35, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    public static func clampGlobal(_ s: Double) -> Double {
        guard s.isFinite else { return defaultGlobal }
        return SimMath.clamp(s, globalRange.lowerBound, globalRange.upperBound)
    }

    public static func clampOverride(_ s: Double) -> Double {
        guard s.isFinite else { return 1 }
        return SimMath.clamp(s, overrideRange.lowerBound, overrideRange.upperBound)
    }

    /// The factor a body is drawn and simulated at.
    public static func effective(global: Double, override: Double?) -> Double {
        if let o = override { return clampOverride(o) }
        return clampGlobal(global)
    }

    /// Next / previous override step from the current factor (the bar's −/+).
    public static func step(_ current: Double, up: Bool) -> Double {
        if up { return overrideSteps.first { $0 > current + 1e-6 } ?? overrideSteps.last! }
        return overrideSteps.last { $0 < current - 1e-6 } ?? overrideSteps.first!
    }

    /// "50 %"
    public static func label(_ s: Double) -> String { "\(Int((s * 100).rounded())) %" }

    /// Probes and steps cannot shrink below what the LiDAR mesh can resolve (its noise is ~1–2 cm).
    public static let minStep = 0.04
    public static let minDrop = 0.05
}

extension RobotProfile {
    /// The robot at scale `s`: footprint, wheels, mast, step limits, speeds and accelerations ×s (turn rates are
    /// unchanged — a model turns as fast as the real thing). Step / drop never go below what the mesh resolves.
    public func scaled(_ s: Double) -> RobotProfile {
        guard abs(s - 1) > 1e-9 else { return self }
        var p = self
        p.length *= s; p.width *= s; p.height *= s; p.trackWidth *= s; p.wheelRadius *= s
        p.maxSpeed *= s; p.maxWheelSpeed *= s; p.accel *= s; p.brake *= s; p.navSpeed *= s
        p.maxStep = max(SimScale.minStep, maxStep * s)
        p.maxDrop = max(SimScale.minDrop, maxDrop * s)
        return p
    }
}

extension SpeciesProfile {
    /// The animal at scale `s`: body radius, look-ahead, walking / fleeing speeds and distances ×s; the scare
    /// distances (about you and the robot, not the body) ×max(s, 0.6).
    public func scaled(_ s: Double) -> SpeciesProfile {
        guard abs(s - 1) > 1e-9 else { return self }
        var p = self
        p.radius *= s; p.lookahead *= s
        p.walkSpeed *= s; p.fleeSpeed *= s; p.fleeDist *= s; p.fleeJitter *= s; p.runAbove *= s
        p.accel *= s; p.fleeAccel *= s
        p.hop = (hop.lowerBound * s)...(hop.upperBound * s)
        let k = max(s, 0.6)
        p.scarePerson *= k; p.scareRobot *= k
        return p
    }
}

/// Step limits and body ray heights for an animal of height `h` (m, already scaled): rays at 20 / 55 / 90 % of the
/// height (a deer is taller than a table top, a rabbit is not), step 12 cm and drop 15 cm at full size.
public enum AnimalReach {
    public static func bodyHeights(height h: Double) -> [Double] {
        h > 0.8 ? [0.15 * h, 0.4 * h, 0.75 * h] : [max(0.03, 0.25 * h), 0.65 * h]
    }
    public static func maxStep(scale s: Double) -> Double { max(SimScale.minStep, 0.12 * s) }
    public static func maxDrop(scale s: Double) -> Double { max(SimScale.minDrop, 0.15 * s) }
}

/// The 1 m reference bar (owner 9.3.65): drawn at 1.000 m regardless of the Sim scale, so the measure tool, the bar
/// and a body can be compared directly (SimScaleTests pins robot bbox / bar = 0.82 at 100 %, 0.41 at 50 %).
public enum ScaleReference {
    public static let lengthM = 1.0
    public static let tickM = 0.1
}
