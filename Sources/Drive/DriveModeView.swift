// SnailSight 12.7 drive mode overlay: the slim top strip, twin sticks (UIKit multi-touch pad: both sticks at once, each
// touch tracked on its own), Turbo hold, the quick wheel, Tank, the controller badge, the Take over banner, and in FPV /
// Chase the crosshair, the minimap inset and the last-AR-frame PiP. Every hit target ≥ 44 pt.
import SwiftUI
import UIKit
import SnailSightCore

struct DriveModeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ui: DriveUI
    @ObservedObject var shared: ServerSimUI

    private var drive: DriveController { model.drive }

    var body: some View {
        ZStack {
            if !ui.controllerMode {
                TwinStickPad(showRight: ui.hasTurret || ui.view != .ar,
                             onLeft: { drive.setLeft($0) }, onRight: { drive.setRight($0) },
                             onRightDoubleTap: { drive.rightDoubleTap() })
                    .ignoresSafeArea()
            }
            if ui.view != .ar { crosshair }
            VStack(spacing: 6) {
                strip
                if let o = ui.otherDriver { takeOverBanner(o) }
                if !ui.turretText.isEmpty {
                    Text(ui.turretText).font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.45), in: Capsule())
                }
                if let t = model.toast {
                    Text(t).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                HStack(alignment: .top) {
                    if ui.view != .ar, let img = ui.pip { pip(img) }
                    Spacer()
                    if ui.view != .ar { DriveMinimap(data: model.planData).frame(width: 128, height: 128) }
                }
                Spacer(minLength: 0)
                bottomControls
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)
            if ui.wheelOpen { DriveWheelView(ui: ui).allowsHitTesting(false) }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .animation(.snappy(duration: 0.15), value: ui.wheelOpen)
    }

    // MARK: strip

    private var strip: some View {
        HStack(spacing: 8) {
            Button { drive.exit(why: "button") } label: {
                Image(systemName: "chevron.left").font(.headline.weight(.bold)).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit drive mode")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: ui.symbol).font(.caption.weight(.bold)).foregroundStyle(.cyan)
                    Text(ui.title).font(.subheadline.weight(.bold)).lineLimit(1)
                    Text(ui.speedText).font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(ui.turbo ? Color.orange : Color.primary).lineLimit(1)
                }
                Text(ui.statusText).font(.caption2).foregroundStyle(ui.statusWarn ? Color.orange : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 2)
            if ui.serverBody { viewToggle }
            Button { drive.estop(via: "button") } label: {
                Text("STOP").font(.caption.weight(.heavy)).foregroundStyle(.white).frame(width: 56, height: 44)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Emergency stop")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var viewToggle: some View {
        HStack(spacing: 0) {
            ForEach(DriveView.allCases, id: \.self) { v in
                Button { drive.setView(v) } label: {
                    Text(v.title).font(.caption.weight(.bold)).frame(minWidth: 40, minHeight: 44)
                        .foregroundStyle(ui.view == v ? Color.black : Color.primary)
                        .background(ui.view == v ? Color.cyan : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(v.title) view")
                .accessibilityAddTraits(ui.view == v ? .isSelected : [])
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func takeOverBanner(_ who: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.black)
            Text("\(ui.title) is driven by \(who)").font(.caption.weight(.semibold)).foregroundStyle(.black).lineLimit(2)
            Spacer(minLength: 4)
            Button("Take over") { drive.takeOver() }
                .font(.caption.weight(.bold)).buttonStyle(.borderedProminent).tint(.black).frame(minHeight: 44)
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background(Color.orange.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: bottom: tank · wheel · turbo · controller badge (the sticks are the pad underneath)

    private var bottomControls: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom) {
                if ui.ackermann {
                    Toggle(isOn: $model.driveTank) {
                        Label("Tank", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold))
                    }
                    .toggleStyle(.button).buttonStyle(.bordered).frame(minHeight: 44)
                    .accessibilityLabel("Tank steering: turn like the robot")
                }
                Spacer()
                if ui.padName != nil || ui.controllerMode { controllerBadge }
                Spacer()
                turboButton
            }
            HStack {
                Spacer()
                wheelButton
                Spacer()
            }
            Color.clear.frame(height: ui.controllerMode ? 0 : 96).allowsHitTesting(false)   // the sticks' room
        }
    }

    private var controllerBadge: some View {
        Button { drive.setControllerMode(!ui.controllerMode, via: "badge") } label: {
            Label(ui.controllerMode ? (ui.padName ?? "Controller") : "Sticks", systemImage: "gamecontroller.fill")
                .font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 10).frame(minHeight: 44)
                .background(ui.controllerMode ? AnyShapeStyle(Color.green.opacity(0.35)) : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ui.controllerMode ? "Controller mode on: tap to show the on-screen sticks" : "Controller mode off")
    }

    private var turboButton: some View {
        Text("TURBO").font(.caption.weight(.heavy))
            .foregroundStyle(ui.turbo ? Color.black : Color.white)
            .frame(width: 72, height: 48)
            .background(ui.turbo ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.black.opacity(0.45)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.orange, lineWidth: 1.5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in drive.setTurbo(true) }
                .onEnded { _ in drive.setTurbo(false) })
            .accessibilityLabel("Turbo: hold for 50 % more speed")
    }

    private var wheelButton: some View {
        Image(systemName: "circle.grid.cross.fill").font(.title3.weight(.semibold))
            .frame(width: 56, height: 56)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.cyan.opacity(0.6)))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in drive.wheelTouch(V2(Double(g.translation.width) / 70, Double(-g.translation.height) / 70), ended: false) }
                .onEnded { _ in drive.wheelTouch(nil, ended: true) })
            .accessibilityLabel("Quick wheel: hold, slide to an action, let go")
    }

    // MARK: FPV extras

    private var crosshair: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5).frame(width: 34, height: 34)
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 2, height: 12).offset(y: -24)
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 2, height: 12).offset(y: 24)
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 12, height: 2).offset(x: -24)
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 12, height: 2).offset(x: 24)
            Circle().fill(Color.red).frame(width: 4, height: 4)
        }
        .shadow(radius: 1.5)
        .allowsHitTesting(false)
    }

    private func pip(_ img: UIImage) -> some View {
        Button { drive.setView(.ar) } label: {
            Image(uiImage: img).resizable().scaledToFill().frame(width: 84, height: 128).clipped()
                .overlay(alignment: .bottomLeading) {
                    Text("AR · last frame").font(.system(size: 9, weight: .bold)).padding(3)
                        .background(.black.opacity(0.6)).foregroundStyle(.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to the AR view")
    }
}

// MARK: - the quick wheel

struct DriveWheelView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ui: DriveUI

    var body: some View {
        let items = DriveWheelItem.allCases
        ZStack {
            Circle().fill(Color.black.opacity(0.72)).frame(width: 250, height: 250)
                .overlay(Circle().stroke(Color.cyan.opacity(0.4)))
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                let o = QuickWheel.offset(i, count: items.count)
                let on = model.drive.wheelAvailable(it)
                VStack(spacing: 2) {
                    Image(systemName: it.symbol).font(.system(size: 18, weight: .semibold))
                    Text(it.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(ui.wheelPick == i ? Color.black : Color.white)
                .frame(width: 58, height: 58)
                .background(ui.wheelPick == i ? Color.cyan : Color.white.opacity(0.08), in: Circle())
                .scaleEffect(ui.wheelPick == i ? 1.18 : 1)
                .opacity(on ? 1 : 0.35)
                .offset(x: CGFloat(o.x * 92), y: CGFloat(o.y * 92))
            }
            Text(ui.wheelPick.map { items[$0].title } ?? "slide to pick").font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - minimap (plan view of the driven body's storey, north up)

struct DriveMinimap: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var data: MapPlanData
    static let ppm = 6.0                                   // ≈ 21 m across

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Canvas { g, size in draw(&g, size) }
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.25)))
        .allowsHitTesting(false)
        .onAppear { refresh() }
    }

    private func refresh() {
        let lv = model.drive.bodyID.flatMap { model.serverSim.driven($0)?.level }
        data.refresh(level: data.levels.first { $0.level == lv } ?? data.levels.first { $0.level != nil })
    }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize) {
        guard let id = model.drive.bodyID, let d = model.serverSim.driven(id) else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: c.x + (x - d.pose.x) * Self.ppm, y: c.y - (y - d.pose.y) * Self.ppm)
        }
        let lv = d.level ?? data.levels.compactMap(\.level).first
        if let l = lv, let img = data.planImages[l], let fp = data.floorplans[l] {
            let a = pt(fp.bounds[0], fp.bounds[3]), b = pt(fp.bounds[2], fp.bounds[1])
            g.draw(Image(decorative: img, scale: 1), in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
        } else if let l = lv, data.planImages[l] == nil {
            DispatchQueue.main.async { refresh() }
        }
        for b in model.serverSim.bodyInfos() where b.id != id {
            let p = pt(b.pose[0], b.pose[1])
            g.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                   with: .color(b.role == .animal ? .orange : b.role == .robot ? .blue : .brown))
        }
        if let me = model.controller.mapLayer.cameraMap {          // the phone
            let p = pt(me[0], me[1])
            g.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.green))
        }
        // look cone (body + turret / view pan), then the body arrow
        let look = d.pose.theta + (d.turret?.yaw ?? (d.spec == nil ? model.drive.viewPan.yaw : 0))
        var cone = Path()
        cone.move(to: c)
        cone.addLine(to: CGPoint(x: c.x + cos(look + 0.5) * 34, y: c.y - sin(look + 0.5) * 34))
        cone.addLine(to: CGPoint(x: c.x + cos(look - 0.5) * 34, y: c.y - sin(look - 0.5) * 34))
        cone.closeSubpath()
        g.fill(cone, with: .color(.red.opacity(0.35)))
        var tri = Path()
        let h = d.pose.theta
        tri.move(to: CGPoint(x: c.x + cos(h) * 8, y: c.y - sin(h) * 8))
        tri.addLine(to: CGPoint(x: c.x + cos(h + 2.5) * 6, y: c.y - sin(h + 2.5) * 6))
        tri.addLine(to: CGPoint(x: c.x + cos(h - 2.5) * 6, y: c.y - sin(h - 2.5) * 6))
        tri.closeSubpath()
        g.fill(tri, with: .color(.cyan))
    }
}

// MARK: - twin-stick pad (UIKit: real multi-touch, each stick owns its own UITouch)

struct TwinStickPad: UIViewRepresentable {
    var showRight: Bool
    var onLeft: (V2) -> Void
    var onRight: (V2) -> Void
    var onRightDoubleTap: () -> Void

    func makeUIView(context: Context) -> TwinStickPadView {
        let v = TwinStickPadView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: TwinStickPadView, context: Context) {
        v.onLeft = onLeft
        v.onRight = onRight
        v.onRightDoubleTap = onRightDoubleTap
        v.showRight = showRight
    }
}

final class TwinStickPadView: UIView {
    var onLeft: ((V2) -> Void)?
    var onRight: ((V2) -> Void)?
    var onRightDoubleTap: (() -> Void)?
    var showRight = true { didSet { if showRight != oldValue { rightBase.isHidden = !showRight; rightKnob.isHidden = !showRight } } }

    static let radius: CGFloat = 62                      // 124 pt sticks (HUD-sized), knob 52 pt
    static let margin: CGFloat = 22
    private let leftBase = CAShapeLayer(), rightBase = CAShapeLayer()
    private let leftKnob = CAShapeLayer(), rightKnob = CAShapeLayer()
    private var leftTouch: UITouch?, rightTouch: UITouch?
    private var tap = DoubleTapDetector()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for (b, k) in [(leftBase, leftKnob), (rightBase, rightKnob)] {
            b.fillColor = UIColor.black.withAlphaComponent(0.35).cgColor
            b.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
            b.lineWidth = 2
            k.fillColor = UIColor.white.withAlphaComponent(0.9).cgColor
            k.shadowOpacity = 0.3; k.shadowRadius = 3; k.shadowOffset = .zero
            layer.addSublayer(b)
            layer.addSublayer(k)
        }
        rightBase.strokeColor = UIColor.systemRed.withAlphaComponent(0.8).cgColor   // the turret stick reads apart
    }

    required init?(coder: NSCoder) { fatalError() }

    private var leftCentre: CGPoint {
        CGPoint(x: safeAreaInsets.left + Self.margin + Self.radius, y: bounds.height - safeAreaInsets.bottom - Self.margin - Self.radius)
    }
    private var rightCentre: CGPoint {
        CGPoint(x: bounds.width - safeAreaInsets.right - Self.margin - Self.radius,
                y: bounds.height - safeAreaInsets.bottom - Self.margin - Self.radius)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (b, c) in [(leftBase, leftCentre), (rightBase, rightCentre)] {
            b.path = UIBezierPath(ovalIn: CGRect(x: c.x - Self.radius, y: c.y - Self.radius, width: Self.radius * 2,
                                                 height: Self.radius * 2)).cgPath
        }
        place(leftKnob, at: leftCentre)
        place(rightKnob, at: rightCentre)
        CATransaction.commit()
    }

    private func place(_ k: CAShapeLayer, at p: CGPoint) {
        let r: CGFloat = 26
        k.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).cgPath
    }

    /// Only the two stick zones take touches; everything else falls through to the AR / 3D view and the buttons.
    override func point(inside p: CGPoint, with event: UIEvent?) -> Bool {
        let grab = Self.radius + 26
        if hypot(p.x - leftCentre.x, p.y - leftCentre.y) <= grab { return true }
        return showRight && hypot(p.x - rightCentre.x, p.y - rightCentre.y) <= grab
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if leftTouch == nil, hypot(p.x - leftCentre.x, p.y - leftCentre.y) <= Self.radius + 26 {
                leftTouch = t
                update(t)
            } else if showRight, rightTouch == nil, hypot(p.x - rightCentre.x, p.y - rightCentre.y) <= Self.radius + 26 {
                rightTouch = t
                if tap.touchDown(at: t.timestamp) { onRightDoubleTap?() }
                update(t)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { update(t) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { end(t) } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { end(t) } }

    private func vector(_ t: UITouch, centre c: CGPoint) -> (V2, CGPoint) {
        let p = t.location(in: self)
        var dx = p.x - c.x, dy = p.y - c.y
        let d = hypot(dx, dy)
        if d > Self.radius { dx = dx / d * Self.radius; dy = dy / d * Self.radius }
        return (V2(Double(dx / Self.radius), Double(-dy / Self.radius)), CGPoint(x: c.x + dx, y: c.y + dy))
    }

    private func update(_ t: UITouch) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if t === leftTouch {
            let (v, k) = vector(t, centre: leftCentre)
            place(leftKnob, at: k)
            onLeft?(v)
        } else if t === rightTouch {
            let (v, k) = vector(t, centre: rightCentre)
            place(rightKnob, at: k)
            onRight?(v)
        }
        CATransaction.commit()
    }

    private func end(_ t: UITouch) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if t === leftTouch { leftTouch = nil; place(leftKnob, at: leftCentre); onLeft?(.zero) }
        else if t === rightTouch { rightTouch = nil; place(rightKnob, at: rightCentre); onRight?(.zero) }
        CATransaction.commit()
    }
}
