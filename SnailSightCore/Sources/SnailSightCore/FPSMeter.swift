import Foundation

/// Frames per second over a sliding time window, from frame timestamps (ARFrame.timestamp, seconds).
public struct FPSMeter {
    public let window: TimeInterval
    private var stamps: [TimeInterval] = []

    public init(window: TimeInterval = 1.0) { self.window = window }

    @discardableResult
    public mutating func tick(_ t: TimeInterval) -> Double {
        if let last = stamps.last, t < last { stamps.removeAll() }   // clock reset (session restart)
        stamps.append(t)
        while let first = stamps.first, t - first > window { stamps.removeFirst() }
        return fps
    }

    public var fps: Double {
        guard stamps.count >= 2, let f = stamps.first, let l = stamps.last, l > f else { return 0 }
        return Double(stamps.count - 1) / (l - f)
    }
}
