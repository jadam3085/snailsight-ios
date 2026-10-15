import Foundation

// SnailSight 9.8 interactive objects (owner: "if it gets pushed off a table, it goes to the floor"). Objects are
// RealityKit dynamic rigid bodies on the LiDAR scene mesh (falling, rolling, bouncing, settling, object-on-object).
// The robot and the animals are NOT physics bodies (their motion is the 1-DOF support model + the scene-mesh sweep,
// which is stable on the noisy mesh); their contact with objects is resolved here, every sim step:
//  - an agent overlapping an object pushes it out along the shallowest axis of the agent's footprint box and gives it
//    at least the agent's speed along that normal (+ a little bounce); a robot pushes anything, an animal pushes what
//    is lighter than itself and is blocked by heavier things (it walks round them: they are in its avoid list);
//  - an object flying into a resting agent bounces off it (and may spook an animal: `impactSpeed`).
// Ground frame (x, y), heights = ARKit y.

public struct PushAgent: Equatable {
    public var center: V2
    public var yaw: Double
    public var halfLength: Double
    public var halfWidth: Double
    public var bottom: Double
    public var height: Double
    public var velocity: V2
    public var massKg: Double
    /// The robot is driven: nothing it touches slows it (kinematic). Animals are not.
    public var kinematic: Bool

    public init(center: V2, yaw: Double, halfLength: Double, halfWidth: Double, bottom: Double, height: Double,
                velocity: V2, massKg: Double, kinematic: Bool) {
        self.center = center; self.yaw = yaw; self.halfLength = halfLength; self.halfWidth = halfWidth
        self.bottom = bottom; self.height = height; self.velocity = velocity; self.massKg = massKg
        self.kinematic = kinematic
    }
}

public struct PushObject: Equatable {
    public var center: V2
    public var radius: Double           // horizontal bounding radius
    public var bottom: Double
    public var top: Double
    public var velocity: V2             // ground-plane velocity
    public var massKg: Double

    public init(center: V2, radius: Double, bottom: Double, top: Double, velocity: V2, massKg: Double) {
        self.center = center; self.radius = radius; self.bottom = bottom; self.top = top
        self.velocity = velocity; self.massKg = massKg
    }
}

public struct PushResult: Equatable {
    /// Move the object by this much (out of the agent).
    public var offset: V2
    /// The object's new ground-plane velocity.
    public var velocity: V2
    /// Outward contact normal (agent → object).
    public var normal: V2
    /// Closing speed at contact (m/s), ≥ 0.
    public var impactSpeed: Double
    /// The object is too heavy for this (non-kinematic) agent: the agent should stop, the object stays.
    public var blocksAgent: Bool
}

public enum SimPush {
    /// An animal moves objects up to this fraction of its own mass.
    public static let animalPushRatio = 0.5
    /// Bounce on contact.
    public static let restitution = 0.25
    /// Cap so a fast-turning robot corner never launches a cup across the room.
    public static let maxPushSpeed = 2.5

    /// Contact between an agent's footprint box and an object's footprint circle, nil when they do not touch.
    public static func resolve(agent a: PushAgent, object o: PushObject) -> PushResult? {
        // vertical overlap: an object on a table above a robot, or a ball flying over a rabbit, is not touched
        guard o.bottom < a.bottom + a.height - 0.005, o.top > a.bottom + 0.005 else { return nil }
        let c = cos(a.yaw), s = sin(a.yaw)
        let d = o.center - a.center
        let lx = c * d.x + s * d.y, ly = -s * d.x + c * d.y            // object centre in the agent frame
        // closest point of the box to the circle centre
        let qx = SimMath.clamp(lx, -a.halfLength, a.halfLength), qy = SimMath.clamp(ly, -a.halfWidth, a.halfWidth)
        var nx = lx - qx, ny = ly - qy
        var dist = (nx * nx + ny * ny).squareRoot()
        let depth: Double
        if dist > 1e-9 {
            guard dist < o.radius else { return nil }
            depth = o.radius - dist
            nx /= dist; ny /= dist
        } else {
            // centre inside the box: leave by the nearest face
            let px = a.halfLength - abs(lx), py = a.halfWidth - abs(ly)
            if px < py { nx = lx >= 0 ? 1 : -1; ny = 0; depth = px + o.radius }
            else { nx = 0; ny = ly >= 0 ? 1 : -1; depth = py + o.radius }
            dist = 0
        }
        let n = V2(c * nx - s * ny, s * nx + c * ny)                  // back to ground frame
        let closing = SimMath.dot(a.velocity - o.velocity, n)          // > 0: agent catching the object
        let heavy = !a.kinematic && o.massKg > a.massKg * animalPushRatio
        if heavy {
            // the animal cannot move it: the object keeps still (only separated if the animal walked in)
            return PushResult(offset: .zero, velocity: o.velocity, normal: n, impactSpeed: max(0, closing), blocksAgent: true)
        }
        var v = o.velocity
        if closing > 0 {
            v += n * (closing * (1 + restitution))
            let sp = SimMath.length(v)
            if sp > maxPushSpeed { v *= maxPushSpeed / sp }
        }
        return PushResult(offset: n * (depth + 0.002), velocity: v, normal: n, impactSpeed: max(0, closing),
                          blocksAgent: false)
    }

    /// A thrown / rolling object hits a standing agent: the object bounces off (reflected along the normal).
    /// Returns nil when they do not touch or the object is moving away.
    public static func bounce(object o: PushObject, off a: PushAgent) -> PushResult? {
        var still = a
        still.velocity = .zero
        still.kinematic = true                                          // an object never shoves an agent here
        guard var r = resolve(agent: still, object: o) else { return nil }
        let into = -SimMath.dot(o.velocity, r.normal)                   // speed toward the agent
        guard into > 0 else { return nil }
        r.velocity = o.velocity + r.normal * (into * (1 + restitution))
        r.impactSpeed = into
        return r
    }
}
