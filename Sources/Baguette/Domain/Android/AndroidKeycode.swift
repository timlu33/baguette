import Foundation

/// `android.view.KeyEvent` codes for what baguette's gesture surface can
/// press. The browser already sends W3C `KeyboardEvent.code`, which
/// baguette parses into a HID usage; this maps that usage on to Android.
enum AndroidKeycode {
    static func from(_ key: KeyboardKey) -> Int32? {
        guard key.hidUsage.page == 7 else { return nil }
        let usage = key.hidUsage.usage
        switch usage {
        case 0x04...0x1D: return Int32(29 + usage - 0x04)          // KEYCODE_A…Z
        case 0x1E...0x26: return Int32(8 + usage - 0x1E)           // KEYCODE_1…9
        case 0x27:        return 7                                  // KEYCODE_0
        case 0x59...0x61: return Int32(145 + usage - 0x59)         // KEYCODE_NUMPAD_1…9
        case 0x62:        return 144                                // KEYCODE_NUMPAD_0
        default:          return named[usage]
        }
    }

    static func from(_ button: DeviceButton) -> Int32? {
        switch button {
        case .home, .swipeToHome:        return 3    // KEYCODE_HOME
        case .appSwitcher,
             .swipeToAppSwitcher:        return 187  // KEYCODE_APP_SWITCH
        case .power, .lock:              return 26   // KEYCODE_POWER
        case .volumeUp:                  return 24   // KEYCODE_VOLUME_UP
        case .volumeDown:                return 25   // KEYCODE_VOLUME_DOWN
        default:                         return nil
        }
    }

    /// `KeyEvent.META_*`: the generic bit plus the left-hand bit, which
    /// is what a physical left Shift/Ctrl/Alt/Meta reports.
    static func metaState(for modifiers: Set<KeyModifier>) -> Int32 {
        var state: Int32 = 0
        if modifiers.contains(.shift)   { state |= 0x1 | 0x40 }
        if modifiers.contains(.option)  { state |= 0x2 | 0x10 }
        if modifiers.contains(.control) { state |= 0x1000 | 0x2000 }
        if modifiers.contains(.command) { state |= 0x10000 | 0x20000 }
        return state
    }

    private static let named: [UInt32: Int32] = [
        0x28: 66,   // Enter       → KEYCODE_ENTER
        0x29: 111,  // Escape      → KEYCODE_ESCAPE
        0x2A: 67,   // Backspace   → KEYCODE_DEL
        0x2B: 61,   // Tab
        0x2C: 62,   // Space
        0x2D: 69,   // Minus
        0x2E: 70,   // Equal
        0x2F: 71,   // BracketLeft
        0x30: 72,   // BracketRight
        0x31: 73,   // Backslash
        0x33: 74,   // Semicolon
        0x34: 75,   // Quote → KEYCODE_APOSTROPHE
        0x35: 68,   // Backquote → KEYCODE_GRAVE
        0x36: 55,   // Comma
        0x37: 56,   // Period
        0x38: 76,   // Slash
        0x4F: 22,   // ArrowRight → KEYCODE_DPAD_RIGHT
        0x50: 21,   // ArrowLeft
        0x51: 20,   // ArrowDown
        0x52: 19,   // ArrowUp
        0x54: 154,  // NumpadDivide
        0x55: 155,  // NumpadMultiply
        0x56: 156,  // NumpadSubtract
        0x57: 157,  // NumpadAdd
        0x58: 160,  // NumpadEnter
        0x63: 158,  // NumpadDecimal
        0x67: 161,  // NumpadEqual
    ]
}
