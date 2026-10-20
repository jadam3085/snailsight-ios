// 9.8 Scans "Drone" mode (owner 2026-10-13: "the same kind of drone mode to explore the scans" as the web viewer's
// Fly): a display-link loop that turns the virtual sticks into a smooth, gravity-off flight of the shared
// ViewerCamera's walk eye (SnailSightCore.DroneMath), swept against the mesh (TriangleIndex.sweep, 20 cm sphere —
// "Walls" toggle), glides for walk points / Home / levels / labels (DroneGlide), and the HUD: dual joysticks,
// altitude buttons, speed slider, level menu, Home and the top-down minimap (FloorPlan of the current level).
// Works in Mesh, Splat and Hybrid alike: the camera is shared; collision needs the mesh (loaded in every view).
import SwiftUI
import UIKit
import simd
import SnailSightCore

/// Display-link target that does not retain the driver.
private final class LinkProxy: NSObject {
    weak var target: DroneDriver?
    @objc func tick(_ l: CADisplayLink) {
        MainActor.assumeIsolated { target?.tick(l) }
    }
}

@MainActor
final class DroneDriver: ObservableObject {
    @Published var speed: Float = 1.2 { didSet { params.maxSpeed = speed } }
    /// Ghost (collision off) is remembered across launches (9.9.97: "I need a ghost mode button to go through walls").
    @Published var collide = !UserDefaults.standard.bool(forKey: "scan.ghost") {
        didSet { params.collide = collide; UserDefaults.standard.set(!collide, forKey: "scan.ghost") }
    }
    @Published private(set) var active = false
    @Published private(set) var blocked = false          // the last step was stopped by a wall (HUD hint)
    private(set) var params = DroneParams()
    /// Stick state, written by the HUD; any stick input cancels a glide.
    var input = DroneInput() { didSet { if !input.isIdle { glide = nil } } }
    /// `(from, to) -> reached` against the mesh; nil = no mesh yet (or a splat-only scene): free flight.
    var collider: ((SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>)?
    var home: WalkCamera?
    /// 12.3 Map ▸ 3D: a replacement for DroneMath.step (SnailSightCore.Map3DFly: walk / run / drone presets, look clamp,
    /// ground clamp). nil = the Scans drone maths.
    var stepper: ((DroneState, DroneInput, Float) -> DroneState)?
    let camera: ViewerCamera

    private var velocity = SIMD3<Float>.zero
    private var glide: DroneGlide?
    private var glideT: Float = 0
    private var link: CADisplayLink?
    private let proxy = LinkProxy()
    private var last: CFTimeInterval = 0

    init(camera: ViewerCamera) { self.camera = camera; params.collide = collide }

    func start() {
        guard !active else { return }
        active = true
        velocity = .zero
        input = DroneInput()
        if camera.mode != .walk { camera.mode = .walk }
        if home == nil { home = camera.walk }
        proxy.target = self
        let l = CADisplayLink(target: proxy, selector: #selector(LinkProxy.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        last = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
        active = false
        glide = nil
        velocity = .zero
        input = DroneInput()
    }

    /// A first-person move from a gesture (two fingers / pinch): through the walls only in Ghost.
    func sweep(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        guard collide, let c = collider else { return b }
        return c(a, b)
    }

    /// Smooth flight to a pose (walk point, Home, level, label).
    func fly(to pose: WalkCamera) {
        if camera.mode != .walk { camera.mode = .walk }
        glide = DroneGlide(from: camera.walk, to: pose)
        glideT = 0
        velocity = .zero
    }

    func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt: Float = last == 0 ? 1.0 / 60 : Float(now - last)
        last = now
        if let g = glide {
            glideT += dt
            camera.walk = g.pose(at: glideT)
            if g.done(at: glideT) { glide = nil }
            camera.changed()
            return
        }
        if input.isIdle && velocity == .zero { return }
        let want = camera.walk.eye + velocity * min(dt, 0.1)
        let s = stepper?(DroneState(camera: camera.walk, velocity: velocity), input, dt)
            ?? DroneMath.step(DroneState(camera: camera.walk, velocity: velocity), input, dt: dt, params: params,
                              collider: collider)
        velocity = s.velocity
        let b = params.collide && collider != nil && simd_distance(s.camera.eye, want) > 0.01 && simd_length(velocity) < 0.05
            && !(input.move == .zero && input.climb == 0)
        if b != blocked { blocked = b }
        camera.walk = s.camera
        camera.changed()
    }
}

/// Eye position / heading for the minimap, published at most ~12 Hz.
@MainActor
final class CameraTracker: ObservableObject {
    @Published private(set) var eye = SIMD3<Float>.zero
    @Published private(set) var yaw: Float = 0
    private var lastT = Date.distantPast

    func update(_ c: ViewerCamera) {
        let now = Date()
        guard now.timeIntervalSince(lastT) > 0.08 else { return }
        lastT = now
        eye = c.eye
        let f = c.forward
        yaw = WalkCamera.yaw(of: SIMD3(f.x, 0, f.z))
    }
}

// MARK: HUD

/// A floating thumb-stick: touch anywhere on the pad, drag; release recentres.
struct JoystickPad: View {
    let title: String
    let onChange: (SIMD2<Float>) -> Void
    var radius: CGFloat = 54
    @State private var knob = CGSize.zero

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.28))
            Circle().stroke(.white.opacity(0.45), lineWidth: 1.5)
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).offset(y: radius - 14)
            Circle().fill(.white.opacity(0.85)).frame(width: 46, height: 46).offset(knob)
                .shadow(radius: 2)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = Float(v.translation.width), dy = Float(v.translation.height)
                    let k = Joystick.knob(dx: dx, dy: dy, radius: Float(radius))
                    knob = CGSize(width: CGFloat(k.x), height: CGFloat(k.y))
                    onChange(Joystick.vector(dx: dx, dy: dy, radius: Float(radius)))
                }
                .onEnded { _ in
                    knob = .zero
                    onChange(.zero)
                }
        )
        .accessibilityLabel(title)
    }
}

/// Press-and-hold button (altitude).
struct HoldButton: View {
    let systemImage: String
    let onHold: (Bool) -> Void
    @State private var down = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.bold))
            .frame(width: 52, height: 46)
            .background((down ? Color.accentColor : Color.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.45), lineWidth: 1.5))
            .foregroundStyle(.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !down { down = true; onHold(true) } }
                    .onEnded { _ in down = false; onHold(false) }
            )
    }
}

struct DroneHUD: View {
    @ObservedObject var driver: DroneDriver
    let levelNames: [String]
    let level: Int?
    let canCollide: Bool
    let onLevel: (Int) -> Void
    let onHome: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").font(.caption)
                Slider(value: $driver.speed, in: DroneParams.speedRange)
                Image(systemName: "hare.fill").font(.caption)
                Text(String(format: "%.1f m/s", driver.speed)).font(.caption.monospacedDigit()).frame(width: 58)
            }
            HStack(spacing: 10) {
                Toggle(isOn: $driver.collide) {
                    Label(driver.collide ? "Walls" : "Ghost", systemImage: driver.collide ? "shield.fill" : "shield.slash")
                }
                .toggleStyle(.button)
                .disabled(!canCollide)
                if !levelNames.isEmpty {
                    Menu {
                        ForEach(levelNames.indices, id: \.self) { i in
                            Button { onLevel(i) } label: {
                                if i == level { Label(levelNames[i], systemImage: "checkmark") } else { Text(levelNames[i]) }
                            }
                        }
                    } label: {
                        Label(level.map { levelNames[$0] } ?? "Level", systemImage: "square.stack.3d.up")
                    }
                }
                Spacer(minLength: 0)
                Button(action: onHome) { Label("Home", systemImage: "house.fill") }
            }
            .font(.callout)
            if driver.blocked {
                Text("Wall ahead — tap Walls to fly through").font(.caption2).foregroundStyle(.orange)
            }
            HStack(alignment: .center) {
                JoystickPad(title: "move") { driver.input.move = $0 }
                Spacer()
                VStack(spacing: 10) {
                    HoldButton(systemImage: "arrow.up") { driver.input.climb = $0 ? 1 : 0 }
                    HoldButton(systemImage: "arrow.down") { driver.input.climb = $0 ? -1 : 0 }
                }
                Spacer()
                JoystickPad(title: "look") { driver.input.look = $0 }
            }
        }
    }
}

/// 9.9 "Simple" fly HUD (owner on 9.8.91: "I liked the older minimalist fly control"; the 9.6 walk and the web viewer
/// Fly): one move stick bottom-left, drag anywhere on the scan to look, ▲▼ height bottom-right, and a row of small
/// icons (walls / ghost, speed preset, level, home). No panel behind it.
struct MinimalFlyHUD: View {
    /// 9.9.97: Advanced (controller) uses this same compact layout plus a small look stick bottom-right.
    var advanced = false
    @ObservedObject var driver: DroneDriver
    let levelNames: [String]
    let level: Int?
    let canCollide: Bool
    let onLevel: (Int) -> Void
    let onHome: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            JoystickPad(title: "", onChange: { driver.input.move = $0 }, radius: 46)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if driver.blocked {
                    Text("Wall · tap Walls for Ghost").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.45), in: Capsule())
                }
                HStack(spacing: 6) {
                    chip { driver.collide.toggle() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: driver.collide ? "shield.fill" : "figure.walk.motion")
                            Text(driver.collide ? "Walls" : "Ghost").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(driver.collide ? Color.white : Color.cyan)
                    }
                    .disabled(!canCollide)
                    .accessibilityLabel(driver.collide ? "Walls on, tap for Ghost mode" : "Ghost mode on, tap for walls")
                    chip { driver.speed = FlyControl.nextSpeed(after: driver.speed) } label: {
                        Text(String(format: driver.speed < 1 ? "%.1f" : "%.0f", driver.speed) + " m/s")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                    }
                    .accessibilityLabel("Speed")
                    if !levelNames.isEmpty {
                        Menu {
                            ForEach(levelNames.indices, id: \.self) { i in
                                Button { onLevel(i) } label: {
                                    if i == level { Label(levelNames[i], systemImage: "checkmark") } else { Text(levelNames[i]) }
                                }
                            }
                        } label: { chipLabel(Image(systemName: "square.stack.3d.up")) }
                    }
                    chip(action: onHome) { Image(systemName: "house.fill") }
                        .accessibilityLabel("Home")
                }
                HStack(alignment: .bottom, spacing: 8) {
                    HoldButton(systemImage: "arrow.up") { driver.input.climb = $0 ? 1 : 0 }
                    HoldButton(systemImage: "arrow.down") { driver.input.climb = $0 ? -1 : 0 }
                    if advanced { JoystickPad(title: "", onChange: { driver.input.look = $0 }, radius: 46) }
                }
            }
        }
    }

    private func chip<L: View>(action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) { chipLabel(label()) }.buttonStyle(.plain)
    }

    private func chipLabel<L: View>(_ l: L) -> some View {
        l.font(.callout.weight(.semibold))
            .frame(minWidth: 34, minHeight: 30)
            .padding(.horizontal, 4)
            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.35), lineWidth: 1))
            .foregroundStyle(.white)
    }
}

// MARK: minimap

enum PlanImage {
    static func make(_ fp: FloorPlan) -> CGImage? {
        let data = Data(fp.rgba()) as CFData
        guard let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(width: fp.width, height: fp.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: fp.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Plan pixels ↔ view points for a plan aspect-fitted (then zoomed / panned) in a view.
struct PlanFit {
    var scale: CGFloat               // points per plan pixel
    var origin: CGPoint              // view point of plan pixel (0, 0)

    static func fit(_ fp: FloorPlan, in size: CGSize, inset: CGFloat = 4) -> PlanFit {
        let s = min((size.width - inset * 2) / CGFloat(fp.width), (size.height - inset * 2) / CGFloat(fp.height))
        let w = CGFloat(fp.width) * s, h = CGFloat(fp.height) * s
        return PlanFit(scale: max(s, 1e-3), origin: CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2))
    }

    func view(_ px: SIMD2<Float>) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(px.x) * scale, y: origin.y + CGFloat(px.y) * scale)
    }
    func plan(_ p: CGPoint) -> SIMD2<Float> {
        SIMD2(Float((p.x - origin.x) / scale), Float((p.y - origin.y) / scale))
    }
    func rect(_ fp: FloorPlan) -> CGRect {
        CGRect(x: origin.x, y: origin.y, width: CGFloat(fp.width) * scale, height: CGFloat(fp.height) * scale)
    }
}

extension Color {
    /// "#4363d8" → Color (rooms' colours from the server).
    init(hex: String?, fallback: Color = .blue) {
        guard let h = hex, h.count == 7, h.hasPrefix("#"), let v = UInt32(h.dropFirst(), radix: 16) else { self = fallback; return }
        self = Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// Top-down plan of the current level with rooms, labels and the eye (position + heading). Tap = fly there.
struct MinimapView: View {
    let plan: FloorPlan
    let image: CGImage
    @ObservedObject var tracker: CameraTracker
    let rooms: [RoomRecord]
    let labels: [MapLabel]
    let onTap: (SIMD3<Float>) -> Void

    var body: some View {
        GeometryReader { geo in
            let fit = PlanFit.fit(plan, in: geo.size)
            Canvas { ctx, _ in
                ctx.draw(Image(decorative: image, scale: 1), in: fit.rect(plan))
                for r in rooms {
                    let pts = r.points.map { fit.view(plan.pixel(mapX: $0.x, mapY: $0.y)) }
                    guard pts.count >= 3 else { continue }
                    var path = Path()
                    path.addLines(pts)
                    path.closeSubpath()
                    let c = Color(hex: r.color)
                    ctx.fill(path, with: .color(c.opacity(0.18)))
                    ctx.stroke(path, with: .color(c), lineWidth: 1.2)
                }
                for l in labels where l.kind == "object" {
                    let p = fit.view(plan.pixel(mapX: l.mapPoint.x, mapY: l.mapPoint.y))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(.yellow))
                }
                // the eye: dot + heading wedge
                let e = fit.view(plan.pixel(tracker.eye))
                let d = PlanHeading.direction(yaw: tracker.yaw)
                let dir = CGPoint(x: CGFloat(d.x), y: CGFloat(d.y)), side = CGPoint(x: -dir.y, y: dir.x)
                var wedge = Path()
                wedge.move(to: CGPoint(x: e.x + dir.x * 14, y: e.y + dir.y * 14))
                wedge.addLine(to: CGPoint(x: e.x + side.x * 6 - dir.x * 3, y: e.y + side.y * 6 - dir.y * 3))
                wedge.addLine(to: CGPoint(x: e.x - side.x * 6 - dir.x * 3, y: e.y - side.y * 6 - dir.y * 3))
                wedge.closeSubpath()
                ctx.fill(wedge, with: .color(.cyan))
                ctx.stroke(wedge, with: .color(.black), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                let px = fit.plan(p)
                guard px.x >= 0, px.y >= 0, px.x <= Float(plan.width), px.y <= Float(plan.height) else { return }
                onTap(plan.world(px, y: plan.floorY))
            }
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.35), lineWidth: 1))
    }
}
