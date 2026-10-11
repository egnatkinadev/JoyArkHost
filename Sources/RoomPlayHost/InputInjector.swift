import AppKit
import ApplicationServices

/// All entry points are used on the main queue. This host injects keyboard/mouse
/// events; it does not advertise a virtual game controller to macOS games.
final class InputInjector {
    private var heldKeys = Set<CGKeyCode>()
    private var heldButtons = Set<Int>()
    private var bounds: CGRect = CGDisplayBounds(CGMainDisplayID())

    var isAvailable: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func selectDisplay(_ displayID: CGDirectDisplayID) { bounds = CGDisplayBounds(displayID) }

    func key(code: Int, pressed: Bool) {
        guard isAvailable, (0...127).contains(code) else { return }
        let key = CGKeyCode(code)
        if pressed { heldKeys.insert(key) } else { heldKeys.remove(key) }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: pressed) else { return }
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    func mouseMove(x: Double, y: Double) {
        guard isAvailable, x.isFinite, y.isFinite, abs(x) <= 4_096, abs(y) <= 4_096,
              let current = CGEvent(source: nil)?.location else { return }
        let event = Self.makeMoveEvent(current: current, x: x, y: y, bounds: bounds, heldButtons: heldButtons, flags: modifierFlags)
        event?.post(tap: .cghidEventTap)
    }

    func mouseButton(_ button: Int, pressed: Bool) {
        guard isAvailable, (0...2).contains(button), let location = CGEvent(source: nil)?.location else { return }
        if pressed { heldButtons.insert(button) } else { heldButtons.remove(button) }
        let type: CGEventType = button == 0 ? (pressed ? .leftMouseDown : .leftMouseUp) : button == 1 ? (pressed ? .rightMouseDown : .rightMouseUp) : (pressed ? .otherMouseDown : .otherMouseUp)
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button == 0 ? .left : button == 1 ? .right : .center)
        event?.flags = modifierFlags
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
    }

    func releaseAll() {
        for key in Array(heldKeys) { self.key(code: Int(key), pressed: false) }
        for button in Array(heldButtons) { mouseButton(button, pressed: false) }
        heldKeys.removeAll()
        heldButtons.removeAll()
    }

    /// Event construction is independently testable without Accessibility or
    /// posting events to other applications. Relative games read delta fields
    /// even when the visible pointer has reached the display edge.
    static func makeMoveEvent(current: CGPoint, x: Double, y: Double, bounds: CGRect,
                              heldButtons: Set<Int>, flags: CGEventFlags) -> CGEvent? {
        guard x.isFinite, y.isFinite, abs(x) <= 4_096, abs(y) <= 4_096 else { return nil }
        let location = CGPoint(x: min(max(current.x + x, bounds.minX), bounds.maxX - 1),
                               y: min(max(current.y + y, bounds.minY), bounds.maxY - 1))
        let type: CGEventType = heldButtons.contains(0) ? .leftMouseDragged : heldButtons.contains(1) ? .rightMouseDragged : heldButtons.contains(2) ? .otherMouseDragged : .mouseMoved
        let button: CGMouseButton = heldButtons.contains(1) ? .right : heldButtons.contains(2) ? .center : .left
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)
        event?.flags = flags
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(x.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(y.rounded()))
        return event
    }

    private var modifierFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if !heldKeys.isDisjoint(with: [55, 54]) { flags.insert(.maskCommand) }
        if !heldKeys.isDisjoint(with: [56, 60]) { flags.insert(.maskShift) }
        if !heldKeys.isDisjoint(with: [58, 61]) { flags.insert(.maskAlternate) }
        if !heldKeys.isDisjoint(with: [59, 62]) { flags.insert(.maskControl) }
        return flags
    }
}
