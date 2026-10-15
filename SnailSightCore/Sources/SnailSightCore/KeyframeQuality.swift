import Foundation

// 9.4 sharp captures (owner 2026-10-13: "a lot of splat photos have some motion blur"). Pure parts, unit-tested:
//  - predicted motion blur from the camera's angular + linear speed × exposure time,
//  - an on-device sharpness score (variance of the Laplacian of the 4× box-downscaled luma),
//  - the keyframe window: when the spacing rule (AdaptiveCapture.isKeyframe) opens a window, the recorder offers every
//    saved frame in it and keeps the SHARPEST one as the keyframe (window extends while everything was predicted
//    blurry),
//  - the "slow down" hint, and the camera exposure policy (Settings → Camera: Sharp / Auto).
// docs/SNAILSIGHT-API.md §4.4 (keyframes.csv quality columns) and §4.4b (camera settings).

public enum KeyframeQuality {
    /// Predicted motion blur in full-resolution pixels during one exposure: rotation sweeps ω·t·f pixels, translation
    /// v·t·f/z pixels for a surface `depthM` away.
    public static func predictedBlurPx(angularSpeedRadS: Double, linearSpeedMS: Double, depthM: Double,
                                       exposureS: Double, focalPx: Double) -> Double {
        let z = max(depthM, 0.1)
        return max(0, exposureS) * focalPx * (abs(angularSpeedRadS) + abs(linearSpeedMS) / z)
    }

    /// Variance of the 4-neighbour Laplacian of an 8-bit luma plane after a `factor`× box downscale (1920×1440 →
    /// 480×360 for factor 4). Higher = sharper; only comparable between frames of similar content (one window).
    /// ~3 ms for a 1920×1440 Y plane on an A17 in Release.
    public static func laplacianVariance(luma: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                                         factor: Int = 4) -> Double {
        let f = max(1, factor)
        let w = width / f, h = height / f
        guard w >= 3, h >= 3 else { return 0 }
        var small = [Float](repeating: 0, count: w * h)
        let norm = 1 / Float(f * f)
        for y in 0..<h {
            for x in 0..<w {
                var s = 0
                for dy in 0..<f {
                    let row = luma + (y * f + dy) * bytesPerRow + x * f
                    for dx in 0..<f { s += Int(row[dx]) }
                }
                small[y * w + x] = Float(s) * norm
            }
        }
        var sum = 0.0, sum2 = 0.0
        var n = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let l = Double(small[i - 1] + small[i + 1] + small[i - w] + small[i + w] - 4 * small[i])
                sum += l; sum2 += l * l; n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / Double(n)
        return max(0, sum2 / Double(n) - mean * mean)
    }

    /// Convenience for tests / small buffers: tightly packed 8-bit luma.
    public static func laplacianVariance(_ luma: [UInt8], width: Int, height: Int, factor: Int = 4) -> Double {
        luma.withUnsafeBufferPointer { p in
            laplacianVariance(luma: p.baseAddress!, width: width, height: height, bytesPerRow: width, factor: factor)
        }
    }
}

/// Main-thread keyframe window. `AdaptiveCapture.isKeyframe` decides WHEN a keyframe is due; the window then stays
/// open for `length` seconds (and up to `2 × length` while every frame so far was predicted blurrier than
/// `blurOK` px), and every saved frame inside it is a candidate. The recorder's queue keeps the sharpest candidate.
public struct KeyframeWindow: Equatable {
    public static let maxLength = 0.6
    public static let blurOK = 2.0

    /// Window length for a keyframe spacing scale: ≤ 0.6 s and ≤ 80 % of the minimum keyframe interval, so windows
    /// never overlap (room: 0.6 s; object profile ×0.3: 0.36 s).
    public static func length(scale: Double) -> Double {
        min(maxLength, 0.8 * AdaptiveCapture.keyframeMinInterval * max(scale, 0.05))
    }

    public private(set) var id = 0
    public private(set) var openedAt: Double?
    public private(set) var minBlur = Double.infinity
    public var length: Double

    public init(length: Double) { self.length = length }

    public var isOpen: Bool { openedAt != nil }

    public mutating func open(at t: Double) {
        id += 1
        openedAt = t
        minBlur = .infinity
    }

    /// A saved frame at `t` with predicted blur `blurPx`: its window id if it is a candidate, nil otherwise. Closes the
    /// window once it has run its length (and a sharp-enough frame was seen) or twice its length.
    public mutating func candidate(at t: Double, blurPx: Double) -> Int? {
        guard let t0 = openedAt else { return nil }
        let age = t - t0
        if age > length * 2 || (age > length && minBlur <= Self.blurOK) {
            openedAt = nil
            return nil
        }
        minBlur = min(minBlur, blurPx)
        return id
    }

    public mutating func close() { openedAt = nil }
}

/// Queue-side best-of selector: frames arrive in order tagged with their window id (nil = not a candidate). When the
/// window id changes (or at `flush`), the best frame of the finished window is returned with how many were compared.
public struct KeyframePicker<Payload> {
    public struct Pick {
        public var payload: Payload
        public var score: Double
        public var candidates: Int
    }

    private var window: Int?
    private var best: (Payload, Double)?
    private var count = 0

    public init() {}

    /// `score` is evaluated only for candidates. Returns the finished previous window's pick, if any.
    public mutating func offer(window w: Int?, payload: Payload, score: () -> Double) -> Pick? {
        var done: Pick?
        if w != window {
            done = flush()
            window = w
        }
        guard w != nil else { return done }
        let s = score()
        count += 1
        if best == nil || s > best!.1 { best = (payload, s) }
        return done
    }

    public mutating func flush() -> Pick? {
        defer { best = nil; count = 0; window = nil }
        guard let b = best else { return nil }
        return Pick(payload: b.0, score: b.1, candidates: count)
    }
}

/// "Slow down" hint (9.8 retune; owner: "any movement at all shows me a turtle"). The predicted blur (exponential
/// average over ~0.3 s) must stay above `onPx` for `holdS` before the hint shows; it hides as soon as the average drops
/// below `offPx`, and after hiding it stays quiet for `cooldownS`. At the 1/250 s shutter cap ordinary walking predicts
/// 2–6 px, which the sharpest-in-window keyframe picker absorbs, so only sustained fast sweeping (~9 px+) shows it.
/// Measured sharpness confirms it: while the newest keyframe is at least `sharpRatio` × the recording's median
/// keyframe sharpness, the frames really are sharp and the hint stays hidden.
public struct MotionHint: Equatable {
    public static let onPx = 9.0
    public static let offPx = 6.0
    public static let holdS = 0.7
    public static let cooldownS = 3.0
    public static let sharpRatio = 0.7
    public static let sharpSamples = 5
    public private(set) var smoothed = 0.0
    public private(set) var active = false
    private var lastT: Double?
    private var aboveSince: Double?
    private var quietUntil = -Double.infinity
    private var sharpness: [Double] = []
    /// The newest keyframe was sharp (relative to this recording): real blur is not happening.
    public private(set) var lastKeyframeSharp = false

    public init() {}

    @discardableResult
    public mutating func update(blurPx: Double, at t: Double, tau: Double = 0.3) -> Bool {
        let dt = lastT.map { max(0, t - $0) } ?? 1
        lastT = t
        let a = min(1, dt / tau)
        smoothed += a * (blurPx - smoothed)
        if active {
            if smoothed < Self.offPx || lastKeyframeSharp {
                active = false
                aboveSince = nil
                quietUntil = t + Self.cooldownS
            }
        } else if smoothed > Self.onPx {
            if aboveSince == nil { aboveSince = t }
            if t - aboveSince! >= Self.holdS && t >= quietUntil && !lastKeyframeSharp { active = true }
        } else {
            aboveSince = nil
        }
        return active
    }

    /// A keyframe was written with this measured sharpness (Laplacian variance; scene-dependent, so only compared with
    /// this recording's own median).
    public mutating func keyframe(sharpness s: Double) {
        guard s.isFinite, s > 0 else { return }
        sharpness.append(s)
        if sharpness.count > 40 { sharpness.removeFirst(sharpness.count - 40) }
        guard sharpness.count >= Self.sharpSamples else { lastKeyframeSharp = false; return }
        let med = sharpness.sorted()[sharpness.count / 2]
        lastKeyframeSharp = s >= Self.sharpRatio * med
    }
}

/// Settings → Camera. `sharp` (default): auto exposure capped at a short shutter (ISO rises instead), white balance
/// locked per recording, exposure also locked per OBJECT scan (one small lit area); `auto`: ARKit's own camera.
public enum CameraMode: String, CaseIterable, Identifiable {
    case sharp, auto
    public var id: String { rawValue }
    public var title: String { self == .sharp ? "Sharp (short shutter)" : "Auto" }
}

public struct CameraPlan: Equatable {
    public var maxExposureS: Double?        // nil = the device default (ARKit's own)
    public var lockWhiteBalance: Bool
    public var lockExposure: Bool
}

public enum CameraPolicy {
    /// 1/250 s: at 1 rad/s (a brisk turn) × f 1370 px that is ~5.5 px of blur instead of ~23 px at 1/60 s.
    public static let sharpMaxExposureS = 1.0 / 250
    /// Seconds after record start before WB / exposure are locked (AE / AWB settle on the start view first).
    public static let settleS = 0.8

    public static func plan(mode: CameraMode, recording: Bool, objectScan: Bool) -> CameraPlan {
        switch mode {
        case .auto: return CameraPlan(maxExposureS: nil, lockWhiteBalance: false, lockExposure: false)
        case .sharp: return CameraPlan(maxExposureS: sharpMaxExposureS, lockWhiteBalance: recording,
                                       lockExposure: recording && objectScan)
        }
    }

    /// The cap clamped into the active format's [min, max] exposure range (AVCaptureDevice throws outside it).
    public static func clampExposure(_ s: Double, minS: Double, maxS: Double) -> Double {
        min(max(s, minS), maxS)
    }
}
