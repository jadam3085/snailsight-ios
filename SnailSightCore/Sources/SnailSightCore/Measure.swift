import simd

/// Two-point tape measure: tap A, tap B → distance; a third tap starts a new measurement at that point.
public struct TwoPointMeasure: Equatable {
    public private(set) var a: SIMD3<Float>?
    public private(set) var b: SIMD3<Float>?

    public init() {}

    public enum Step: Equatable {
        case first(SIMD3<Float>)
        case second(SIMD3<Float>, SIMD3<Float>, distance: Float)
    }

    @discardableResult
    public mutating func add(_ p: SIMD3<Float>) -> Step {
        if let a0 = a, b == nil {
            b = p
            return .second(a0, p, distance: simd_distance(a0, p))
        }
        a = p; b = nil
        return .first(p)
    }

    public var distance: Float? {
        guard let a, let b else { return nil }
        return simd_distance(a, b)
    }

    public mutating func reset() { a = nil; b = nil }
}
