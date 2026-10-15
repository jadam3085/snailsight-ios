// Frame convention (one, documented, tested): everything here is in ARKit world space as ARKit defines
// it with `.gravity` alignment: metres, right-handed, +Y = up (against gravity), origin = where the
// session started. A raycast hit's transform has the surface normal on its +Y column.
import Foundation
import simd

public enum Geo {
    public static let worldUp = SIMD3<Float>(0, 1, 0)

    public static func position(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Surface normal of a raycast result (its transform's +Y axis), normalised.
    public static func normal(_ hit: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(SIMD3(hit.columns.1.x, hit.columns.1.y, hit.columns.1.z))
    }

    public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_distance(a, b) }

    /// Angle between two vectors in degrees (0…180). Zero-length input → 0.
    public static func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 1e-9, lb > 1e-9 else { return 0 }
        let c = max(-1, min(1, simd_dot(a, b) / (la * lb)))
        return acos(c) * 180 / .pi
    }

    /// Component of `v` lying in the plane with normal `n`.
    public static func projectOntoPlane(_ v: SIMD3<Float>, normal n: SIMD3<Float>) -> SIMD3<Float> {
        let nn = simd_normalize(n)
        return v - simd_dot(v, nn) * nn
    }

    /// "123.4 cm" (one decimal, always centimetres so a tape comparison is direct).
    public static func centimetres(_ metres: Float) -> String {
        String(format: "%.1f cm", Double(metres) * 100)
    }

    /// Pose for an object placed on a raycast hit. On a near-horizontal, upward-facing surface (normal within
    /// `maxTiltDegrees` of world up) the object is gravity-aligned (+Y exactly up) and turned so its +Z faces
    /// the camera; otherwise the hit pose is used unchanged (walls, slopes). Position = hit position.
    public static func placementTransform(hit: simd_float4x4, cameraPosition: SIMD3<Float>,
                                          maxTiltDegrees: Float = 20) -> simd_float4x4 {
        let p = position(hit)
        guard angleDegrees(normal(hit), worldUp) <= maxTiltDegrees else { return hit }
        var f = projectOntoPlane(cameraPosition - p, normal: worldUp)
        if simd_length(f) < 1e-4 {           // camera straight above: keep the hit's own heading
            f = projectOntoPlane(SIMD3(hit.columns.2.x, hit.columns.2.y, hit.columns.2.z), normal: worldUp)
        }
        if simd_length(f) < 1e-4 { f = SIMD3(0, 0, 1) }
        let z = simd_normalize(f)
        let y = worldUp
        let x = simd_cross(y, z)
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(p, 1))
    }

    /// Frame for a straight ruler lying on a surface: origin at `origin`, +X along the camera's forward
    /// direction projected onto the surface, +Y = surface normal. nil if the camera looks straight along the
    /// normal (no usable direction).
    public static func rulerFrame(origin: SIMD3<Float>, normal: SIMD3<Float>,
                                  cameraForward: SIMD3<Float>) -> simd_float4x4? {
        let d = projectOntoPlane(cameraForward, normal: normal)
        guard simd_length(d) > 1e-3 else { return nil }
        let x = simd_normalize(d)
        let y = simd_normalize(normal)
        let z = simd_cross(x, y)
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(origin, 1))
    }

    public struct Segment {
        public var center: SIMD3<Float>
        public var rotation: simd_quatf      // rotates +X onto the segment direction
        public var length: Float
    }

    /// A thin box of size (length, t, t) with this center/rotation spans exactly a→b.
    public static func segment(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Segment {
        let d = b - a
        let len = simd_length(d)
        let rot: simd_quatf
        if len < 1e-6 {
            rot = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        } else {
            let u = d / len
            if simd_dot(u, SIMD3(1, 0, 0)) < -0.9999 {      // antiparallel: 180° about Y
                rot = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
            } else {
                rot = simd_quatf(from: SIMD3(1, 0, 0), to: u)
            }
        }
        return Segment(center: (a + b) / 2, rotation: rot, length: len)
    }

    /// Tick offsets along a ruler (0 … length inclusive), every `spacing` metres.
    public static func ticks(length: Float, spacing: Float) -> [Float] {
        guard spacing > 0, length >= 0 else { return [] }
        let n = Int((length / spacing + 1e-3).rounded(.down))   // 1.0/0.1 is 9.99999 in Float
        return (0...max(0, n)).map { Float($0) * spacing }
    }

    /// Rotation that turns a label's front (+Z) toward the camera while keeping its +Y as close to world up
    /// as possible (no roll). Camera straight above/below → +X kept along world X.
    public static func billboardRotation(position p: SIMD3<Float>, camera c: SIMD3<Float>) -> simd_quatf {
        var z = c - p
        if simd_length(z) < 1e-6 { z = SIMD3(0, 0, 1) }
        z = simd_normalize(z)
        var x = simd_cross(worldUp, z)
        if simd_length(x) < 1e-4 { x = SIMD3(1, 0, 0) }
        x = simd_normalize(x)
        let y = simd_cross(z, x)
        return simd_quatf(simd_float3x3(x, y, z))
    }

    /// True if the upper-left 3×3 is a rotation (orthonormal, det +1) within `tol`.
    public static func isRigid(_ m: simd_float4x4, tol: Float = 1e-3) -> Bool {
        let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                              SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                              SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let i = r.transpose * r
        let e = simd_float3x3(diagonal: SIMD3(repeating: 1))
        for c in 0..<3 { for k in 0..<3 where abs(i[c][k] - e[c][k]) > tol { return false } }
        return abs(simd_determinant(r) - 1) <= tol
    }
}
