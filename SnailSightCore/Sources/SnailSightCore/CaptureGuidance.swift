import Foundation

// SnailSight 12.26 capture-quality guidance during a walk. The server lane measured (2026-11-13, W1c §13.1b) that map
// disagreement between walks is mostly measurement quality: low ARKit depth confidence 38 %, grazing incidence
// (|cos| < 0.3) 17 %, range > 2.5 m 9 %, plus glass / mirrors. At good confidence, incidence and range the walks agree to
// ~2 cm p90. So the walk shows ONE small, gentle hint at a time when most of the view is weak, far, edge-on, empty
// (glass / open space) or the phone moves too fast, and a coverage hint per 4 m area. Pure + Linux-tested
// (CaptureGuidanceTests); the app measures each live keyframe's depth + confidence on its encode queue.

/// Shares (0…1) of one keyframe's depth pixels (sampled every `step` px). `valid` = pixels with depth; the others are
/// shares of the valid ones (graze: of those with a usable normal).
public struct CaptureQuality: Equatable {
    public var confLow: Double
    public var far: Double
    public var graze: Double
    public var valid: Double

    public init(confLow: Double, far: Double, graze: Double, valid: Double) {
        self.confLow = confLow; self.far = far; self.graze = graze; self.valid = valid
    }

    public static let farM = 2.5            // the server's long-range cause (> 2.5 m)
    public static let grazeCos = 0.3        // the server's grazing cause (|cos| < 0.3)
    public static let lowConf: UInt8 = 1    // ARKit confidence 0 / 1 = the server's low-confidence cause

    /// Additive keyframe header key `capture_q` (older servers ignore it; walk_validate reads it from the stored kf).
    public var json: [String: Any] {
        ["conf_low": Self.r3(confLow), "far": Self.r3(far), "graze": Self.r3(graze), "valid": Self.r3(valid)]
    }
    static func r3(_ v: Double) -> Double { v.isFinite ? (v * 1000).rounded() / 1000 : 0 }

    /// `depthMM` = little-endian UInt16 millimetres (0 = none), `conf` = 0/1/2 per pixel (same size) or nil;
    /// `K` = fx, fy, cx, cy of the CAMERA image (`imageW` wide): scaled to the depth map here.
    public static func measure(depthMM: [UInt16], conf: [UInt8]?, width w: Int, height h: Int,
                               K: [Double], imageW: Int, step: Int = 4) -> CaptureQuality? {
        guard w > 2 * step, h > 2 * step, depthMM.count == w * h, K.count == 4, imageW > 0 else { return nil }
        let c = conf.flatMap { $0.count == w * h ? $0 : nil }
        let sc = Double(w) / Double(imageW)
        let fx = K[0] * sc, fy = K[1] * sc, cx = K[2] * sc, cy = K[3] * sc
        guard fx > 0, fy > 0 else { return nil }
        @inline(__always) func z(_ x: Int, _ y: Int) -> Double { Double(UInt16(littleEndian: depthMM[y * w + x])) / 1000 }
        var total = 0, valid = 0, low = 0, far = 0, nrm = 0, graze = 0
        var y = 0
        while y < h - step {
            var x = 0
            while x < w - step {
                total += 1
                let d = z(x, y)
                if d > 0.05 {
                    valid += 1
                    if let c, c[y * w + x] <= lowConf { low += 1 }
                    if d > farM { far += 1 }
                    let dx = z(x + step, y), dy = z(x, y + step)
                    // a jump of > 35 % is an occlusion edge, not a surface (a grazing floor changes less per 4 px)
                    if dx > 0.05, dy > 0.05, abs(dx - d) < 0.35 * max(d, dx), abs(dy - d) < 0.35 * max(d, dy) {
                        // camera-frame points (x right, y down, z forward): normal = (Px - P) × (Py - P)
                        let p = [(Double(x) - cx) / fx * d, (Double(y) - cy) / fy * d, d]
                        let px = [(Double(x + step) - cx) / fx * dx, (Double(y) - cy) / fy * dx, dx]
                        let py = [(Double(x) - cx) / fx * dy, (Double(y + step) - cy) / fy * dy, dy]
                        let a = [px[0] - p[0], px[1] - p[1], px[2] - p[2]], b = [py[0] - p[0], py[1] - p[1], py[2] - p[2]]
                        let n = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
                        let nn = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).squareRoot()
                        let pn = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).squareRoot()
                        if nn > 0, pn > 0 {
                            nrm += 1
                            if abs(n[0] * p[0] + n[1] * p[1] + n[2] * p[2]) / (nn * pn) < grazeCos { graze += 1 }
                        }
                    }
                }
                x += step
            }
            y += step
        }
        guard total > 0 else { return nil }
        let v = Double(max(valid, 1))
        return CaptureQuality(confLow: c == nil ? 0 : Double(low) / v, far: Double(far) / v,
                              graze: nrm > 0 ? Double(graze) / Double(nrm) : 0, valid: Double(valid) / Double(total))
    }
}

public enum WalkHintKind: String, CaseIterable, Equatable {
    case speed, conf, far, graze, nodepth, coverage

    /// Gentle, plain words; one at a time.
    public var text: String {
        switch self {
        case .speed: return "A little slower: frames are blurring"
        case .conf: return "Depth is weak here: step closer or add light"
        case .far: return "Mostly far away: get within about 2.5 m"
        case .graze: return "Surfaces seen edge-on: face them more squarely"
        case .nodepth: return "Little depth here (glass, mirror or open space)"
        case .coverage: return "Turn slowly to see the rest of this area"
        }
    }

    public var symbol: String {
        switch self {
        case .speed: return "tortoise"
        case .conf: return "light.max"
        case .far: return "arrow.down.right.and.arrow.up.left"
        case .graze: return "rectangle.portrait.rotate"
        case .nodepth: return "window.vertical.closed"
        case .coverage: return "arrow.triangle.2.circlepath"
        }
    }
}

/// One hint at a time, never nagging: a condition must hold in `need` of the last `window` samples (≈ 3 s at 2 Hz)
/// to show; a shown hint stays ≥ `minShowS` and clears when it holds in ≤ 1 of the last `window`; the same hint does not
/// come back for `cooldownS` after it cleared. Priority = the enum order (speed first).
public struct WalkGuidance {
    public static let window = 6
    public static let need = 4
    public static let minShowS = 4.0
    public static let cooldownS = 25.0
    // thresholds (shares of the view)
    public static let confShare = 0.5
    public static let farShare = 0.5
    public static let grazeShare = 0.45
    public static let validMin = 0.5
    public static let blurPx = 6.0          // LiveGate.blurLate: a keyframe this blurry is late already
    public static let turnDegS = 80.0
    public static let moveMS = 1.2
    public static let coverageAfterS = 25.0
    public static let coverageShare = 0.5

    public private(set) var current: WalkHintKind?
    public private(set) var shown: [WalkHintKind: Int] = [:]
    private var hist: [WalkHintKind: [Bool]] = [:]
    private var shownAt = 0.0
    private var clearedAt: [WalkHintKind: Double] = [:]
    // walk means of the keyframe shares
    public private(set) var samples = 0
    private var sum = (conf: 0.0, far: 0.0, graze: 0.0, nodepth: 0.0)

    public init() {}

    public var means: (conf: Double, far: Double, graze: Double, nodepth: Double)? {
        guard samples > 0 else { return nil }
        let n = Double(samples)
        return (sum.conf / n, sum.far / n, sum.graze / n, sum.nodepth / n)
    }

    /// A keyframe's measured shares (nil = not measured). Only accumulates; `step` decides.
    public mutating func keyframe(_ q: CaptureQuality) {
        samples += 1
        sum.conf += q.confLow; sum.far += q.far; sum.graze += q.graze; sum.nodepth += 1 - q.valid
    }

    /// Which conditions hold now.
    public static func conditions(q: CaptureQuality?, blurPx: Double?, turnDegS: Double?, moveMS: Double?,
                                  coverage: (inAreaS: Double, share: Double)?) -> Set<WalkHintKind> {
        var s = Set<WalkHintKind>()
        if (blurPx ?? 0) > Self.blurPx || (turnDegS ?? 0) > Self.turnDegS || (moveMS ?? 0) > Self.moveMS { s.insert(.speed) }
        if let q {
            if q.valid < validMin { s.insert(.nodepth) } else {
                if q.confLow > confShare { s.insert(.conf) }
                if q.far > farShare { s.insert(.far) }
                if q.graze > grazeShare { s.insert(.graze) }
            }
        }
        if let c = coverage, c.inAreaS >= coverageAfterS, c.share < coverageShare { s.insert(.coverage) }
        return s
    }

    /// One sample (≈ 2 Hz). Returns the hint that changed (shown or cleared) or nil when nothing changed.
    @discardableResult
    public mutating func step(_ holds: Set<WalkHintKind>, now: Double) -> (kind: WalkHintKind, on: Bool)? {
        for k in WalkHintKind.allCases {
            var h = hist[k] ?? []
            h.append(holds.contains(k))
            if h.count > Self.window { h.removeFirst(h.count - Self.window) }
            hist[k] = h
        }
        func count(_ k: WalkHintKind) -> Int { (hist[k] ?? []).filter { $0 }.count }
        if let c = current {
            guard now - shownAt >= Self.minShowS else { return nil }
            if count(c) <= 1 {
                current = nil
                clearedAt[c] = now
                return (c, false)
            }
            return nil
        }
        for k in WalkHintKind.allCases where count(k) >= Self.need {
            if let t = clearedAt[k], now - t < Self.cooldownS { continue }
            current = k
            shownAt = now
            shown[k, default: 0] += 1
            return (k, true)
        }
        return nil
    }

    /// "speed:2,far:1" for the walk summary log.
    public var shownText: String {
        WalkHintKind.allCases.compactMap { k in shown[k].map { "\(k.rawValue):\($0)" } }.joined(separator: ",")
    }
}
