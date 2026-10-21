import Foundation
import SnailSightCore

// 12.6 Articulated doors (API §8.12): the latest door states for the map, shared by AR (MapARLayer.doorNode), the Map
// plan and Map 3D. GET /v1/maps/{map}/doors once (re-read every 2 min while something draws doors, and when the map
// version changes), then live `door` events on the downlink's changes layer (§6b.4) replace a door's state in place.
// `rev` bumps on any change so each view rebuilds only its door boxes.
final class DoorStore: ObservableObject {
    private unowned let model: AppModel
    @Published private(set) var doorSet = DoorSet()
    private(set) var rev = 0
    private var loadedAt: TimeInterval = 0
    private var loadedKey = ""
    private var loading = false
    private(set) var note: String?

    init(model: AppModel) { self.model = model }

    var leaves: [DoorLeaf] { doorSet.leaves }

    /// Fetch when stale; cheap to call every tick.
    func ensure() {
        guard model.drawDoors, model.serverBase != nil, let link = model.link, !loading else { return }
        let map = model.controller.mapLayer.mapID
        let now = Date().timeIntervalSince1970
        let key = "\(map)@\(model.liveBaseVersion ?? -1)"
        guard key != loadedKey || now - loadedAt > 120, now - loadedAt > 8 else { return }
        loading = true
        loadedAt = now
        Task { [weak self] in
            let r = try? await link.request("GET", "/v1/maps/\(map)/doors", timeout: 20)
            await MainActor.run {
                guard let self else { return }
                self.loading = false
                if let r, r.1 == 200, let doc = DoorsDoc.parse(r.0) {
                    self.loadedKey = key
                    self.doorSet.load(doc)
                    self.rev += 1
                    self.objectWillChange.send()
                    self.note = nil
                    self.model.log.event("doors_load", ["map": .string(map), "doors": .int(self.doorSet.doors.count)])
                } else {
                    self.note = "Doors unavailable (map server \(r?.1 ?? 0))"
                }
            }
        }
    }

    /// Downlink `door` message (§6b.4).
    func live(_ data: Data) {
        guard let e = DoorEvent.parse(data) else { return }
        if doorSet.apply(e) {
            rev += 1
            objectWillChange.send()
            model.log.event("door_live", ["door": .string(e.doorID), "state": .string(e.state),
                                          "angle": .double(e.angleDeg ?? -1)])
        } else if !doorSet.doors.contains(where: { $0.id == e.doorID }) {
            loadedAt = 0                                   // a door we do not know yet: re-read the list
        }
    }
}

import RealityKit
import UIKit

/// RealityKit leaf for a DoorLeaf, in the MAP frame (Z-up metres): a thin box (width x 0.04 x height) hinged at the pivot.
enum DoorMeshes {
    static func leaf(_ d: DoorLeaf, opacity: Float = 0.85) -> Entity {
        let col = UIColor(red: d.colour[0], green: d.colour[1], blue: d.colour[2], alpha: 1)
        var m = UnlitMaterial(color: col)
        m.blending = .transparent(opacity: .init(scale: opacity))
        let holder = Entity()
        holder.name = "door.\(d.id)"
        holder.position = SIMD3<Float>(Float(d.boxCenter[0]), Float(d.boxCenter[1]), Float(d.boxCenter[2]))
        holder.orientation = simd_quatf(angle: Float(d.yaw), axis: SIMD3<Float>(0, 0, 1))
        let box = ModelEntity(mesh: .generateBox(size: SIMD3(Float(d.width), Float(DoorLeaf.thickness), Float(d.height))), materials: [m])
        holder.addChild(box)
        if d.hinged {                                                    // the hinge axis
            let pin = ModelEntity(mesh: .generateCylinder(height: Float(d.height), radius: 0.02), materials: [UnlitMaterial(color: .white)])
            pin.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))   // cylinder axis y -> z
            pin.position = SIMD3<Float>(-Float(d.width) / 2, 0, 0)
            holder.addChild(pin)
        }
        return holder
    }
}
