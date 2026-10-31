import Foundation

// SnailSight 12.22 (server live 0.10, API §6b.13): GPS / compass / barometer as WEAK priors on every live keyframe.
// The server never puts GPS into geometry: it fits a datum per frame (house or island), places unjoined islands
// approximately, seeds / narrows searches and vetoes joins that contradict GPS. The phone's job is to send honest fixes:
// what CoreLocation says (with its accuracy), the TRUE heading of the camera's optical axis (with its accuracy) and the
// barometer's relative altitude.
//
// This file is the pure part (Linux-tested): the `geo` header object, the fix gate (age / accuracy), the heading filter
// (compass offset to the ARKit world, so the per-keyframe heading follows ARKit's smooth yaw instead of a noisy compass
// sample) and a 2D datum (frame <-> WGS84) for drawing island outlines at their lat/lon.

/// One keyframe's `geo` header object (API §6b.13 keyframe header).
public struct LiveGeo: Equatable {
    public var lat: Double
    public var lon: Double
    public var hAccM: Double
    public var altM: Double?
    public var vAccM: Double?
    /// TRUE heading (deg clockwise from north) of the camera's optical axis projected on the horizontal.
    public var headingDeg: Double?
    public var headingAccDeg: Double?
    public var baroRelM: Double?
    /// "phone" (CoreLocation) or "gnss" (an ARKit geo-tracking fix).
    public var source: String
    /// UNIX time of the fix (CLLocation.timestamp).
    public var t: Double?

    public init(lat: Double, lon: Double, hAccM: Double, altM: Double? = nil, vAccM: Double? = nil,
                headingDeg: Double? = nil, headingAccDeg: Double? = nil, baroRelM: Double? = nil,
                source: String = "phone", t: Double? = nil) {
        self.lat = lat; self.lon = lon; self.hAccM = hAccM; self.altM = altM; self.vAccM = vAccM
        self.headingDeg = headingDeg; self.headingAccDeg = headingAccDeg; self.baroRelM = baroRelM
        self.source = source; self.t = t
    }

    private static func r(_ v: Double, _ digits: Double) -> Double { (v * digits).rounded() / digits }

    /// The header object. Optional keys are omitted when unknown (never NaN: JSONSerialization traps on it).
    public var json: [String: Any] {
        var o: [String: Any] = ["lat": Self.r(lat, 1e8), "lon": Self.r(lon, 1e8), "h_acc_m": Self.r(hAccM, 100),
                                "source": source]
        if let a = altM, a.isFinite { o["alt_m"] = Self.r(a, 100) }
        if let v = vAccM, v.isFinite, v >= 0 { o["v_acc_m"] = Self.r(v, 100) }
        if let h = headingDeg, h.isFinite {
            o["heading_deg"] = Self.r(GeoHeading.wrap360(h), 100)
            o["heading_ref"] = "camera"
            if let a = headingAccDeg, a.isFinite, a >= 0 { o["heading_acc_deg"] = Self.r(a, 100) }
        }
        if let b = baroRelM, b.isFinite { o["baro_rel_m"] = Self.r(b, 1000) }
        if let t, t.isFinite { o["t"] = Self.r(t, 1000) }
        return o
    }
}

/// Which raw fixes become a keyframe's `geo`: CoreLocation's invalid (negative accuracy), stale or > 100 m fixes are
/// dropped here (the server ignores > 100 m anyway; sending them only costs bytes).
public enum LiveGeoFix {
    public static let maxAgeS = 10.0
    public static let maxHAccM = 100.0

    public static func make(lat: Double, lon: Double, hAccM: Double, altM: Double?, vAccM: Double?, fixTime: Double,
                            now: Double, heading: (deg: Double, accDeg: Double)?, baroRelM: Double?,
                            source: String = "phone") -> LiveGeo? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        guard hAccM.isFinite, hAccM >= 0, hAccM <= maxHAccM else { return nil }
        guard now - fixTime <= maxAgeS, fixTime - now <= 2 else { return nil }
        // a negative vertical accuracy = altitude invalid (CoreLocation)
        let vOK = (vAccM ?? -1) >= 0 && (altM?.isFinite ?? false)
        return LiveGeo(lat: lat, lon: lon, hAccM: hAccM, altM: vOK ? altM : nil, vAccM: vOK ? vAccM : nil,
                       headingDeg: heading?.deg, headingAccDeg: heading?.accDeg, baroRelM: baroRelM,
                       source: source, t: fixTime)
    }
}

/// The camera axis' TRUE heading from the compass, carried on ARKit's yaw.
///
/// ARKit's world has an arbitrary yaw (gravity alignment) but a smooth, drift-free-ish heading over a walk; the compass
/// has true north but is noisy and disturbed near steel. So the filter keeps the OFFSET between the two (true heading
/// minus ARKit yaw of the same camera axis at the same moment, circular mean over a window) and a keyframe's heading
/// is its own ARKit yaw + that offset. A new ARKit world (reset / new stream) resets it.
public struct GeoHeading: Equatable {
    public struct Sample: Equatable { public var t: Double; public var offsetDeg: Double; public var accDeg: Double }
    public private(set) var samples: [Sample] = []
    public var windowS = 60.0
    public var maxSamples = 240
    public static let minSamples = 5
    /// Compass error is a slow bias (API §6b.13): never claim better than this.
    public static let floorDeg = 5.0
    public init() {}

    public static func wrap360(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
    public static func wrap180(_ d: Double) -> Double {
        let r = wrap360(d)
        return r > 180 ? r - 360 : r
    }

    /// ARKit yaw of a camera's optical axis (ARKit world, y up): clockwise from -z towards +x seen from above, degrees.
    /// `T` = T_arkit_cam row-major 16; the camera looks along its -z. nil when the camera looks (almost) straight up /
    /// down (no horizontal axis).
    public static func arkitYawDeg(T: [Double]) -> Double? {
        guard T.count == 16 else { return nil }
        let fx = -T[2], fz = -T[10]
        guard (fx * fx + fz * fz).squareRoot() >= 0.25 else { return nil }
        return wrap360(atan2(fx, -fz) * 180 / .pi)
    }

    /// The back camera's optical axis (device -z) in CoreMotion's `xTrueNorthZVertical` frame (x = true north,
    /// y = west, z = up), from the attitude rotation matrix (row-major m11 ... m33) and the device-frame gravity.
    /// CoreMotion's documentation does not pin the matrix direction, so the one that maps the measured gravity to
    /// (0, 0, -1) is used (logged as `geo_heading_conv`). nil when neither convention fits (bad sample).
    public static func cameraAxisNorthWestUp(rotation m: [Double], gravityDevice g: [Double]) -> (axis: [Double], transposed: Bool)? {
        guard m.count == 9, g.count == 3 else { return nil }
        func mul(_ a: [Double], _ v: [Double], transpose: Bool) -> [Double] {
            var out = [0.0, 0.0, 0.0]
            for r in 0..<3 {
                var s = 0.0
                for c in 0..<3 {
                    let e: Double = transpose ? a[c * 3 + r] : a[r * 3 + c]
                    s += e * v[c]
                }
                out[r] = s
            }
            return out
        }
        let gn = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
        guard gn > 0.5 else { return nil }
        let gu = g.map { $0 / gn }
        let a = mul(m, gu, transpose: false), b = mul(m, gu, transpose: true)
        let ea: Double = abs(a[2] + 1) + abs(a[0]) + abs(a[1])
        let eb: Double = abs(b[2] + 1) + abs(b[0]) + abs(b[1])
        guard min(ea, eb) < 0.2 else { return nil }
        let t = eb < ea
        return (mul(m, [0, 0, -1], transpose: t), t)
    }

    /// True heading (deg) of a direction in the north-west-up frame; nil when (almost) vertical.
    public static func trueHeadingDeg(northWestUp v: [Double]) -> Double? {
        guard v.count == 3 else { return nil }
        let north = v[0], east = -v[1]
        guard (north * north + east * east).squareRoot() >= 0.25 else { return nil }
        return wrap360(atan2(east, north) * 180 / .pi)
    }

    /// CoreMotion's magnetometer calibration (CMMagneticFieldCalibrationAccuracy raw value: -1 uncalibrated, 0 low,
    /// 1 medium, 2 high) as a heading accuracy; nil = do not use the sample.
    public static func accuracyDeg(calibration: Int) -> Double? {
        switch calibration {
        case 2: return 5
        case 1: return 10
        case 0: return 20
        default: return nil
        }
    }

    public mutating func reset() { samples.removeAll() }

    /// One simultaneous pair (ARKit yaw, true heading) of the same camera axis.
    public mutating func add(arkitYawDeg: Double, trueHeadingDeg: Double, accDeg: Double, t: Double) {
        guard arkitYawDeg.isFinite, trueHeadingDeg.isFinite, accDeg.isFinite else { return }
        samples.append(Sample(t: t, offsetDeg: Self.wrap360(trueHeadingDeg - arkitYawDeg), accDeg: max(accDeg, 0)))
        samples.removeAll { t - $0.t > windowS }
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }

    /// Circular mean offset + its spread (deg), nil with < minSamples.
    public var offset: (deg: Double, spreadDeg: Double, accDeg: Double)? {
        guard samples.count >= Self.minSamples else { return nil }
        var sx = 0.0, sy = 0.0
        for s in samples { sx += cos(s.offsetDeg * .pi / 180); sy += sin(s.offsetDeg * .pi / 180) }
        let n = Double(samples.count)
        let rbar = min(1, (sx * sx + sy * sy).squareRoot() / n)
        guard rbar > 0.2 else { return nil }                         // compass all over the place: no heading
        let spread = (-2 * log(rbar)).squareRoot() * 180 / .pi        // circular standard deviation
        let accs = samples.map(\.accDeg).sorted()
        let medAcc = accs[accs.count / 2]
        return (Self.wrap360(atan2(sy, sx) * 180 / .pi), spread, medAcc)
    }

    /// The true heading of a keyframe's camera axis + its honest accuracy, nil if unknown.
    public func heading(T: [Double]) -> (deg: Double, accDeg: Double)? {
        guard let o = offset, let y = Self.arkitYawDeg(T: T) else { return nil }
        return (Self.wrap360(y + o.deg), max(Self.floorDeg, o.accDeg, o.spreadDeg))
    }
}

/// A frame's datum as the server serves it (`geoprior.Datum.to_json`): frame (x, y) -> ENU (e, n) by yaw + t, ENU
/// about (lat0, lon0) -> WGS84. Local radii of curvature (exact enough for drawing over a few km).
public struct GeoDatum: Equatable {
    public var lat0: Double
    public var lon0: Double
    public var yaw: Double            // rad: e = c x - s y + t0, n = s x + c y + t1
    public var t: [Double]            // [e, n]
    public var sigmaT: Double?
    public var yawKnown: Bool
    public var source: String?
    public var centroidMap: [Double]?

    public init(lat0: Double, lon0: Double, yaw: Double, t: [Double] = [0, 0], sigmaT: Double? = nil,
                yawKnown: Bool = true, source: String? = nil, centroidMap: [Double]? = nil) {
        self.lat0 = lat0; self.lon0 = lon0; self.yaw = yaw; self.t = t.count >= 2 ? t : [0, 0]
        self.sigmaT = sigmaT; self.yawKnown = yawKnown; self.source = source; self.centroidMap = centroidMap
    }

    public init?(json o: [String: Any]?) {
        guard let o, let la = (o["lat0"] as? NSNumber)?.doubleValue, let lo = (o["lon0"] as? NSNumber)?.doubleValue else { return nil }
        let yaw: Double
        if let y = (o["yaw"] as? NSNumber)?.doubleValue { yaw = y }
        else if let d = (o["yaw_deg"] as? NSNumber)?.doubleValue { yaw = d * .pi / 180 }
        else { yaw = 0 }
        let t = (o["t"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0]
        self.init(lat0: la, lon0: lo, yaw: yaw, t: t, sigmaT: (o["sigma_t"] as? NSNumber)?.doubleValue,
                  yawKnown: (o["yaw_known"] as? Bool) ?? true, source: o["source"] as? String,
                  centroidMap: (o["centroid_map"] as? [NSNumber])?.map(\.doubleValue))
    }

    static let a = 6_378_137.0, e2 = 6.694379990141e-3
    private var radii: (m: Double, n: Double) {
        let s = sin(lat0 * .pi / 180), w = (1 - Self.e2 * s * s).squareRoot()
        return (Self.a * (1 - Self.e2) / (w * w * w), Self.a / w)
    }

    public func toENU(x: Double, y: Double) -> (e: Double, n: Double) {
        let c = cos(yaw), s = sin(yaw)
        return (c * x - s * y + t[0], s * x + c * y + t[1])
    }

    public func fromENU(e: Double, n: Double) -> (x: Double, y: Double) {
        let c = cos(yaw), s = sin(yaw), de = e - t[0], dn = n - t[1]
        return (c * de + s * dn, -s * de + c * dn)
    }

    public func toLatLon(x: Double, y: Double) -> (lat: Double, lon: Double) {
        let (e, n) = toENU(x: x, y: y)
        let r = radii
        return (lat0 + n / r.m * 180 / .pi, lon0 + e / (r.n * cos(lat0 * .pi / 180)) * 180 / .pi)
    }

    public func fromLatLon(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let r = radii
        let n = (lat - lat0) * .pi / 180 * r.m, e = (lon - lon0) * .pi / 180 * r.n * cos(lat0 * .pi / 180)
        return fromENU(e: e, n: n)
    }

    /// Ground distance (m) between two WGS84 points (local WGS84 radii at the mean latitude, fine below ~50 km).
    public static func distanceM(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let r = GeoDatum(lat0: (a.lat + b.lat) / 2, lon0: a.lon, yaw: 0).radii
        let la = (a.lat + b.lat) / 2 * .pi / 180
        let dx = (b.lon - a.lon) * .pi / 180 * cos(la) * r.n, dy = (b.lat - a.lat) * .pi / 180 * r.m
        return (dx * dx + dy * dy).squareRoot()
    }
}
