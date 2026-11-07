import Testing
import Foundation
@testable import Baguette

@Suite("ScrcpyControlMessage")
struct ScrcpyControlMessageTests {

    private let phone = Size(width: 100, height: 200)

    @Test func `should encode a finger landing as a 32-byte inject-touch message`() {
        let message = ScrcpyControlMessage.touch(
            .down, pointer: 0, at: Point(x: 10, y: 20), in: phone, pressure: 1
        )
        #expect([UInt8](message.bytes) == [
            2, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 10,
            0, 0, 0, 20,
            0, 100, 0, 200,
            0xFF, 0xFF,
            0, 0, 0, 0,
            0, 0, 0, 0,
        ])
    }

    @Test func `should carry the pointer id and the move and up actions on a touch`() {
        let move = ScrcpyControlMessage.touch(
            .move, pointer: 1, at: Point(x: 0, y: 0), in: phone, pressure: 1
        ).bytes
        let up = ScrcpyControlMessage.touch(
            .up, pointer: 1, at: Point(x: 0, y: 0), in: phone, pressure: 0
        ).bytes
        #expect(move[1] == 2)
        #expect(up[1] == 1)
        #expect(move[9] == 1)
        #expect(up[22] == 0 && up[23] == 0)
    }

    @Test func `should round a fractional touch position to the nearest pixel`() {
        let bytes = ScrcpyControlMessage.touch(
            .down, pointer: 0, at: Point(x: 10.6, y: 19.4), in: phone, pressure: 1
        ).bytes
        #expect([UInt8](bytes[10..<18]) == [0, 0, 0, 11, 0, 0, 0, 19])
    }

    @Test func `should clamp a touch outside the screen onto its edge`() {
        let bytes = ScrcpyControlMessage.touch(
            .move, pointer: 0, at: Point(x: -5, y: 900), in: phone, pressure: 1
        ).bytes
        #expect([UInt8](bytes[10..<18]) == [0, 0, 0, 0, 0, 0, 0, 199])
    }

    @Test func `should encode half pressure as a fixed-point fraction of 65536`() {
        let bytes = ScrcpyControlMessage.touch(
            .down, pointer: 0, at: Point(x: 1, y: 1), in: phone, pressure: 0.5
        ).bytes
        #expect(bytes[22] == 0x80 && bytes[23] == 0x00)
    }

    @Test func `should encode a key press as keycode action repeat and meta state`() {
        let message = ScrcpyControlMessage.keycode(.down, code: 66, metaState: 1)
        #expect([UInt8](message.bytes) == [
            0, 0,
            0, 0, 0, 66,
            0, 0, 0, 0,
            0, 0, 0, 1,
        ])
        #expect(ScrcpyControlMessage.keycode(.up, code: 4).bytes[1] == 1)
    }

    @Test func `should encode inject text as a length-prefixed UTF-8 string`() {
        let bytes = ScrcpyControlMessage.text("hi").bytes
        #expect([UInt8](bytes) == [1, 0, 0, 0, 2, 0x68, 0x69])
    }

    @Test func `should encode a clipboard paste with its flag and a byte length not a character count`() {
        let bytes = ScrcpyControlMessage.setClipboard(text: "你", paste: true).bytes
        #expect([UInt8](bytes) == [
            9,
            0, 0, 0, 0, 0, 0, 0, 0,
            1,
            0, 0, 0, 3,
            0xE4, 0xBD, 0xA0,
        ])
    }

    @Test func `should encode a scroll tick as position plus two signed fixed-point deltas`() {
        let bytes = ScrcpyControlMessage.scroll(
            at: Point(x: 50, y: 100), in: phone, horizontal: 0, vertical: 1
        ).bytes
        #expect([UInt8](bytes) == [
            3,
            0, 0, 0, 50,
            0, 0, 0, 100,
            0, 100, 0, 200,
            0, 0,
            0x08, 0x00,
            0, 0, 0, 0,
        ])
    }

    @Test func `should saturate a scroll delta at plus or minus sixteen`() {
        let up = ScrcpyControlMessage.scroll(
            at: Point(x: 0, y: 0), in: phone, horizontal: 0, vertical: 99
        ).bytes
        let down = ScrcpyControlMessage.scroll(
            at: Point(x: 0, y: 0), in: phone, horizontal: 0, vertical: -99
        ).bytes
        #expect(up[15] == 0x7F && up[16] == 0xFF)
        #expect(down[15] == 0x80 && down[16] == 0x00)
    }

    @Test func `should encode back-or-screen-on with the key action`() {
        #expect([UInt8](ScrcpyControlMessage.backOrScreenOn(.down).bytes) == [4, 0])
        #expect([UInt8](ScrcpyControlMessage.backOrScreenOn(.up).bytes) == [4, 1])
    }

    @Test func `should encode the argument-less commands as a single type byte`() {
        #expect([UInt8](ScrcpyControlMessage.expandNotificationPanel.bytes) == [5])
        #expect([UInt8](ScrcpyControlMessage.expandSettingsPanel.bytes) == [6])
        #expect([UInt8](ScrcpyControlMessage.collapsePanels.bytes) == [7])
        #expect([UInt8](ScrcpyControlMessage.rotateDevice.bytes) == [11])
        #expect([UInt8](ScrcpyControlMessage.resetVideo.bytes) == [17])
    }
}
