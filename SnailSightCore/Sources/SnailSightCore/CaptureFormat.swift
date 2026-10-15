import Foundation

/// StrayScanner-layout capture formatting (docs/SNAILSIGHT-API.md §4.4, schema `snailsight.capture/1`).
/// Pure: the app passes plain numbers in, gets CSV lines / converted samples out.
public enum CaptureFormat {
    public static let schema = "snailsight.capture/1"
    public static let odometryHeader = "timestamp, frame, x, y, z, qx, qy, qz, qw\n"
    public static let imuHeader = "timestamp, a_x, a_y, a_z, alpha_x, alpha_y, alpha_z\n"
    /// keyframes.csv (9.1.61): one row per full-resolution keyframe `keyframes/NNNNNN.jpg`; `frame` is the shared frame
    /// index (its pose is that odometry.csv row), intrinsics are for this keyframe's own width × height.
    /// 9.4 (blur-aware keyframes) adds five quality columns: `sharpness` (KeyframeQuality.laplacianVariance of the
    /// luma, 4× box-downscaled; higher = sharper, compare within one capture), `blur_px` (predicted motion blur in
    /// full-res pixels), `exposure_s`, `iso` (0 = unknown) and `candidates` (frames compared in that keyframe's window).
    public static let keyframesHeader = "frame, timestamp, width, height, fx, fy, cx, cy, sharpness, blur_px, exposure_s, iso, candidates\n"

    public static func keyframeLine(frame: Int, timestamp: Double, width: Int, height: Int,
                                    fx: Double, fy: Double, cx: Double, cy: Double) -> String {
        "\(frame), \(f(timestamp)), \(width), \(height), \(f(fx, 4)), \(f(fy, 4)), \(f(cx, 4)), \(f(cy, 4))\n"
    }

    /// keyframes.csv row with the 9.4 quality columns (matches `keyframesHeader`).
    public static func keyframeLine(frame: Int, timestamp: Double, width: Int, height: Int,
                                    fx: Double, fy: Double, cx: Double, cy: Double,
                                    sharpness: Double, blurPx: Double, exposureS: Double, iso: Double,
                                    candidates: Int) -> String {
        "\(frame), \(f(timestamp)), \(width), \(height), \(f(fx, 4)), \(f(fy, 4)), \(f(cx, 4)), \(f(cy, 4)), "
            + "\(f(sharpness, 2)), \(f(blurPx, 2)), \(f(exposureS, 6)), \(f(iso, 0)), \(candidates)\n"
    }
    public static let gravity = 9.80665
    public static let rgbSize = (width: 1024, height: 768)      // 4× the 256×192 depth, 4:3 like the full image

    public struct Quat: Equatable { public var x, y, z, w: Double
        public init(x: Double, y: Double, z: Double, w: Double) { self.x = x; self.y = y; self.z = z; self.w = w }
    }

    /// Unit quaternion (w ≥ 0) from a rotation matrix given as rows `r[row][col]` (Shepperd's method).
    public static func quaternion(rows r: [[Double]]) -> Quat {
        let tr = r[0][0] + r[1][1] + r[2][2]
        var q: Quat
        if tr > 0 {
            let s = (tr + 1).squareRoot() * 2
            q = Quat(x: (r[2][1] - r[1][2]) / s, y: (r[0][2] - r[2][0]) / s, z: (r[1][0] - r[0][1]) / s, w: 0.25 * s)
        } else if r[0][0] > r[1][1] && r[0][0] > r[2][2] {
            let s = (1 + r[0][0] - r[1][1] - r[2][2]).squareRoot() * 2
            q = Quat(x: 0.25 * s, y: (r[0][1] + r[1][0]) / s, z: (r[0][2] + r[2][0]) / s, w: (r[2][1] - r[1][2]) / s)
        } else if r[1][1] > r[2][2] {
            let s = (1 + r[1][1] - r[0][0] - r[2][2]).squareRoot() * 2
            q = Quat(x: (r[0][1] + r[1][0]) / s, y: 0.25 * s, z: (r[1][2] + r[2][1]) / s, w: (r[0][2] - r[2][0]) / s)
        } else {
            let s = (1 + r[2][2] - r[0][0] - r[1][1]).squareRoot() * 2
            q = Quat(x: (r[0][2] + r[2][0]) / s, y: (r[1][2] + r[2][1]) / s, z: 0.25 * s, w: (r[1][0] - r[0][1]) / s)
        }
        let n = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()
        if n > 0 { q = Quat(x: q.x / n, y: q.y / n, z: q.z / n, w: q.w / n) }
        if q.w < 0 { q = Quat(x: -q.x, y: -q.y, z: -q.z, w: -q.w) }
        return q
    }

    static func f(_ v: Double, _ digits: Int = 6) -> String {
        String(format: "%.\(digits)f", v.isFinite ? v : 0)
    }

    /// One odometry.csv row: timestamp, frame, x, y, z, qx, qy, qz, qw (camera→world, raw ARKit).
    public static func odometryLine(timestamp: Double, frame: Int, position p: [Double], rotationRows r: [[Double]]) -> String {
        let q = quaternion(rows: r)
        return "\(f(timestamp)), \(frame), \(f(p[0])), \(f(p[1])), \(f(p[2])), \(f(q.x, 8)), \(f(q.y, 8)), \(f(q.z, 8)), \(f(q.w, 8))\n"
    }

    /// One imu.csv row. `userAccel`/`gravity` in g (CoreMotion), output total acceleration in m/s²; gyro rad/s.
    public static func imuLine(timestamp: Double, accelG a: [Double], gyro w: [Double]) -> String {
        "\(f(timestamp)), \(f(a[0] * gravity)), \(f(a[1] * gravity)), \(f(a[2] * gravity)), \(f(w[0])), \(f(w[1])), \(f(w[2]))\n"
    }

    /// camera_matrix.csv: 3 lines × 3 comma-separated values, rows of K.
    public static func cameraMatrix(fx: Double, fy: Double, cx: Double, cy: Double) -> String {
        "\(f(fx)),0.000000,\(f(cx))\n0.000000,\(f(fy)),\(f(cy))\n0.000000,0.000000,1.000000\n"
    }

    /// LiDAR depth in metres → millimetres (UInt16). NaN/inf/≤0 → 0 (no data); > 65.535 m clamps.
    @inline(__always)
    public static func depthMillimetres(_ metres: Float) -> UInt16 {
        guard metres.isFinite, metres > 0 else { return 0 }
        let mm = (metres * 1000).rounded()
        return mm >= 65535 ? 65535 : UInt16(mm)
    }

    public static func depthMillimetres(_ metres: [Float]) -> [UInt16] { metres.map { depthMillimetres($0) } }

    /// Rate control: save this frame if at least `1/rateHz` s passed since the last saved one.
    public static func shouldSave(now: Double, last: Double?, rateHz: Double) -> Bool {
        guard let last else { return true }
        guard rateHz > 0 else { return false }
        return now - last >= (1 / rateHz) - 0.004       // 4 ms slack so 60 Hz frames land on a 10 Hz grid
    }
}
