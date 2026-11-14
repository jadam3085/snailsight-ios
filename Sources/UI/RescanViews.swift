// SnailSight 12.27 Rescan + Scan view UI: the guidance sheet, the coverage strip during a rescan (coverage by surface,
// a top-down mini map of good depth, points held, Scan view / 3D), the result card (building -> before / after, rev,
// Open in snailCOP / held + why), and the orbit view of the live point cloud (paused: drag to orbit, pinch to zoom).
import MetalKit
import SwiftUI
import SnailSightCore
import simd

// MARK: - presentation (observes the controllers: AppModel does not republish their changes)

struct RescanPresenter: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject var rescan: RescanController
    @ObservedObject var cloud: ScanCloudController

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $rescan.showGuide) { RescanGuideSheet(rescan: rescan).environmentObject(model) }
            .fullScreenCover(isPresented: $cloud.orbitOpen) { ScanOrbitView(cloud: cloud).environmentObject(model) }
    }
}

/// Mapping ▸ Scan view (observes the cloud so the switch follows the walk bar's toggle).
struct ScanViewToggle: View {
    @ObservedObject var cloud: ScanCloudController

    var body: some View {
        Toggle(isOn: $cloud.on) { Label("Scan view (live points)", systemImage: "circle.grid.3x3.fill") }
        Toggle(isOn: $cloud.showFaint) { Label("Show weak points (faint)", systemImage: "circle.dotted") }
            .disabled(!cloud.on)
    }
}

// MARK: - guidance

struct RescanGuideSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var rescan: RescanController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("What", selection: $rescan.setting) {
                        ForEach(RescanSetting.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(rescan.setting == .indoor ? "Room name (optional)" : "Area name (optional)", text: $rescan.name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text(rescan.setting == .indoor
                         ? "One careful scan becomes this room's map. Only what you scan well is replaced."
                         : "One careful scan becomes this area's map: the region your scan covered well (no room needed).")
                }
                Section("How to scan") {
                    ForEach(Array(rescan.setting.guidance.enumerated()), id: \.offset) { i, g in
                        Label(g, systemImage: ["tortoise", "ruler", "square.on.square.dashed", "link", "circle.grid.3x3"][min(i, 4)])
                            .font(.callout)
                    }
                }
                Section {
                    Button {
                        Task { await rescan.start() }
                    } label: {
                        Label("Start rescan", systemImage: "viewfinder").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(rescan.starting)
                }
            }
            .navigationTitle("Rescan an area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { rescan.showGuide = false } }
            }
        }
        .presentationDetents([.large, .medium])
    }
}

// MARK: - coverage strip (above the walk bar while scanning)

struct RescanStrip: View {
    @ObservedObject var rescan: RescanController
    @ObservedObject var cloud: ScanCloudController

    var body: some View {
        if let s = rescan.session, s.phase == .scanning || s.phase == .creating {
            HStack(alignment: .center, spacing: 10) {
                MiniCoverageMap(cells: cloud.topDown, heading: cloud.heading)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.setting == .indoor ? "Rescan room" : "Rescan area").font(.caption.weight(.bold))
                        if s.id == nil, s.phase == .scanning {
                            Text("as a walk").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.3), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        Text("\(cloud.coverage.coveragePct) % good").font(.caption.weight(.bold)).monospacedDigit()
                            .foregroundStyle(cloud.coverage.coveragePct >= 70 ? .green : .orange)
                    }
                    Text(cloud.coverage.line(outdoor: s.setting == .outdoor)).font(.caption2).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(cloud.points / 1000)k points · \(Int(cloud.coverage.coveredM2.rounded())) m² good depth")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                VStack(spacing: 6) {
                    Button { cloud.orbitOpen = true } label: { Image(systemName: "rotate.3d").font(.system(size: 15, weight: .semibold)) }
                        .accessibilityLabel("Pause and view in 3D")
                    Button { rescan.cancel() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)) }
                        .accessibilityLabel("Cancel rescan")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: 440)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Top-down good-depth map around you (green = covered, amber = seen but weak), north-up with your heading.
struct MiniCoverageMap: View {
    let cells: [UInt8]
    let heading: Float

    var body: some View {
        Canvas { ctx, size in
            let n = Int(Double(cells.count).squareRoot())
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(.black.opacity(0.35)))
            guard n > 0 else { return }
            let s = size.width / CGFloat(n)
            for r in 0..<n {
                for c in 0..<n {
                    let v = cells[r * n + c]
                    guard v > 0 else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s + 0.5, height: s + 0.5)),
                             with: .color(v == 2 ? .green.opacity(0.85) : .orange.opacity(0.6)))
                }
            }
            let ctr = CGPoint(x: size.width / 2, y: size.height / 2)
            var p = Path()
            let a = CGFloat(heading)
            p.move(to: CGPoint(x: ctr.x + sin(a) * 9, y: ctr.y - cos(a) * 9))
            p.addLine(to: CGPoint(x: ctr.x + sin(a + 2.5) * 6, y: ctr.y - cos(a + 2.5) * 6))
            p.addLine(to: CGPoint(x: ctr.x + sin(a - 2.5) * 6, y: ctr.y - cos(a - 2.5) * 6))
            p.closeSubpath()
            ctx.fill(p, with: .color(.white))
        }
        .accessibilityLabel("Coverage map")
    }
}

// MARK: - result card

struct RescanCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var rescan: RescanController
    @ObservedObject var cloud: ScanCloudController

    var body: some View {
        if let s = rescan.session, rescan.cardVisible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon(s.phase)).font(.headline).foregroundStyle(tint(s.phase))
                    Text(s.title).font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                    if s.phase == .finishing || (s.phase == .building && !s.stale) { ProgressView() }
                }
                ForEach(Array(s.lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.footnote).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
                if let n = s.next { Text(n).font(.caption).foregroundStyle(.secondary) }
                if s.status?.beforeURL != nil || s.status?.afterURL != nil {
                    HStack(spacing: 8) {
                        preview("Before", rescan.url(s.status?.beforeURL))
                        preview("After", rescan.url(s.status?.afterURL))
                    }
                }
                HStack(spacing: 8) {
                    Button("Done") { rescan.dismiss() }.buttonStyle(.borderedProminent)
                    if cloud.points > 0 {
                        Button { cloud.orbitOpen = true } label: { Label("3D", systemImage: "rotate.3d") }.buttonStyle(.bordered)
                    }
                    Spacer(minLength: 0)
                    if s.phase == .published || s.phase == .building || s.phase == .held {
                        Button { rescan.openInCop() } label: { Label("snailCOP", systemImage: "scope") }.buttonStyle(.bordered)
                    }
                    if s.phase.terminal {
                        Button("Scan again") { rescan.dismiss(); rescan.open(cause: "card_again") }.buttonStyle(.bordered)
                    }
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(14)
            .frame(maxWidth: 440, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func preview(_ title: String, _ url: URL?) -> some View {
        VStack(spacing: 3) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                default: ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 130)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(.caption2.weight(.semibold))
        }
    }

    private func icon(_ p: RescanPhase) -> String {
        switch p {
        case .published: return "checkmark.seal.fill"
        case .held: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .local: return "figure.walk"
        default: return "gearshape.2"
        }
    }

    private func tint(_ p: RescanPhase) -> Color {
        switch p {
        case .published: return .green
        case .held, .local: return .orange
        case .failed: return .red
        default: return .blue
        }
    }
}

// MARK: - orbit view (paused)

struct ScanOrbitView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var cloud: ScanCloudController
    @State private var yaw: Float = 0.6
    @State private var pitch: Float = -0.6
    @State private var dist: Float = 6
    @State private var dragStart: (Float, Float)?
    @State private var pinchStart: Float?
    @State private var center = SIMD3<Float>(0, 0, 0)

    var body: some View {
        ZStack(alignment: .top) {
            OrbitMetalView(renderer: cloud.renderer, eye: eye, target: center)
                .ignoresSafeArea()
                .gesture(DragGesture()
                    .onChanged { g in
                        let s = dragStart ?? (yaw, pitch)
                        dragStart = s
                        yaw = s.0 - Float(g.translation.width) / 150
                        pitch = max(-1.45, min(1.45, s.1 - Float(g.translation.height) / 150))
                    }
                    .onEnded { _ in dragStart = nil })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { m in
                        let s = pinchStart ?? dist
                        pinchStart = s
                        dist = max(0.5, min(80, s / Float(m)))
                    }
                    .onEnded { _ in pinchStart = nil })
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan view · \(cloud.points / 1000)k points").font(.footnote.weight(.bold)).monospacedDigit()
                    Text("Paused: drag to orbit, pinch to zoom").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Faint", isOn: $cloud.showFaint).toggleStyle(.button).font(.caption.weight(.semibold))
                Button("Resume") { cloud.orbitOpen = false }.buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .background(Color.black)
        .onAppear {
            if let b = cloud.bounds() { center = b.center; dist = max(2, b.radius * 2.2) }
            let c = cloud.cameraPosition
            let d = c - center
            if simd_length(SIMD2(d.x, d.z)) > 0.3 { yaw = atan2(d.x, d.z) }
        }
    }

    private var eye: SIMD3<Float> {
        center + dist * SIMD3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw))
    }
}

private struct OrbitMetalView: UIViewRepresentable {
    let renderer: ScanCloudRenderer
    let eye: SIMD3<Float>
    let target: SIMD3<Float>

    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: ScanCloudRenderer
        let queue: MTLCommandQueue?
        var eye = SIMD3<Float>(0, 2, 5)
        var target = SIMD3<Float>(0, 0, 0)
        init(renderer: ScanCloudRenderer) {
            self.renderer = renderer
            queue = renderer.device?.makeCommandQueue()
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let q = queue, let rp = view.currentRenderPassDescriptor, let dr = view.currentDrawable,
                  let cb = q.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
            let size = view.drawableSize
            let aspect = Float(size.width / max(1, size.height))
            let v = ScanCloudRenderer.lookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
            let p = ScanCloudRenderer.perspective(fovyRad: 1.0, aspect: aspect, near: 0.05, far: 300)
            let scale = Float(size.height) / 900
            renderer.encode(enc, color: view.colorPixelFormat, depth: view.depthStencilPixelFormat,
                            uniforms: ScanCloudUniforms(viewProj: p * v, view: v, pointScale: 6 * scale, minSize: 1.5 * scale,
                                                        maxSize: 10 * scale, alpha: 1))
            enc.endEncoding()
            cb.present(dr)
            cb.commit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.clearColor = MTLClearColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.delegate = context.coordinator
        context.coordinator.eye = eye
        context.coordinator.target = target
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        context.coordinator.eye = eye
        context.coordinator.target = target
    }
}
