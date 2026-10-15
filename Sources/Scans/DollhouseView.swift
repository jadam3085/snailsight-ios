// 9.6 Scans viewer, AR dollhouse: the scanned house (or object) as a miniature on a real table / floor. Its own AR
// session (the main SnailSight session is paused while Scans is open). Tap a horizontal surface to place; pinch to
// scale, twist to turn, drag to move (RealityKit entity gestures on a box collider around the model). A whole house
// starts at ~60 cm across (SnailSightCore.Dollhouse.fitScale); an object starts at 1 : 1.
import SwiftUI
import ARKit
import RealityKit
import SnailSightCore

final class DollhouseState: ObservableObject {
    @Published var placed = false
    @Published var scaleText = ""
    @Published var hint = "Move the phone over a table or the floor, then tap to place"
}

struct DollhouseView: UIViewRepresentable {
    let model: Entity               // a clone of the loaded scan (already unlit)
    let bounds: (min: SIMD3<Float>, max: SIMD3<Float>)
    let floorY: Float?
    @ObservedObject var state: DollhouseState
    let log: DebugLog

    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal]
        c.worldAlignment = .gravity
        c.environmentTexturing = .none
        v.session.run(c)
        let coach = ARCoachingOverlayView()
        coach.session = v.session
        coach.goal = .horizontalPlane
        coach.activatesAutomatically = true
        coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.addSubview(coach)
        v.renderOptions = [.disableMotionBlur, .disableDepthOfField]
        context.coordinator.arView = v
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return v
    }

    func updateUIView(_ v: ARView, context: Context) {}

    static func dismantleUIView(_ v: ARView, coordinator: Coordinator) {
        v.session.pause()
        v.scene.anchors.removeAll()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        let parent: DollhouseView
        weak var arView: ARView?
        private var anchor: AnchorEntity?
        private var holder: ModelEntity?
        private var baseScale: Float = 1
        private var scaleTimer: Timer?

        init(_ p: DollhouseView) { parent = p }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = arView else { return }
            let pt = g.location(in: v)
            guard let hit = v.raycast(from: pt, allowing: .estimatedPlane, alignment: .horizontal).first else {
                parent.state.hint = "No table or floor found there yet: sweep the phone over it"
                return
            }
            place(at: hit.worldTransform, in: v)
        }

        private func place(at m: simd_float4x4, in v: ARView) {
            let b = parent.bounds
            if let h = holder {                              // already placed: move it
                anchor?.transform = Transform(matrix: m)
                anchor?.transform.rotation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
                h.position = .zero
                return
            }
            let s = Dollhouse.fitScale(min: b.min, max: b.max)
            baseScale = s
            let off = Dollhouse.baseOffset(min: b.min, max: b.max, floorY: parent.floorY)
            let inner = Entity()                             // footprint centre at the origin, floor on y = 0
            inner.position = off
            inner.addChild(parent.model)
            let h = ModelEntity()
            h.addChild(inner)
            let size = b.max - b.min
            let centre = (b.min + b.max) / 2 + off
            h.collision = CollisionComponent(shapes: [ShapeResource.generateBox(size: simd_max(size, SIMD3(repeating: 0.02)))
                .offsetBy(translation: centre)])
            h.scale = SIMD3(repeating: s)
            let a = AnchorEntity(world: m)
            a.transform.rotation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))   // upright, ignore the plane's yaw
            a.addChild(h)
            v.scene.addAnchor(a)
            v.installGestures([.rotation, .scale, .translation], for: h)
            anchor = a
            holder = h
            parent.state.placed = true
            parent.state.hint = "Pinch to scale · twist to turn · drag to move · tap elsewhere to move it there"
            updateScale()
            scaleTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.updateScale() }
            var ev = MemoryProbe.fields()
            ev["scale"] = .double(Double(s))
            parent.log.event("scan_dollhouse_place", ev)
        }

        private func updateScale() {
            guard let h = holder else { return }
            let t = Dollhouse.scaleLabel(h.scale.x)
            if parent.state.scaleText != t { parent.state.scaleText = t }
        }

        deinit { scaleTimer?.invalidate() }
    }
}

/// 1:1 AR overlay: the scan over the real house at full size. Needs relocalization into the house map (plan P2), so
/// this is a stub that explains what it will do.
struct OverlayStubView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.3.layers.3d.down.right").font(.system(size: 44))
            Text("1 : 1 AR overlay").font(.title3.weight(.semibold))
            Text("Shows the scan over the real rooms at full size, so you can see what the map got right and what it missed. It needs the phone to know where it is in the house map (relocalization, plan P2), which is not built yet.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Later here: fly the virtual drone 1 : 1 over the real rooms, and see your room and object labels in place (they are kept in map coordinates for exactly this).")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Coming with P2").font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .foregroundStyle(.white)
    }
}
