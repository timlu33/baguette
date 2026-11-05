import Foundation

/// One message on scrcpy's control socket, host → device. The server
/// (v3.3) reads them with `ControlMessageReader`; this is the matching
/// writer, as a pure value so the byte layout can be pinned by tests.
///
/// Every integer is big-endian. A touch is a finger *by id*: scrcpy
/// folds consecutive DOWN/MOVE/UP messages with different ids into one
/// multi-touch `MotionEvent`, so two fingers are just two ids.
enum ScrcpyControlMessage: Equatable, Sendable {
    /// `KeyEvent.ACTION_DOWN` / `ACTION_UP`.
    enum KeyAction: UInt8, Sendable { case down = 0, up = 1 }
    /// `MotionEvent.ACTION_DOWN` / `ACTION_UP` / `ACTION_MOVE`.
    enum TouchAction: UInt8, Sendable { case down = 0, up = 1, move = 2 }

    case keycode(KeyAction, code: Int32, repeatCount: Int32 = 0, metaState: Int32 = 0)
    case text(String)
    case touch(TouchAction, pointer: Int64, at: Point, in: Size, pressure: Double)
    case scroll(at: Point, in: Size, horizontal: Double, vertical: Double)
    case backOrScreenOn(KeyAction)
    case expandNotificationPanel
    case expandSettingsPanel
    case collapsePanels
    case rotateDevice
    case setClipboard(text: String, paste: Bool)
    case resetVideo

    var bytes: Data {
        var out = Data()
        switch self {
        case .keycode(let action, let code, let repeatCount, let metaState):
            out.append(0)
            out.append(action.rawValue)
            out.append(int32: code)
            out.append(int32: repeatCount)
            out.append(int32: metaState)

        case .text(let text):
            out.append(1)
            let utf8 = Data(text.utf8)
            out.append(int32: Int32(utf8.count))
            out.append(utf8)

        case .touch(let action, let pointer, let point, let size, let pressure):
            out.append(2)
            out.append(action.rawValue)
            out.append(int64: pointer)
            out.appendPosition(point, size)
            out.append(uint16: Self.unsignedFixedPoint(pressure))
            out.append(int32: 0) // action button
            out.append(int32: 0) // buttons

        case .scroll(let point, let size, let horizontal, let vertical):
            out.append(3)
            out.appendPosition(point, size)
            out.append(uint16: UInt16(bitPattern: Self.signedFixedPoint(horizontal / 16)))
            out.append(uint16: UInt16(bitPattern: Self.signedFixedPoint(vertical / 16)))
            out.append(int32: 0) // buttons

        case .backOrScreenOn(let action):
            out.append(4)
            out.append(action.rawValue)

        case .expandNotificationPanel: out.append(5)
        case .expandSettingsPanel:     out.append(6)
        case .collapsePanels:          out.append(7)

        case .setClipboard(let text, let paste):
            out.append(9)
            out.append(int64: 0) // sequence: 0 asks for no acknowledgement
            out.append(paste ? 1 : 0)
            let utf8 = Data(text.utf8)
            out.append(int32: Int32(utf8.count))
            out.append(utf8)

        case .rotateDevice: out.append(11)
        case .resetVideo:   out.append(17)
        }
        return out
    }

    /// `Binary.u16FixedPointToFloat` inverted: 1.0 is the full-scale 0xFFFF.
    private static func unsignedFixedPoint(_ value: Double) -> UInt16 {
        if value >= 1 { return 0xFFFF }
        if value <= 0 { return 0 }
        return UInt16(value * 65536)
    }

    /// `Binary.i16FixedPointToFloat` inverted over [-1, 1].
    private static func signedFixedPoint(_ value: Double) -> Int16 {
        if value >= 1 { return 0x7FFF }
        if value <= -1 { return Int16.min }
        return Int16(value * 32768)
    }
}

private extension Data {
    mutating func append(int32 value: Int32) {
        let v = UInt32(bitPattern: value)
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    mutating func append(int64 value: Int64) {
        let v = UInt64(bitPattern: value)
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((v >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// x, y, then the screen size they are relative to. scrcpy drops an
    /// event whose size disagrees with the live video size, so the size
    /// is part of the message rather than something the host remembers.
    mutating func appendPosition(_ point: Point, _ size: Size) {
        let width = Int(Swift.max(1, Swift.min(size.width.rounded(), 65535)))
        let height = Int(Swift.max(1, Swift.min(size.height.rounded(), 65535)))
        let x = Int32(Swift.max(0, Swift.min(point.x.rounded(), Double(width - 1))))
        let y = Int32(Swift.max(0, Swift.min(point.y.rounded(), Double(height - 1))))
        append(int32: x)
        append(int32: y)
        append(uint16: UInt16(width))
        append(uint16: UInt16(height))
    }
}
