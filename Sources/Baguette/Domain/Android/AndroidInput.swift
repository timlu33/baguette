import Foundation

/// What `nav` can ask of a phone that a hardware button cannot.
enum NavigationAction: String, Sendable, Equatable, CaseIterable {
    case back, home, recents, notifications, settings, collapse, rotate, wake

    static let allowed = allCases.map(\.rawValue).joined(separator: " | ")
}

/// An Android phone's input surface. Everything `Input` already offers
/// (tap, swipe, touches, buttons, keys, scroll) plus the three things
/// iOS has no word for: a finger *by id*, the system navigation keys,
/// and text typed whole.
protocol AndroidInput: Input {
    /// One phase of finger `id`. Any number of ids may be down at once.
    func pointer(_ phase: GesturePhase, id: Int, at point: Point, size: Size, pressure: Double) -> Bool
    func navigate(_ action: NavigationAction) -> Bool
    /// Put `text` into the focused field — Unicode included.
    func enterText(_ text: String) -> Bool
}

/// `{ "type": "pointer-down|move|up", "id": 0, "x": …, "y": …, "width": …, "height": …, "pressure": 1 }`
/// One browser pointer, 1:1. Coordinates are in the units of `width` ×
/// `height` — the frame size the page decoded — like every other gesture.
struct PointerTouch: Gesture, Equatable {
    static let wireType = "pointer"

    let phase: GesturePhase
    let id: Int
    let at: Point
    let size: Size
    let pressure: Double

    static func parse(_ dict: [String: Any]) throws -> PointerTouch {
        guard let rawPhase = dict["phase"] as? String, let phase = GesturePhase(rawValue: rawPhase) else {
            throw GestureError.missingField("phase")
        }
        let id = Int(Field.optionalDouble(dict, "id", default: 0))
        guard id >= 0 else { throw GestureError.invalidValue("id", expected: "a non-negative integer") }
        return PointerTouch(
            phase: phase,
            id: id,
            at: try Field.requiredPoint(dict, "x", "y"),
            size: try Field.requiredSize(dict),
            pressure: Field.optionalDouble(dict, "pressure", default: phase == .up ? 0 : 1)
        )
    }

    func execute(on input: any Input) -> Bool {
        guard let android = input as? any AndroidInput else { return false }
        return android.pointer(phase, id: id, at: at, size: size, pressure: pressure)
    }
}

/// `{ "type": "nav", "action": "back" }`
struct Navigate: Gesture, Equatable {
    static let wireType = "nav"

    let action: NavigationAction

    static func parse(_ dict: [String: Any]) throws -> Navigate {
        let raw = try Field.requiredString(dict, "action")
        guard let action = NavigationAction(rawValue: raw) else {
            throw GestureError.invalidValue("action", expected: NavigationAction.allowed)
        }
        return Navigate(action: action)
    }

    func execute(on input: any Input) -> Bool {
        (input as? any AndroidInput)?.navigate(action) ?? false
    }
}

/// `{ "type": "text", "text": "你好" }`
struct EnterText: Gesture, Equatable {
    static let wireType = "text"

    let text: String

    static func parse(_ dict: [String: Any]) throws -> EnterText {
        EnterText(text: try Field.requiredString(dict, "text"))
    }

    func execute(on input: any Input) -> Bool {
        (input as? any AndroidInput)?.enterText(text) ?? false
    }
}

extension GestureRegistry {
    /// Everything iOS understands plus the Android-only gestures. Kept
    /// apart from `standard` so an iOS simulator never accepts `nav`.
    static var android: GestureRegistry {
        let registry = GestureRegistry.standard
        registry.registerPhased(PointerTouch.self)
        registry.register(Navigate.self)
        registry.register(EnterText.self)
        return registry
    }
}
