/// ARKit tracking state mirrored without ARKit, so the banner text is unit-testable.
public enum TrackingReason: String, Codable, Equatable {
    case initializing, excessiveMotion, insufficientFeatures, relocalizing, unknown
}

public enum TrackingStatus: Equatable, Codable {
    case notAvailable
    case limited(TrackingReason)
    case normal

    public enum Severity: String { case ok, warn, bad }

    public var label: String {
        switch self {
        case .normal: return "TRACKING NORMAL"
        case .notAvailable: return "TRACKING NOT AVAILABLE"
        case .limited(let r): return "TRACKING LIMITED · \(r.short)"
        }
    }

    public var severity: Severity {
        switch self {
        case .normal: return .ok
        case .limited: return .warn
        case .notAvailable: return .bad
        }
    }

    /// What the user should do, or nil when nothing is needed.
    public var hint: String? {
        switch self {
        case .normal: return nil
        case .notAvailable: return "Camera blocked or AR not running"
        case .limited(.initializing): return "Move the phone slowly to start"
        case .limited(.excessiveMotion): return "Slow down"
        case .limited(.insufficientFeatures): return "Point at textured, well-lit surfaces"
        case .limited(.relocalizing): return "Return to where you were"
        case .limited(.unknown): return nil
        }
    }

    /// Short machine name for logs: "normal", "limited:excessiveMotion", "notAvailable".
    public var code: String {
        switch self {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(let r): return "limited:\(r.rawValue)"
        }
    }
}

extension TrackingReason {
    public var short: String {
        switch self {
        case .initializing: return "initializing"
        case .excessiveMotion: return "too fast"
        case .insufficientFeatures: return "low detail"
        case .relocalizing: return "relocalizing"
        case .unknown: return "unknown"
        }
    }
}
