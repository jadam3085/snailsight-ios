// SnailSight 12.7 drive mode (owner 2026-10-22: "It's hard to see and drive at the same time. I want the right thumbstick
// and I want that to control turret orientation" · "If you're doing a full screen drive mode, give me teleop control like
// in the robosnailbob project, and give first person view with 3d world").
// - Tapping Drive (ring / bar) enters a full-screen driving layout (SnailSightCore.DriveModeLayout): the ring, the O2 ops
//   card, the selection bar, the rail, the status pill and the sheet are hidden; a slim strip (body, speed, lease holder /
//   nav / connection, AR | FPV | Chase, Exit, E-stop) and twin sticks remain. Exit restores the previous layout exactly and
//   releases the controller lease (`cmd {release: true}`).
// - Twin sticks with RoboSnailBob HUD parity (core TeleopMap): left = drive (Tank toggle for the rc_car), right = turret
//   rate (double-tap recentres), Turbo hold (+50 %), release decel ramp, E-stop, speed readout, controller mode, the quick
//   wheel (hold L2 / the wheel button). ONE 10 Hz WS message carries drive + turret (API §5.9.10).
// - Gamepad (GameSir G8 Galileo, any extended gamepad): GamepadInput → core GamepadRouter → the same paths.
// - rc_car: no server turret; the right stick pans the app's own view in FPV / Chase (core ViewPan) and is hidden in AR.
// - The local (offline) sim robot: drive mode with the left stick in AR only.
// Logs: drive_mode_enter / _exit, drive_view, drive_estop, drive_takeover, drive_wheel, drive_turbo, turret_aim /
// turret_centre / turret_step, gamepad_connect / _disconnect, controller_mode, fpv_* (DriveViewer).
import Combine
import SwiftUI
import UIKit
import SnailSightCore

/// What the drive overlay shows (its own ObservableObject: the 10 Hz loop never churns AppModel).
final class DriveUI: ObservableObject {
    @Published var active = false
    @Published var view: DriveView = .ar
    @Published var title = ""
    @Published var symbol = "car.side"
    @Published var speedText = "0.00 m/s"
    @Published var statusText = ""
    @Published var statusWarn = false
    @Published var otherDriver: String?
    @Published var turbo = false
    @Published var hasTurret = false
    @Published var ackermann = false
    @Published var serverBody = true
    @Published var turretText = ""
    @Published var controllerMode = false
    @Published var padName: String?
    @Published var wheelOpen = false
    @Published var wheelPick: Int?
    @Published var pip: UIImage?                     // the AR view's last frame (FPV / Chase pause AR)
    @Published var fpvStatus = ""
    @Published var leftKnob = CGSize.zero            // drawn stick offsets (unit disc, y down)
    @Published var rightKnob = CGSize.zero
}

final class DriveController {
    private unowned let model: AppModel
    let ui = DriveUI()
    private(set) var layout = DriveModeLayout()
    private var sender = TeleopFrameSender()
    private var decel = DecelRamp()
    private var lastDrive = DriveInput.zero
    private var driving = false
    private var aiming = false
    private var aimStart = 0.0
    private var estopLatched = false
    private var forceNext = false
    private var enteredAt = 0.0
    private var lastUI = 0.0
    // inputs
    private var touchLeft = V2.zero
    private var touchRight = V2.zero
    private var turboHeld = false
    private var wheelVec: V2?                        // the on-screen wheel: finger offset (x right, y up), nil = closed
    private(set) var viewPan = ViewPan()
    private var lastPanAt = 0.0
    // gamepad
    let pad = GamepadInput()
    private(set) var padConfig = GamepadConfig.decode(UserDefaults.standard.data(forKey: GamepadConfig.defaultsKey))
    private var router = GamepadRouter()
    private var padOut = GamepadOutput(axes: TwinStickAxes(), turbo: false, wheelHeld: false, fired: [])
    private var padWheel = false
    private var padMenuWheel = false
    private var lastPadFrame = GamepadFrame()

    init(model: AppModel) {
        self.model = model
        ui.controllerMode = padConfig.controllerMode ?? false
        pad.onFrame = { [weak self] f in self?.padFrame(f) }
        pad.onConnect = { [weak self] name, connected in self?.padConnected(name, connected) }
        pad.start()
    }

    var active: Bool { layout.active }
    var view: DriveView { layout.view }
    var bodyID: String? { layout.bodyID }
    private var now: Double { Date().timeIntervalSince1970 }
    private var sim: ServerSimClient { model.serverSim }
    private var serverMode: Bool { !(layout.bodyID ?? "").hasPrefix("local.") }

    // MARK: enter / exit

    /// Drive (ring / bar / L3): the selected drivable body.
    func enter() {
        let shared = sim.ui
        if shared.active, let s = shared.selection, s.drivable {
            enter(body: s.id)
        } else if !shared.active, let s = model.controller.sim.ui.selection, s.kind.role == .robot {
            enter(body: "local.\(s.id)")
        } else {
            model.flash("Select a robot or RC car first, then Drive", seconds: 2)
        }
    }

    private func enter(body id: String) {
        let snap = DriveLayoutSnapshot(sheetDetent: model.sheetDetent, selectionID: model.serverSim.ui.selection?.id,
                                       statusExpanded: model.statusExpanded, locExpanded: model.locExpanded,
                                       legacyJoystickHidden: model.driveHidden)
        let was = layout.active
        guard layout.enter(body: id, current: snap) else { return }
        model.sheetDetent = .collapsed
        model.statusExpanded = false
        model.locExpanded = false
        model.driveHidden = true                          // the 12.5 single joystick is replaced by the twin sticks
        model.serverSim.stopDriving()
        model.controller.sim.setStick(.zero)
        model.serverSim.cancelPending()
        sender = TeleopFrameSender()
        decel.cancel()
        estopLatched = false
        viewPan.centre()
        if !was { enteredAt = now }
        ui.view = layout.view
        ui.active = true
        refreshBody()
        model.serverSim.refreshOtherDriver()
        var ev: [String: LogValue] = ["id": .string(id), "kind": .string(sim.driven(id)?.kind ?? "local"),
                                      "pad": .string(pad.name ?? ""), "controller_mode": .bool(ui.controllerMode),
                                      "turret": .bool(ui.hasTurret), "switch": .bool(was)]
        for (k, v) in MemoryProbe.fields() { ev[k] = v }
        model.log.event("drive_mode_enter", ev)
        if !was {
            model.flash(ui.hasTurret ? "Left stick drives · right stick aims the turret · double-tap it to centre"
                                     : "Left stick drives" + (ui.ackermann ? " · Tank turns like the robot" : ""), seconds: 2.5)
        }
    }

    func exit(why: String = "exit") {
        let id = layout.bodyID
        let fromView = layout.view
        guard let e = layout.exit() else { return }
        stopInputs()
        if let id {
            if id.hasPrefix("local.") { model.controller.sim.setStick(.zero) }
            else { sim.sendRelease(id) }
        }
        sim.hideBody(nil)
        model.sheetDetent = e.restore.sheetDetent
        model.statusExpanded = e.restore.statusExpanded
        model.locExpanded = e.restore.locExpanded
        if let sel = e.restore.selectionID, sim.ui.selection?.id != sel { sim.select(id: sel) }
        model.driveHidden = e.restore.legacyJoystickHidden
        ui.active = false
        ui.wheelOpen = false
        ui.view = .ar
        if e.resumeAR { model.endDriveViewer() }
        ui.pip = nil
        model.log.event("drive_mode_exit", ["id": .string(id ?? ""), "why": .string(why), "view": .string(fromView.rawValue),
                                            "s": .double(((now - enteredAt) * 10).rounded() / 10),
                                            "released": .bool(id.map { !$0.hasPrefix("local.") } ?? false)])
    }

    /// The body went away (deleted / server lost) while driving.
    func bodyGone() {
        guard layout.active else { return }
        model.flash("\(ui.title) is gone: drive mode closed", seconds: 2.5)
        exit(why: "body_gone")
    }

    private func stopInputs() {
        touchLeft = .zero; touchRight = .zero; turboHeld = false; wheelVec = nil
        decel.cancel()
        driving = false
        if aiming { endAim() }
        ui.leftKnob = .zero; ui.rightKnob = .zero
    }

    // MARK: view toggle (AR | FPV | Chase)

    func setView(_ v: DriveView) {
        guard layout.active else { return }
        if v != .ar && !serverMode { model.flash("FPV needs the shared sim (map server + LOCALIZED)", seconds: 2); return }
        guard let ch = layout.setView(v) else { return }
        ui.view = v
        model.log.event("drive_view", ["from": .string(ch.from.rawValue), "to": .string(ch.to.rawValue)])
        if ch.from == .ar && v.pausesAR { model.beginDriveViewer(pip: { [weak self] img in self?.ui.pip = img }) }
        else if ch.from.pausesAR && v == .ar { model.endDriveViewer(); ui.pip = nil }
        sim.hideBody(v == .fpv ? layout.bodyID : nil)
    }

    func cycleView() { setView(layout.view.next) }

    // MARK: touch input (DriveModeView / TwinStickPad)

    func setLeft(_ v: V2) {
        touchLeft = v
        ui.leftKnob = CGSize(width: v.x, height: -v.y)
        if v == .zero { estopLatchCheck() }
    }

    func setRight(_ v: V2) {
        touchRight = v
        ui.rightKnob = CGSize(width: v.x, height: -v.y)
        if v == .zero { estopLatchCheck() }
    }

    /// Double-tap on the right stick.
    func rightDoubleTap() { centreTurret(via: "double_tap") }

    func setTurbo(_ on: Bool) {
        guard on != turboHeld else { return }
        turboHeld = on
        model.log.event("drive_turbo", ["on": .bool(on), "via": .string("touch")])
    }

    // MARK: actions

    func estop(via: String) {
        guard let id = layout.bodyID else { return }
        decel.cancel()
        driving = false
        estopLatched = true                               // sticks ignored until both are let go
        sender.reset()
        if id.hasPrefix("local.") { model.controller.sim.setStick(.zero) }
        else {
            sim.estop(id)
            if ui.hasTurret { sim.sendControl(TeleopMessage(turret: .rate(yaw: 0, pitch: 0)), to: id) }
        }
        model.log.event("drive_estop", ["id": .string(id), "via": .string(via)])
        model.flash("STOP", seconds: 1.2)
    }

    private func estopLatchCheck() {
        if estopLatched, touchLeft == .zero, touchRight == .zero, padOut.axes.drive == .zero, padOut.axes.turret == .zero {
            estopLatched = false
        }
    }

    func takeOver() {
        guard let id = layout.bodyID, serverMode else { return }
        forceNext = true
        sim.sendControl(TeleopMessage(drive: .zero), to: id, force: true)
        forceNext = false
        model.log.event("drive_takeover", ["id": .string(id), "from": .string(sim.ui.otherDriver ?? "")])
    }

    func centreTurret(via: String) {
        guard let id = layout.bodyID else { return }
        if ui.hasTurret {
            sim.sendTurret(.centre, to: id)
            model.log.event("turret_centre", ["id": .string(id), "via": .string(via)])
        } else {
            viewPan.centre()
            model.log.event("turret_centre", ["id": .string(id), "via": .string(via), "view_pan": .bool(true)])
        }
    }

    /// D-pad nudges: absolute aim from the current head pose.
    func stepTurret(yaw dy: Double, pitch dp: Double) {
        guard let id = layout.bodyID, ui.hasTurret, let d = sim.driven(id), let tu = d.turret, let spec = d.spec else { return }
        let y = spec.clampYaw(tu.yaw + dy), p = spec.clampPitch(tu.pitch + dp)
        sim.sendTurret(.aim(yaw: dy != 0 ? y : nil, pitch: dp != 0 ? p : nil), to: id)
        model.log.event("turret_step", ["id": .string(id), "yaw": .double((y * 1000).rounded() / 1000),
                                        "pitch": .double((p * 1000).rounded() / 1000)])
    }

    func toggleTank() {
        guard ui.ackermann else { return }
        model.driveTank.toggle()
        model.log.event("drive_tank", ["on": .bool(model.driveTank), "via": .string("drive_mode")])
    }

    func follow() {
        guard serverMode, sim.ui.selection != nil else { return }
        sim.command(.follow)
    }

    /// Go to: FPV / Chase = the floor point under the crosshair; AR = tap the floor (the usual pending Go to).
    func goTo() {
        guard let id = layout.bodyID, serverMode else { return }
        if layout.view == .ar {
            sim.startPending(.goTo)
            model.flash("Tap the floor where it should go", seconds: 2)
            return
        }
        guard let d = sim.driven(id), let cam = fpvCamera(d) else { return }
        let f = cam.forward
        var dist = 3.0
        if f[2] < -0.02 { dist = min(30, (cam.z - d.pose.z) / -f[2]) }
        let g = [cam.x + f[0] * dist, cam.y + f[1] * dist, d.pose.z]
        sim.goTo(mapPoint: g)
        model.log.event("drive_goto", ["id": .string(id), "goal": .doubles(g.map { ($0 * 100).rounded() / 100 })])
    }

    func switchBody(_ dir: Int) {
        guard serverMode, let cur = layout.bodyID else { return }
        let ids = sim.drivableIDs
        guard ids.count > 1, let i = ids.firstIndex(of: cur) else { return }
        let next = ids[(i + dir + ids.count) % ids.count]
        stopInputs()
        sim.sendRelease(cur)
        sim.select(id: next)
        layout.switchBody(next)
        enter(body: next)
        if layout.view == .fpv { sim.hideBody(next) }
    }

    func wheelAction(_ item: DriveWheelItem) {
        model.log.event("drive_wheel", ["item": .string(item.rawValue)])
        switch item {
        case .stop: estop(via: "wheel")
        case .centreTurret: centreTurret(via: "wheel")
        case .view: cycleView()
        case .tank: toggleTank()
        case .follow: follow()
        case .goTo: goTo()
        case .exit: exit(why: "wheel")
        case .takeOver: takeOver()
        }
    }

    func wheelAvailable(_ item: DriveWheelItem) -> Bool {
        DriveWheelItem.available(item, hasTurret: ui.hasTurret || (ui.serverBody && !ui.hasTurret && layout.view != .ar),
                                 ackermann: ui.ackermann, otherDriver: ui.otherDriver != nil)
    }

    // on-screen wheel (press and hold the wheel button, slide to an item, let go)
    func wheelTouch(_ v: V2?, ended: Bool) {
        if ended {
            let pick = wheelVec.flatMap { QuickWheel.pick($0, count: DriveWheelItem.allCases.count) }
            wheelVec = nil
            ui.wheelOpen = false
            ui.wheelPick = nil
            if let i = pick { wheelAction(DriveWheelItem.allCases[i]) }
            return
        }
        wheelVec = v ?? .zero
        if !ui.wheelOpen { ui.wheelOpen = true }
        let p = QuickWheel.pick(wheelVec ?? .zero, count: DriveWheelItem.allCases.count)
        if ui.wheelPick != p { ui.wheelPick = p }
    }

    func setControllerMode(_ on: Bool, via: String) {
        ui.controllerMode = on
        padConfig.controllerMode = on
        savePad()
        model.log.event("controller_mode", ["on": .bool(on), "via": .string(via), "pad": .string(pad.name ?? "")])
    }

    func applyPreset(_ p: GamepadPreset) {
        padConfig.apply(p)
        savePad()
        model.log.event("gamepad_preset", ["preset": .string(p.rawValue)])
    }

    func setDeadzone(_ d: Double) { padConfig.deadzone = SimMath.clamp(d, 0, 0.4); savePad() }

    private func savePad() { UserDefaults.standard.set(padConfig.encoded(), forKey: GamepadConfig.defaultsKey) }

    // MARK: the 10 Hz send loop (called every frame by ServerSimClient.frame: AR frames, or the FPV viewer's updates)

    func frame(now t: Double) {
        guard layout.active, let id = layout.bodyID else { return }
        let local = id.hasPrefix("local.")
        let wheel = ui.wheelOpen
        var dAxes = touchLeft != .zero ? StickDeadzone.apply(touchLeft, TeleopFeel.touchDeadzone) : padOut.axes.drive
        var tAxes = touchRight != .zero ? StickDeadzone.apply(touchRight, TeleopFeel.touchDeadzone) : padOut.axes.turret
        if wheel || estopLatched { dAxes = .zero; tAxes = .zero }
        if estopLatched { estopLatchCheck() }
        let turbo = turboHeld || padOut.turbo
        if turbo != ui.turbo { ui.turbo = turbo }
        if local {
            model.controller.sim.setStick(dAxes * TeleopFeel.fraction(turbo: turbo))
            updateUI(now: t, drive: nil)
            return
        }
        guard let d = sim.driven(id) else { bodyGone(); return }
        let tank = d.ackermann && model.driveTank
        var drive = TwinStick.drive(dAxes, turbo: turbo, tank: tank)
        if drive.isZero {
            if driving { driving = false; decel.start(from: lastDrive, now: t) }
            drive = estopLatched ? .zero : (decel.value(now: t) ?? DriveInput(throttle: 0, steer: 0, tank: tank))
        } else {
            decel.cancel()
            driving = true
            lastDrive = drive
        }
        var turret: TurretCommand?
        if ui.hasTurret {
            let c = TwinStick.turret(tAxes)
            turret = c
            let on = !c.isZeroRate
            if on && !aiming { aiming = true; aimStart = t; model.log.event("turret_aim", ["id": .string(id), "on": .bool(true)]) }
            else if !on && aiming { endAim() }
        } else {
            viewPan.step(yawRate: -tAxes.x, pitchRate: tAxes.y, dt: lastPanAt > 0 ? t - lastPanAt : 0)
        }
        lastPanAt = t
        if let m = sender.next(drive: drive, turret: turret, now: t) {
            sim.sendControl(m, to: id, force: forceNext)
            forceNext = false
        }
        updateUI(now: t, drive: drive)
    }

    private func endAim() {
        aiming = false
        model.log.event("turret_aim", ["id": .string(layout.bodyID ?? ""), "on": .bool(false),
                                       "s": .double(((now - aimStart) * 10).rounded() / 10)])
    }

    /// The FPV / Chase camera: the server turret camera (vehicle.py turret_camera), else the app's view pan (rc_car).
    func fpvCamera(_ d: DrivenBody) -> FPVPose? {
        if let spec = d.spec, let tu = d.turret {
            return TurretCamera.pose(x: d.pose.x, y: d.pose.y, z: d.pose.z, bodyYaw: d.pose.theta, scale: d.scale, spec: spec,
                                     turretYaw: tu.yaw, turretPitch: tu.pitch)
        }
        if d.spec != nil {                               // turreted, no snapshot pose yet: straight ahead
            return TurretCamera.pose(x: d.pose.x, y: d.pose.y, z: d.pose.z, bodyYaw: d.pose.theta, scale: d.scale,
                                     spec: d.spec!, turretYaw: 0, turretPitch: 0)
        }
        return TurretCamera.pose(x: d.pose.x, y: d.pose.y, z: d.pose.z, bodyYaw: d.pose.theta, scale: d.scale,
                                 spec: .rcCarView, turretYaw: viewPan.yaw, turretPitch: viewPan.pitch)
    }

    private func refreshBody() {
        guard let id = layout.bodyID else { return }
        if id.hasPrefix("local.") {
            ui.title = model.controller.sim.ui.selection?.title ?? "Robot"
            ui.symbol = "car.side"; ui.hasTurret = false; ui.ackermann = false; ui.serverBody = false
            return
        }
        let d = sim.driven(id)
        ui.title = d?.title ?? sim.ui.selection?.title ?? id
        ui.ackermann = d?.ackermann ?? false
        ui.hasTurret = d?.spec != nil
        ui.symbol = ui.ackermann ? "car.side.fill" : "car.side"
        ui.serverBody = true
    }

    /// 5 Hz: speed, status line, turret readout.
    private func updateUI(now t: Double, drive: DriveInput?) {
        guard t - lastUI >= 0.2 else { return }
        lastUI = t
        guard let id = layout.bodyID else { return }
        if id.hasPrefix("local.") {
            setIfChanged(\.speedText, "local sim")
            setIfChanged(\.statusText, "local sim · offline drive")
            return
        }
        refreshBody()
        sim.refreshOtherDriver()
        let other = sim.ui.otherDriver
        if ui.otherDriver != other { ui.otherDriver = other }
        guard let d = sim.driven(id) else { return }
        setIfChanged(\.speedText, SpeedReadout.text(speed: d.speed, throttle: drive?.throttle, turbo: ui.turbo))
        var parts: [String] = []
        let warn: Bool
        if let o = other { parts.append("driven by \(o)"); warn = true }
        else if !sim.socketUp { parts.append("server link down"); warn = true }
        else if !model.controller.mapLayer.isAligned && layout.view == .ar { parts.append("not localized"); warn = true }
        else { parts.append(sim.leases.isMine(id) ? "you drive" : "ready"); warn = false }
        if let n = d.nav, n.isProblem { parts.append(n.text) }
        if let l = d.level { parts.append("L\(l)") }
        if let p = pad.name, ui.controllerMode { parts.append(p) }
        setIfChanged(\.statusText, parts.joined(separator: " · "))
        if ui.statusWarn != warn { ui.statusWarn = warn }
        if let tu = d.turret {
            setIfChanged(\.turretText, String(format: "pan %+.0f° tilt %+.0f°", tu.yaw * 180 / .pi, tu.pitch * 180 / .pi))
        } else if !ui.hasTurret, layout.view != .ar {
            setIfChanged(\.turretText, String(format: "view %+.0f° %+.0f°", viewPan.yaw * 180 / .pi, viewPan.pitch * 180 / .pi))
        } else {
            setIfChanged(\.turretText, "")
        }
    }

    private func setIfChanged(_ k: ReferenceWritableKeyPath<DriveUI, String>, _ v: String) {
        if ui[keyPath: k] != v { ui[keyPath: k] = v }
    }

    // MARK: gamepad

    private func padConnected(_ name: String?, _ connected: Bool) {
        ui.padName = connected ? name : nil
        router.reset()
        padOut = GamepadOutput(axes: TwinStickAxes(), turbo: false, wheelHeld: false, fired: [])
        model.log.event(connected ? "gamepad_connect" : "gamepad_disconnect",
                        ["name": .string(name ?? ""), "preset": .string(padConfig.preset),
                         "controller_mode": .bool(ui.controllerMode)])
        if connected {
            if padConfig.controllerMode == nil { setControllerMode(true, via: "first_pairing") }   // HUD: auto at first pairing
            model.flash("Controller connected: \(name ?? "gamepad") · L3 = drive mode", seconds: 2.5)
        } else if ui.controllerMode {
            model.flash("Controller disconnected: tap the controller badge to bring the sticks back", seconds: 3)
        }
    }

    private func padFrame(_ f: GamepadFrame) {
        guard padConfig.enabled else { return }
        lastPadFrame = f
        let out = router.step(f, config: padConfig)
        padOut = out
        if padOut.axes.drive == .zero && padOut.axes.turret == .zero { estopLatchCheck() }
        // the wheel: L2 held (or Start = sticky menu wheel); the left stick points, release / A selects, B cancels
        let wheelNow = out.wheelHeld || padMenuWheel
        if layout.active && wheelNow {
            if !ui.wheelOpen { ui.wheelOpen = true; model.log.event("drive_wheel_open", ["via": .string("gamepad")]) }
            let p = QuickWheel.pick(f.left, count: DriveWheelItem.allCases.count)
            if ui.wheelPick != p { ui.wheelPick = p }
        } else if padWheel && !wheelNow && !padMenuWheel {
            closePadWheel(activate: true)
        }
        padWheel = out.wheelHeld
        for fn in out.fired { run(fn) }
    }

    private func closePadWheel(activate: Bool) {
        let pick = ui.wheelPick
        ui.wheelOpen = false
        ui.wheelPick = nil
        padMenuWheel = false
        if activate, let i = pick, wheelAvailable(DriveWheelItem.allCases[i]) { wheelAction(DriveWheelItem.allCases[i]) }
    }

    private func run(_ fn: GamepadFunction) {
        if ui.wheelOpen {                                 // the wheel owns A / B while it is open
            if fn == .select { closePadWheel(activate: true); return }
            if fn == .estop { closePadWheel(activate: false); return }
        }
        guard layout.active else {
            if fn == .driveMode { enter() }
            else if fn == .controllerMode { setControllerMode(!ui.controllerMode, via: "gamepad") }
            return
        }
        switch fn {
        case .select: break
        case .estop: estop(via: "gamepad")
        case .viewNext: cycleView()
        case .takeOver: if ui.otherDriver != nil { takeOver() }
        case .prevBody: switchBody(-1)
        case .nextBody: switchBody(1)
        case .controllerMode: setControllerMode(!ui.controllerMode, via: "gamepad")
        case .menu:
            padMenuWheel.toggle()
            ui.wheelOpen = padMenuWheel
            if !padMenuWheel { ui.wheelPick = nil }
        case .driveMode: exit(why: "gamepad")
        case .turretCentre: centreTurret(via: "gamepad")
        case .pitchUp: stepTurret(yaw: 0, pitch: 10 * .pi / 180)
        case .pitchDown: stepTurret(yaw: 0, pitch: -10 * .pi / 180)
        case .yawLeft: stepTurret(yaw: 15 * .pi / 180, pitch: 0)
        case .yawRight: stepTurret(yaw: -15 * .pi / 180, pitch: 0)
        case .tank: toggleTank()
        case .follow: follow()
        case .wheel, .turbo: break                       // holds
        }
    }
}
