import AppKit
import GameController
import HubCore

/// Feeds ``ControllerBridge`` from macOS's GameController framework for as long as MacGameHub runs.
///
/// Games are frontmost while they run, so background events have to be enabled explicitly or
/// GameController would stop delivering input the moment a game takes focus.
@MainActor
final class ControllerBridgeService {
    private let bridge: ControllerBridge
    private var slots: [ObjectIdentifier: Int] = [:]
    private var heartbeat: Timer?
    private var observers: [NSObjectProtocol] = []

    init(fileURL: URL) {
        bridge = ControllerBridge(fileURL: fileURL)
    }

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.detach(controller) }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bridge.disconnectAll() }
        })
        GCController.controllers().forEach(attach)
        bridge.disconnectAll() // fresh file, then the controllers above fill it on their first input
        GCController.controllers().forEach { publish($0) }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.bridge.beat() }
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad, slots[ObjectIdentifier(controller)] == nil else { return }
        let used = Set(slots.values)
        guard let slot = (0..<ControllerBridge.slotCount).first(where: { !used.contains($0) }) else { return }
        slots[ObjectIdentifier(controller)] = slot
        controller.playerIndex = GCControllerPlayerIndex(rawValue: slot) ?? .indexUnset
        pad.valueChangedHandler = { [weak self, weak controller] _, _ in
            guard let controller else { return }
            MainActor.assumeIsolated { self?.publish(controller) }
        }
        publish(controller)
    }

    private func detach(_ controller: GCController) {
        guard let slot = slots.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        bridge.update(slot: slot, pad: nil)
    }

    private func publish(_ controller: GCController) {
        guard let slot = slots[ObjectIdentifier(controller)], let gamepad = controller.extendedGamepad else { return }
        bridge.update(slot: slot, pad: Self.pad(from: gamepad))
    }

    static func pad(from g: GCExtendedGamepad) -> BridgePad {
        var pad = BridgePad()
        let buttons: [(GCControllerButtonInput?, UInt16)] = [
            (g.buttonA, BridgePad.a), (g.buttonB, BridgePad.b), (g.buttonX, BridgePad.x), (g.buttonY, BridgePad.y),
            (g.leftShoulder, BridgePad.leftShoulder), (g.rightShoulder, BridgePad.rightShoulder),
            (g.buttonMenu, BridgePad.start), (g.buttonOptions, BridgePad.back), (g.buttonHome, BridgePad.guide),
            (g.leftThumbstickButton, BridgePad.leftThumb), (g.rightThumbstickButton, BridgePad.rightThumb),
            (g.dpad.up, BridgePad.dpadUp), (g.dpad.down, BridgePad.dpadDown),
            (g.dpad.left, BridgePad.dpadLeft), (g.dpad.right, BridgePad.dpadRight),
        ]
        for (button, bit) in buttons where button?.isPressed == true { pad.buttons |= bit }
        pad.leftTrigger = BridgePad.trigger(g.leftTrigger.value)
        pad.rightTrigger = BridgePad.trigger(g.rightTrigger.value)
        // GameController and XInput agree: up and right are positive.
        pad.leftX = BridgePad.axis(g.leftThumbstick.xAxis.value)
        pad.leftY = BridgePad.axis(g.leftThumbstick.yAxis.value)
        pad.rightX = BridgePad.axis(g.rightThumbstick.xAxis.value)
        pad.rightY = BridgePad.axis(g.rightThumbstick.yAxis.value)
        return pad
    }
}
