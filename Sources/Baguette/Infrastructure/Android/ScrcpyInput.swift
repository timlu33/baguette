import Foundation

/// The Android phone's input surface, spoken in scrcpy control messages.
///
/// Every verb is a short script of `ScrcpyControlMessage`s handed to
/// `send` (the control socket in production, a recorder in tests), with
/// `pause` between them for the holds and drags that take time. Blocking
/// on `pause` is deliberate: gestures arrive on one serial consumer, so
/// a swipe finishes before the next envelope starts.
final class ScrcpyInput: AndroidInput, @unchecked Sendable {
    static let defaultTapHold = 0.05
    private static let frameInterval = 0.016
    private static let maxSteps = 60
    /// Points of wheel travel that make one Android scroll notch.
    private static let pointsPerNotch = 50.0
    private static let maxInjectedTextBytes = 300

    private let screen: @Sendable () -> Size
    private let send: @Sendable (ScrcpyControlMessage) -> Bool
    private let pause: @Sendable (Double) -> Void

    /// - Parameters:
    ///   - screen: the live video size — the scroll notch lands on its middle.
    ///   - send: write one control message; `false` when the socket is gone.
    ///   - pause: sleep for the given seconds.
    init(
        screen: @escaping @Sendable () -> Size,
        send: @escaping @Sendable (ScrcpyControlMessage) -> Bool,
        pause: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.screen = screen
        self.send = send
        self.pause = pause
    }

    // MARK: Input

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        guard touch(.down, 0, point, size) else { return false }
        pause(duration > 0 ? duration : Self.defaultTapHold)
        return touch(.up, 0, point, size)
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        let total = max(duration, Self.defaultTapHold)
        let steps = Self.steps(for: total)
        guard touch(.down, 0, start, size) else { return false }
        for step in 1...steps {
            pause(total / Double(steps))
            guard touch(.move, 0, Self.lerp(start, end, Double(step) / Double(steps)), size) else { return false }
        }
        return touch(.up, 0, end, size)
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        touch(Self.action(phase), 0, point, size)
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        touch(Self.action(phase), 0, first, size) && touch(Self.action(phase), 1, second, size)
    }

    func twoFingerPath(
        start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double
    ) -> Bool {
        let total = max(duration, Self.defaultTapHold)
        let steps = Self.steps(for: total)
        guard touch(.down, 0, start1, size), touch(.down, 1, start2, size) else { return false }
        for step in 1...steps {
            pause(total / Double(steps))
            let t = Double(step) / Double(steps)
            guard touch(.move, 0, Self.lerp(start1, end1, t), size),
                  touch(.move, 1, Self.lerp(start2, end2, t), size) else { return false }
        }
        return touch(.up, 0, end1, size) && touch(.up, 1, end2, size)
    }

    func button(_ button: DeviceButton, duration: Double) -> Bool {
        if button == .pullDownToNotificationCenter {
            return send(.expandNotificationPanel)
        }
        guard let code = AndroidKeycode.from(button) else { return false }
        return pressKey(code, meta: 0, hold: duration)
    }

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        guard let code = AndroidKeycode.from(key) else { return false }
        return pressKey(code, meta: AndroidKeycode.metaState(for: modifiers), hold: duration)
    }

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        let size = screen()
        guard size.width > 0, size.height > 0 else { return false }
        return send(.scroll(
            at: Point(x: size.width / 2, y: size.height / 2),
            in: size,
            // Browser wheel: +Y is down. Android AXIS_VSCROLL: + is up.
            horizontal: deltaX / Self.pointsPerNotch,
            vertical: -deltaY / Self.pointsPerNotch
        ))
    }

    // MARK: AndroidInput

    func pointer(_ phase: GesturePhase, id: Int, at point: Point, size: Size, pressure: Double) -> Bool {
        send(.touch(Self.action(phase), pointer: Int64(id), at: point, in: size, pressure: pressure))
    }

    func navigate(_ action: NavigationAction) -> Bool {
        switch action {
        case .back:          return send(.backOrScreenOn(.down)) && send(.backOrScreenOn(.up))
        case .home:          return pressKey(3, meta: 0, hold: 0)
        case .recents:       return pressKey(187, meta: 0, hold: 0)
        case .notifications: return send(.expandNotificationPanel)
        case .settings:      return send(.expandSettingsPanel)
        case .collapse:      return send(.collapsePanels)
        case .rotate:        return send(.rotateDevice)
        case .wake:          return pressKey(224, meta: 0, hold: 0)
        }
    }

    func enterText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // Injected key events only carry what the keymap can type; the
        // clipboard route carries anything, at the cost of clobbering
        // the device clipboard — so it is the fallback, not the default.
        if text.allSatisfy(\.isASCII), text.utf8.count <= Self.maxInjectedTextBytes {
            return send(.text(text))
        }
        return send(.setClipboard(text: text, paste: true))
    }

    // MARK: helpers

    private func touch(
        _ action: ScrcpyControlMessage.TouchAction, _ pointer: Int64, _ point: Point, _ size: Size
    ) -> Bool {
        send(.touch(action, pointer: pointer, at: point, in: size, pressure: action == .up ? 0 : 1))
    }

    private func pressKey(_ code: Int32, meta: Int32, hold: Double) -> Bool {
        guard send(.keycode(.down, code: code, metaState: meta)) else { return false }
        if hold > 0 { pause(hold) }
        return send(.keycode(.up, code: code, metaState: meta))
    }

    private static func action(_ phase: GesturePhase) -> ScrcpyControlMessage.TouchAction {
        switch phase {
        case .down: return .down
        case .move: return .move
        case .up:   return .up
        }
    }

    private static func steps(for duration: Double) -> Int {
        max(2, min(maxSteps, Int(duration / frameInterval)))
    }

    private static func lerp(_ a: Point, _ b: Point, _ t: Double) -> Point {
        Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
