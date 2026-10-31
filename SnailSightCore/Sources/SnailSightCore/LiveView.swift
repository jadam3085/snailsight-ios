import Foundation

// SnailSight 12.21 "Live map view" (owner 2026-10-31: "Is it possible for me to see the overlay of that live map in the
// app instead of the current visual?"). One remembered switch in AR between:
//  - Device view (12.18 default): the camera is the room near you; stored faces the phone has seen are hidden.
//  - Live map view: the SERVER's live world is the visible overlay where you stand: Layer B surface + live downlink
//    mesh tiles, drawn SOLID and SHADED in a high-contrast palette (the portal lane found pale blue on grey hard to
//    see); stored base tiles are dimmed (ghost) and still hidden inside Layer B cubes. The device-surface rule no
//    longer hides live / Layer B faces (they are what you came to see); it still hides base faces.
// Memory: live tiles are unwelded for the strip colours (3 vertices a face, like Photo colour); the 12.20 SpatialLRU
// budgets bound them (MemoryBudgetTests soak runs with the overlay on).

public enum ARLook: String, CaseIterable, Identifiable {
    case device, live
    public var id: String { rawValue }
    public var title: String { self == .live ? "Live map view" : "Camera + device surface" }
    public var short: String { self == .live ? "Live map" : "Camera" }
    public var symbol: String { self == .live ? "cube.fill" : "camera.viewfinder" }
    public var toggled: ARLook { self == .live ? .device : .live }
}

public enum LiveViewLook {
    /// Palette (sRGB 0-255) by surface orientation, chosen for contrast over a camera image: saturated, mid-to-dark
    /// luma, far from neutral grey and from the portal's pale blue.
    public static let floor: SIMD3<Double> = [24, 160, 140]       // teal
    public static let wall: SIMD3<Double> = [235, 120, 30]        // amber-orange
    public static let ceiling: SIMD3<Double> = [150, 80, 210]     // violet
    public static let photoMix = 0.35                             // a little of the photo colour for texture cues
    /// Map-frame light (z up), two-sided Lambert with an ambient floor so no face goes black.
    public static let light: SIMD3<Double> = {
        let v = SIMD3<Double>(0.35, 0.55, 0.76)
        return v / (v * v).sum().squareRoot()
    }()
    public static let ambient = 0.42

    /// Shaded colour of one face with unit normal `n` (map frame) and an optional photo colour.
    public static func shade(normal n: SIMD3<Double>, photo: SIMD3<Double>?) -> SIMD3<Double> {
        let base: SIMD3<Double>
        if n.z > 0.7 { base = floor } else if n.z < -0.7 { base = ceiling } else { base = wall }
        let mixed = photo.map { base * (1 - photoMix) + $0 * photoMix } ?? base
        let lam = abs((n * light).sum())
        let k = ambient + (1 - ambient) * lam
        return SIMD3(min(255, mixed.x * k), min(255, mixed.y * k), min(255, mixed.z * k))
    }

    /// RGB per face (3 bytes each) for a mesh in the map frame; `rgb` = optional per-vertex photo colour.
    public static func faceColours(_ m: FlatMesh, rgb: [UInt8]?) -> [UInt8] {
        let nt = m.triangleCount, nv = m.vertexCount
        let photo = rgb.flatMap { $0.count == nv * 3 ? $0 : nil }
        var out = [UInt8](repeating: 0, count: nt * 3)
        for f in 0..<nt {
            let ia = Int(m.indices[f * 3]), ib = Int(m.indices[f * 3 + 1]), ic = Int(m.indices[f * 3 + 2])
            guard ia < nv, ib < nv, ic < nv else { continue }
            func p(_ i: Int) -> SIMD3<Double> {
                SIMD3(Double(m.positions[i * 3]), Double(m.positions[i * 3 + 1]), Double(m.positions[i * 3 + 2]))
            }
            let a = p(ia), b = p(ib), c = p(ic)
            let e1 = b - a, e2 = c - a
            var n = SIMD3(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x)
            let len = (n * n).sum().squareRoot()
            n = len > 0 ? n / len : SIMD3(0, 0, 1)
            var ph: SIMD3<Double>?
            if let r = photo {
                var s = SIMD3<Double>(0, 0, 0)
                for i in [ia, ib, ic] { s += SIMD3(Double(r[i * 3]), Double(r[i * 3 + 1]), Double(r[i * 3 + 2])) }
                ph = s / 3
            }
            let col = shade(normal: n, photo: ph)
            out[f * 3] = UInt8(col.x.rounded()); out[f * 3 + 1] = UInt8(col.y.rounded()); out[f * 3 + 2] = UInt8(col.z.rounded())
        }
        return out
    }

    /// Relative luminance (sRGB 0-255 -> 0-1, WCAG).
    public static func luminance(_ c: SIMD3<Double>) -> Double {
        func ch(_ v: Double) -> Double { let s = v / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.x) + 0.7152 * ch(c.y) + 0.0722 * ch(c.z)
    }

    /// WCAG contrast ratio of two colours.
    public static func contrast(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Chroma (max - min channel): distance from grey.
    public static func chroma(_ c: SIMD3<Double>) -> Double { max(c.x, c.y, c.z) - min(c.x, c.y, c.z) }
}

/// 12.21 warm on open: `POST /v1/localizer/warm` fire-and-forget on launch, foreground and Live map on, at most once
/// per `minS` (the server coalesces concurrent calls too; the engines then page in ~2-5 s before the first localize).
public struct WarmDebounce {
    public var minS: Double
    public private(set) var lastAt: Double?
    public private(set) var fired = 0
    public private(set) var skipped = 0
    public init(minS: Double = 60) { self.minS = minS }
    /// true = send now (and remember it).
    public mutating func shouldFire(now: Double) -> Bool {
        if let l = lastAt, now - l < minS, now >= l { skipped += 1; return false }
        lastAt = now
        fired += 1
        return true
    }
    /// A failed send (no network): allow the next trigger to try again at once.
    public mutating func failed() { lastAt = nil }
}
