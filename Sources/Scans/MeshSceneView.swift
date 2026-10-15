// 9.6 Scans viewer, Mesh mode: the server-built mesh.usdz (docs/SNAILSIGHT-API.md §8.9; same coordinates as mesh.glb:
// Y-up, metres) in a RealityKit ARView with a virtual camera (no AR session). Materials are made unlit (the texture IS
// the photographed light) with back faces culled, so from outside you look into the rooms like a dollhouse and from
// inside (Walk) you see the walls. Measure = ray casts against the mesh's own triangles (SnailSightCore.TriangleIndex),
// never the splat (as the web viewer, §8.8).
import SwiftUI
import RealityKit
import UIKit
import SnailSightCore

/// Loads a USDZ into an entity tree ready for the scan views (unlit textures). Main actor (RealityKit).
@MainActor
enum ScanModelLoader {
    static func load(_ url: URL) async throws -> Entity {
        let e = try await Entity(contentsOf: url)
        makeUnlit(e)
        return e
    }

    static func makeUnlit(_ e: Entity) {
        if var mc = e.components[ModelComponent.self] {
            mc.materials = mc.materials.map { m -> RealityKit.Material in
                if let p = m as? PhysicallyBasedMaterial {
                    var u = UnlitMaterial()
                    u.color = .init(tint: p.baseColor.tint, texture: p.baseColor.texture)
                    u.faceCulling = .back
                    return u
                }
                if let s = m as? SimpleMaterial {
                    var u = UnlitMaterial()
                    u.color = .init(tint: s.color.tint, texture: s.color.texture)
                    return u
                }
                return m
            }
            e.components.set(mc)
        }
        for c in e.children { makeUnlit(c) }
    }

    /// World-space triangles of every model in the tree (for Measure / walk-to).
    static func triangles(_ root: Entity) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var pos: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        func visit(_ e: Entity) {
            if let mc = e.components[ModelComponent.self] {
                let world = e.transformMatrix(relativeTo: nil)
                let contents = mc.mesh.contents
                for inst in contents.instances {
                    guard let m = contents.models[inst.model] else { continue }
                    let T = world * inst.transform
                    for part in m.parts {
                        guard let tri = part.triangleIndices?.elements else { continue }
                        let base = UInt32(pos.count)
                        for p in part.positions.elements {
                            let w = T * SIMD4<Float>(p, 1)
                            pos.append(SIMD3(w.x, w.y, w.z))
                        }
                        idx.append(contentsOf: tri.map { $0 + base })
                    }
                }
            }
            for c in e.children { visit(c) }
        }
        visit(root)
        return (pos, idx)
    }

    /// Visual bounds (viewer frame) of a loaded tree.
    static func bounds(_ e: Entity) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let b = e.visualBounds(relativeTo: nil)
        return (b.min, b.max)
    }
}

struct MeshSceneView: UIViewRepresentable {
    let entity: Entity
    let camera: ViewerCamera
    let markers: MeasureMarkers

    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        v.environment.background = .color(UIColor(white: 0.08, alpha: 1))
        v.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableHDR, .disableGroundingShadows]
        let world = AnchorEntity(world: matrix_identity_float4x4)
        world.addChild(entity)
        world.addChild(markers.root)
        let cam = PerspectiveCamera()
        cam.camera.fieldOfViewInDegrees = camera.fovy * 180 / .pi
        cam.camera.near = 0.02
        cam.camera.far = 500
        world.addChild(cam)
        v.scene.addAnchor(world)
        context.coordinator.cam = cam
        context.coordinator.update()
        context.coordinator.listener = camera.listen { [weak coord = context.coordinator] in coord?.update() }
        camera.attach(to: v)
        return v
    }

    func updateUIView(_ v: ARView, context: Context) {}

    static func dismantleUIView(_ v: ARView, coordinator: Coordinator) {
        if let id = coordinator.listener { coordinator.camera.unlisten(id) }
        v.scene.anchors.removeAll()
    }

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }

    final class Coordinator {
        let camera: ViewerCamera
        var cam: PerspectiveCamera?
        var listener: UUID?
        init(camera: ViewerCamera) { self.camera = camera }

        func update() {
            cam?.look(at: camera.target, from: camera.eye, relativeTo: nil)
        }
    }
}

/// Measure A→B on the mesh: two dots and a line (RealityKit), plus the label in SwiftUI.
@MainActor
final class MeasureMarkers {
    let root = Entity()
    private var a: SIMD3<Float>?
    private var dotSize: Float = 0.02

    func setScale(_ sceneSize: Float) { dotSize = min(0.05, max(0.008, sceneSize / 400)) }

    func clear() {
        a = nil
        root.children.removeAll()
    }

    /// Returns the distance once B is set (then the next tap starts again).
    func tap(_ p: SIMD3<Float>) -> Float? {
        let mat = UnlitMaterial(color: .systemYellow)
        if let a0 = a {
            root.addChild(dot(p, mat))
            let d = simd_distance(a0, p)
            let line = ModelEntity(mesh: .generateBox(size: SIMD3(dotSize * 0.4, dotSize * 0.4, max(d, 0.001))), materials: [mat])
            line.position = (a0 + p) / 2
            if d > 1e-4 { line.look(at: p, from: line.position, relativeTo: nil) }
            root.addChild(line)
            a = nil
            return d
        }
        root.children.removeAll()
        root.addChild(dot(p, mat))
        a = p
        return nil
    }

    private func dot(_ p: SIMD3<Float>, _ m: UnlitMaterial) -> ModelEntity {
        let e = ModelEntity(mesh: .generateSphere(radius: dotSize), materials: [m])
        e.position = p
        return e
    }
}
