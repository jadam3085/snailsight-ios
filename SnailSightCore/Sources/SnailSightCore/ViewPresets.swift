// 12.4 View presets + the "3D world" master switch (owner 2026-10-20: "view live camera plus animals, and be able to
// turn off the layer where I see the 3d generated world").
//
// - LayerSnapshot: the individual world/overlay settings a preset sets (a value type so the logic is testable).
// - ViewPreset: "Camera + animals" (plain passthrough + sim bodies), "Full world" (the user's previous full set),
//   "Custom" (anything else). Any manual toggle -> Custom. The choice persists (Codable state).
// - WorldGate: the master "3D world" switch. It never rewrites the individual settings; it only masks the rendered
//   world geometry (house tiles in any style + labels/objects, live mesh, terrain, estimated trees/terrain), so turning
//   it back on restores them. Sim bodies, paths, cameras and other agents are not "world".
import Foundation

public struct LayerSnapshot: Codable, Equatable {
    /// HouseStyle raw value ("Off" / "Labels" / "Model" / "Wire" / "Ghost").
    public var house: String
    public var meshLive: Bool
    public var objects: Bool
    public var terrain: Bool
    public var cameras: Bool
    public var agents: Bool

    public init(house: String = "Model", meshLive: Bool = true, objects: Bool = true, terrain: Bool = false,
                cameras: Bool = true, agents: Bool = true) {
        self.house = house; self.meshLive = meshLive; self.objects = objects; self.terrain = terrain
        self.cameras = cameras; self.agents = agents
    }

    /// The shipped defaults (what "Full world" means before the user has a set of their own).
    public static let fullDefault = LayerSnapshot()

    /// Nothing but the camera and the sim bodies: house Off, mesh/objects/terrain/cameras/agents/estimated off.
    public static let cameraOnly = LayerSnapshot(house: "Off", meshLive: false, objects: false, terrain: false,
                                                 cameras: false, agents: false)

    /// True when no world geometry or overlay is on.
    public var isCameraOnly: Bool { self == .cameraOnly }
}

public enum ViewPreset: String, Codable, CaseIterable, Equatable, Identifiable {
    case cameraAnimals, fullWorld, custom
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cameraAnimals: return "Camera + animals"
        case .fullWorld: return "Full world"
        case .custom: return "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .cameraAnimals: return "The plain camera plus sim animals and robots; no house, mesh, terrain or cameras"
        case .fullWorld: return "Everything you had on before, restored"
        case .custom: return "Your own mix of the toggles below"
        }
    }
}

/// Persisted state: the chosen preset, the remembered "full" set, and the master 3D-world switch.
public struct ViewPresetState: Codable, Equatable {
    public var preset: ViewPreset = .fullWorld
    public var fullSet: LayerSnapshot = .fullDefault
    public var worldOn: Bool = true

    public init() {}

    /// Pick a preset. Returns the snapshot the app must apply (nil for Custom: nothing changes).
    /// Leaving a non-camera-only set for "Camera + animals" remembers it as the full set.
    public mutating func select(_ p: ViewPreset, current: LayerSnapshot) -> LayerSnapshot? {
        switch p {
        case .custom:
            preset = .custom
            return nil
        case .cameraAnimals:
            if !current.isCameraOnly { fullSet = current }
            preset = .cameraAnimals
            return .cameraOnly
        case .fullWorld:
            if fullSet.isCameraOnly { fullSet = .fullDefault }     // never "restore" to an empty world
            preset = .fullWorld
            return fullSet
        }
    }

    /// The user flipped an individual toggle: the row becomes Custom. A change made while on Full world also updates the
    /// remembered full set (it is what they were using); one made on Camera + animals leaves it untouched.
    public mutating func manualChange(current: LayerSnapshot) {
        if preset == .fullWorld, !current.isCameraOnly { fullSet = current }
        preset = .custom
    }

    /// Restore from storage: a stored "cameraAnimals" whose settings were later edited elsewhere reads as Custom.
    public mutating func reconcile(current: LayerSnapshot) {
        if preset == .cameraAnimals, !current.isCameraOnly { preset = .custom }
        if preset == .fullWorld, current != fullSet { preset = .custom }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ d: Data?) -> ViewPresetState {
        guard let d, let s = try? JSONDecoder().decode(ViewPresetState.self, from: d) else { return ViewPresetState() }
        return s
    }
}

/// What actually draws, given the individual settings and the master switch.
public enum WorldGate {
    /// HouseStyle raw value to draw ("Off" when the 3D world is off).
    public static func house(_ s: LayerSnapshot, worldOn: Bool) -> String { worldOn ? s.house : "Off" }
    public static func meshLive(_ s: LayerSnapshot, worldOn: Bool) -> Bool { worldOn && s.meshLive }
    public static func objects(_ s: LayerSnapshot, worldOn: Bool) -> Bool { worldOn && s.objects && s.house != "Off" }
    public static func terrain(_ s: LayerSnapshot, worldOn: Bool) -> Bool { worldOn && s.terrain }
    /// Estimated / surveyed trees and the estimated terrain are world content too (Map 3D, Yard).
    public static func estimated(worldOn: Bool) -> Bool { worldOn }

    /// House tiles / labels are fetched only for a drawing style while the world is on.
    public static func fetchesHouse(_ s: LayerSnapshot, worldOn: Bool) -> Bool {
        worldOn && ["Model", "Wire", "Ghost"].contains(s.house)
    }

    /// The live downlink is wanted when agents are shown or any world layer is.
    public static func downlinkWanted(_ s: LayerSnapshot, worldOn: Bool) -> Bool {
        s.agents || (worldOn && (s.house != "Off" || s.meshLive))
    }
}
