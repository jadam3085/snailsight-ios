import Foundation

// SnailSight S1 sim bodies: the robot's drawn parts and the sizes every sim entity reports (selection box, scale
// label, support probes). Local body frame = RealityKit's: x forward, y up, z right (= −URDF y), metres, feet at y = 0.
//
// Size semantics (the 9.3.65 "double size" audit): every `size` here is the FULL extent of the part's local box, which
// is exactly what RealityKit's `MeshResource.generateBox(size:)` takes. A cylinder of radius r and length l is stored
// as (2r, 2r, l) for an axle along z (or (2r, l, 2r) along y) and drawn with `generateCylinder(height: l, radius: r)`
// — radius = size / 2, never the diameter.

public struct Bounds3: Equatable {
    public var min: SIMD3<Double>
    public var max: SIMD3<Double>
    public init(min: SIMD3<Double>, max: SIMD3<Double>) { self.min = min; self.max = max }
    public init(center c: SIMD3<Double>, size s: SIMD3<Double>) { min = c - s / 2; max = c + s / 2 }
    public var extents: SIMD3<Double> { max - min }
    public var center: SIMD3<Double> { (min + max) / 2 }
    public func union(_ o: Bounds3) -> Bounds3 {
        Bounds3(min: SIMD3(Swift.min(min.x, o.min.x), Swift.min(min.y, o.min.y), Swift.min(min.z, o.min.z)),
                max: SIMD3(Swift.max(max.x, o.max.x), Swift.max(max.y, o.max.y), Swift.max(max.z, o.max.z)))
    }
    public func expanded(by m: Double) -> Bounds3 { Bounds3(min: min - SIMD3(repeating: m), max: max + SIMD3(repeating: m)) }
    public func intersects(_ o: Bounds3) -> Bool {
        min.x <= o.max.x && max.x >= o.min.x && min.y <= o.max.y && max.y >= o.min.y && min.z <= o.max.z && max.z >= o.min.z
    }
}

public enum PartShape: Equatable {
    case box(cornerRadius: Double)
    case cylinderZ          // axle along local z (wheels)
    case cylinderY          // upright (lidar puck)
}

public enum PartMaterial: String, Equatable { case body, dark, light, grey }

public struct BodyPart: Equatable {
    public var name: String
    public var shape: PartShape
    public var center: SIMD3<Double>
    public var size: SIMD3<Double>
    public var material: PartMaterial
    public init(_ name: String, _ shape: PartShape, center: SIMD3<Double>, size: SIMD3<Double>, _ material: PartMaterial) {
        self.name = name; self.shape = shape; self.center = center; self.size = size; self.material = material
    }
    public var bounds: Bounds3 { Bounds3(center: center, size: size) }
    /// Radius for a cylinder part (half its diameter extent).
    public var radius: Double { size.x / 2 }
}

/// RobosnailBob as drawn in AR: the Q6 Edge 2.0 base (hull between the mid drive wheels, casters front and rear,
/// centre lift post) plus the sensor head at the URDF poses (Kinect at x 0.35, L1 lidar at x 0.15 on a post).
/// Every number is derived from `RobotProfile` so the drawing, the collision footprint and the test agree.
public enum RobotModel {
    public static let groundClearance = 0.07           // 2.7 in (hardware.yml)
    public static let wheelWidth = 0.07
    public static let casterRadius = 0.076             // 6 in casters
    public static let lidarHeight = 0.07

    public static func parts(_ p: RobotProfile = .robosnailbob) -> [BodyPart] {
        let c = groundClearance
        let hullTop = c + 0.27
        let hullWidth = p.width - 2 * wheelWidth - 0.02
        let r = p.wheelRadius
        let half = p.trackWidth / 2
        var out: [BodyPart] = [
            BodyPart("hull", .box(cornerRadius: 0.02), center: SIMD3(0, c + 0.135, 0),
                     size: SIMD3(p.length, 0.27, hullWidth), .body),
            // left = +URDF y = −z
            BodyPart("wheel.left", .cylinderZ, center: SIMD3(0, r, -half), size: SIMD3(2 * r, 2 * r, wheelWidth), .dark),
            BodyPart("wheel.right", .cylinderZ, center: SIMD3(0, r, half), size: SIMD3(2 * r, 2 * r, wheelWidth), .dark),
            BodyPart("lift_post", .box(cornerRadius: 0.01), center: SIMD3(0, hullTop + 0.05, 0),
                     size: SIMD3(0.12, 0.10, 0.12), .grey),
            BodyPart("kinect", .box(cornerRadius: 0.008), center: SIMD3(0.35, hullTop + 0.025, 0),
                     size: SIMD3(0.07, 0.05, 0.25), .dark),
        ]
        let lidarY = p.height - lidarHeight / 2
        let postH = (lidarY - lidarHeight / 2) - hullTop
        out.append(BodyPart("lidar_post", .box(cornerRadius: 0), center: SIMD3(0.15, hullTop + postH / 2, 0),
                            size: SIMD3(0.03, postH, 0.03), .grey))
        out.append(BodyPart("lidar", .cylinderY, center: SIMD3(0.15, lidarY, 0),
                            size: SIMD3(0.10, lidarHeight, 0.10), .dark))
        let cx = p.length / 2 - 0.09, cz = hullWidth / 2 - 0.06
        for (i, (sx, sz)) in [(1.0, -1.0), (1.0, 1.0), (-1.0, -1.0), (-1.0, 1.0)].enumerated() {
            out.append(BodyPart("caster.\(i)", .cylinderZ, center: SIMD3(sx * cx, casterRadius, sz * cz),
                                size: SIMD3(2 * casterRadius, 2 * casterRadius, 0.05), .dark))
        }
        return out
    }

    public static func bounds(_ parts: [BodyPart]) -> Bounds3 {
        guard var b = parts.first?.bounds else { return Bounds3(min: .zero, max: .zero) }
        for p in parts.dropFirst() { b = b.union(p.bounds) }
        return b
    }
}

/// What can be selected and commanded in the sim: the robot, a catalog animal or a catalog object (9.8: the catalog
/// replaced the fixed deer / fox / rabbit / block list; those names stay as constants for the 9.7 records and tests).
public struct SimKind: Hashable {
    public enum Role: String, Hashable { case robot, animal, object }
    public var key: String
    public var role: Role

    public init(key: String, role: Role) { self.key = key; self.role = role }

    public static let robot = SimKind(key: "robot", role: .robot)
    public static let deer = SimKind(key: "deer", role: .animal)
    public static let fox = SimKind(key: "fox", role: .animal)
    public static let rabbit = SimKind(key: "rabbit", role: .animal)
    /// The 9.4 20 cm crate (now any catalog object without its own entry).
    public static let block = SimKind(key: "block", role: .object)

    /// An animal kind for a species key (9.7 API).
    public init?(species: String) {
        guard !species.isEmpty, species != "robot" else { return nil }
        self.init(key: species, role: .animal)
    }

    public var rawValue: String { key }
    public var isAnimal: Bool { role == .animal }
    public var isObject: Bool { role == .object }

    public var label: String {
        switch role {
        case .robot: return "RobosnailBob"
        default: return key == "block" ? "Block" : key.capitalized
        }
    }

    /// Body size (length along heading, height, width) at 100 % for the built-in kinds; catalog items carry their own
    /// measured size (SimCatalogItem.size). Animal sizes match the 9.7 models (Quaternius Stag 1.5 m).
    public var size: SIMD3<Double> {
        switch key {
        case "robot": return RobotModel.bounds(RobotModel.parts()).extents
        case "deer": return SIMD3(1.5, 1.4, 0.45)
        case "fox": return SIMD3(0.8, 0.45, 0.25)
        case "rabbit": return SIMD3(0.35, 0.3, 0.2)
        default: return SIMD3(repeating: SimBlockSpec.edge)
        }
    }
}

public enum SimBlockSpec {
    public static let edge = 0.2                        // 20 cm crate
    public static let dropHeight = 0.4                  // spawned this far above the floor so it visibly falls
}
