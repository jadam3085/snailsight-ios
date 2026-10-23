// SnailSight 12.7 gamepad glue: GameController framework (GCController / GCExtendedGamepad; the owner's GameSir G8
// Galileo, any MFi / Xbox / DualSense pad) read into SnailSightCore's standard-layout GamepadFrame. Event driven
// (valueChangedHandler on the main queue): no polling loop; DriveController routes each frame through GamepadRouter.
import GameController
import SnailSightCore

final class GamepadInput {
    var onFrame: ((GamepadFrame) -> Void)?
    var onConnect: ((String?, Bool) -> Void)?
    private(set) var name: String?
    private weak var current: GCController?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            guard let self, let c = n.object as? GCController, c === self.current else { return }
            self.current = nil
            let was = self.name
            self.name = nil
            self.onConnect?(was, false)
            if let other = GCController.controllers().first(where: { $0.extendedGamepad != nil }) { self.attach(other) }
        })
        GCController.shouldMonitorBackgroundEvents = false
        if let c = GCController.controllers().first(where: { $0.extendedGamepad != nil }) { attach(c) }
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad, c !== current else { return }
        current = c
        c.handlerQueue = .main
        name = c.vendorName ?? c.productCategory
        pad.valueChangedHandler = { [weak self] p, _ in self?.onFrame?(GamepadInput.read(p)) }
        onConnect?(name, true)
    }

    /// The standard (W3C) layout the HUD and SnailSightCore use. GameController sticks are already y-up.
    static func read(_ p: GCExtendedGamepad) -> GamepadFrame {
        var down = Set<GamepadButton>()
        func b(_ x: GCControllerButtonInput?, _ k: GamepadButton) { if x?.isPressed == true { down.insert(k) } }
        b(p.buttonA, .a); b(p.buttonB, .b); b(p.buttonX, .x); b(p.buttonY, .y)
        b(p.leftShoulder, .l1); b(p.rightShoulder, .r1)
        b(p.buttonOptions, .select); b(p.buttonMenu, .start); b(p.buttonHome, .home)
        b(p.leftThumbstickButton, .l3); b(p.rightThumbstickButton, .r3)
        b(p.dpad.up, .dUp); b(p.dpad.down, .dDown); b(p.dpad.left, .dLeft); b(p.dpad.right, .dRight)
        return GamepadFrame(left: V2(Double(p.leftThumbstick.xAxis.value), Double(p.leftThumbstick.yAxis.value)),
                            right: V2(Double(p.rightThumbstick.xAxis.value), Double(p.rightThumbstick.yAxis.value)),
                            pressed: down, l2: Double(p.leftTrigger.value), r2: Double(p.rightTrigger.value))
    }
}
