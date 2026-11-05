import Testing
import Foundation
@testable import Baguette

@Suite("ScrcpyInput")
struct ScrcpyInputTests {

    private final class Wire: @unchecked Sendable {
        var sent: [ScrcpyControlMessage] = []
        var pauses: [Double] = []
        var accepting = true
    }

    private let phone = Size(width: 100, height: 200)

    private func make(_ wire: Wire) -> ScrcpyInput {
        ScrcpyInput(
            screen: { Size(width: 100, height: 200) },
            send: { wire.sent.append($0); return wire.accepting },
            pause: { wire.pauses.append($0) }
        )
    }

    @Test func `should land a tap as a finger down then up at the same spot`() {
        let wire = Wire()
        let ok = make(wire).tap(at: Point(x: 10, y: 20), size: phone, duration: 0, edge: nil)
        #expect(ok)
        #expect(wire.sent == [
            .touch(.down, pointer: 0, at: Point(x: 10, y: 20), in: phone, pressure: 1),
            .touch(.up, pointer: 0, at: Point(x: 10, y: 20), in: phone, pressure: 0),
        ])
    }

    @Test func `should hold a tap for the requested time and a short default otherwise`() {
        let wire = Wire()
        let input = make(wire)
        _ = input.tap(at: Point(x: 1, y: 1), size: phone, duration: 0.4, edge: nil)
        _ = input.tap(at: Point(x: 1, y: 1), size: phone, duration: 0, edge: nil)
        #expect(wire.pauses == [0.4, ScrcpyInput.defaultTapHold])
    }

    @Test func `should report failure when the control socket refuses the touch`() {
        let wire = Wire()
        wire.accepting = false
        #expect(make(wire).tap(at: Point(x: 1, y: 1), size: phone, duration: 0, edge: nil) == false)
    }

    @Test func `should drag a swipe through intermediate moves and lift at the end`() {
        let wire = Wire()
        _ = make(wire).swipe(from: Point(x: 0, y: 100), to: Point(x: 80, y: 100), size: phone, duration: 0.2)
        #expect(wire.sent.first == .touch(.down, pointer: 0, at: Point(x: 0, y: 100), in: phone, pressure: 1))
        #expect(wire.sent.last == .touch(.up, pointer: 0, at: Point(x: 80, y: 100), in: phone, pressure: 0))
        let moves = wire.sent.compactMap { message -> Double? in
            if case .touch(.move, _, let p, _, _) = message { return p.x }
            return nil
        }
        #expect(moves.count >= 2)
        #expect(moves == moves.sorted())
        #expect(moves.last == 80)
    }

    @Test func `should forward a streamed touch one phase at a time on finger zero`() {
        let wire = Wire()
        let input = make(wire)
        _ = input.touch1(phase: .down, at: Point(x: 5, y: 6), size: phone, edge: nil)
        _ = input.touch1(phase: .move, at: Point(x: 7, y: 8), size: phone, edge: nil)
        _ = input.touch1(phase: .up, at: Point(x: 7, y: 8), size: phone, edge: nil)
        #expect(wire.sent == [
            .touch(.down, pointer: 0, at: Point(x: 5, y: 6), in: phone, pressure: 1),
            .touch(.move, pointer: 0, at: Point(x: 7, y: 8), in: phone, pressure: 1),
            .touch(.up, pointer: 0, at: Point(x: 7, y: 8), in: phone, pressure: 0),
        ])
    }

    @Test func `should drive two fingers as pointers zero and one`() {
        let wire = Wire()
        _ = make(wire).touch2(phase: .down, first: Point(x: 1, y: 1), second: Point(x: 9, y: 9), size: phone)
        #expect(wire.sent == [
            .touch(.down, pointer: 0, at: Point(x: 1, y: 1), in: phone, pressure: 1),
            .touch(.down, pointer: 1, at: Point(x: 9, y: 9), in: phone, pressure: 1),
        ])
    }

    @Test func `should bring both fingers along a two finger path and lift them together`() {
        let wire = Wire()
        _ = make(wire).twoFingerPath(
            start1: Point(x: 40, y: 100), end1: Point(x: 10, y: 100),
            start2: Point(x: 60, y: 100), end2: Point(x: 90, y: 100),
            size: phone, duration: 0.2
        )
        #expect(wire.sent.prefix(2) == [
            .touch(.down, pointer: 0, at: Point(x: 40, y: 100), in: phone, pressure: 1),
            .touch(.down, pointer: 1, at: Point(x: 60, y: 100), in: phone, pressure: 1),
        ][...])
        #expect(wire.sent.suffix(2) == [
            .touch(.up, pointer: 0, at: Point(x: 10, y: 100), in: phone, pressure: 0),
            .touch(.up, pointer: 1, at: Point(x: 90, y: 100), in: phone, pressure: 0),
        ][...])
    }

    @Test func `should land a pointer by id with its pressure`() {
        let wire = Wire()
        _ = make(wire).pointer(.down, id: 3, at: Point(x: 4, y: 5), size: phone, pressure: 0.7)
        #expect(wire.sent == [.touch(.down, pointer: 3, at: Point(x: 4, y: 5), in: phone, pressure: 0.7)])
    }

    @Test func `should press home as a keycode down then up`() {
        let wire = Wire()
        #expect(make(wire).button(.home, duration: 0))
        #expect(wire.sent == [.keycode(.down, code: 3), .keycode(.up, code: 3)])
    }

    @Test func `should hold a long press between the key down and up`() {
        let wire = Wire()
        _ = make(wire).button(.power, duration: 1.5)
        #expect(wire.pauses == [1.5])
    }

    @Test func `should pull the notification shade down with the panel command`() {
        let wire = Wire()
        #expect(make(wire).button(.pullDownToNotificationCenter, duration: 0))
        #expect(wire.sent == [.expandNotificationPanel])
    }

    @Test func `should refuse a button the phone does not have`() {
        let wire = Wire()
        #expect(make(wire).button(.digitalCrown, duration: 0) == false)
        #expect(wire.sent.isEmpty)
    }

    @Test func `should press a keyboard key with its modifiers folded into meta state`() throws {
        let wire = Wire()
        let a = try #require(KeyboardKey.from(wireCode: "KeyA"))
        #expect(make(wire).key(a, modifiers: [.shift], duration: 0))
        #expect(wire.sent == [
            .keycode(.down, code: 29, metaState: 0x41),
            .keycode(.up, code: 29, metaState: 0x41),
        ])
    }

    @Test func `should scroll at the middle of the screen with the wheel direction flipped`() {
        let wire = Wire()
        #expect(make(wire).scroll(deltaX: 50, deltaY: 100))
        #expect(wire.sent == [
            .scroll(at: Point(x: 50, y: 100), in: phone, horizontal: 1, vertical: -2),
        ])
    }

    @Test func `should map each navigation action onto its Android command`() {
        let wire = Wire()
        let input = make(wire)
        for action in [NavigationAction.back, .home, .recents, .notifications, .settings, .collapse, .rotate, .wake] {
            #expect(input.navigate(action))
        }
        #expect(wire.sent == [
            .backOrScreenOn(.down), .backOrScreenOn(.up),
            .keycode(.down, code: 3), .keycode(.up, code: 3),
            .keycode(.down, code: 187), .keycode(.up, code: 187),
            .expandNotificationPanel, .expandSettingsPanel, .collapsePanels, .rotateDevice,
            .keycode(.down, code: 224), .keycode(.up, code: 224),
        ])
    }

    @Test func `should type short ASCII text as key events and anything else through the clipboard`() {
        let wire = Wire()
        let input = make(wire)
        #expect(input.enterText("hello"))
        #expect(input.enterText("你好"))
        #expect(wire.sent == [
            .text("hello"),
            .setClipboard(text: "你好", paste: true),
        ])
    }

    @Test func `should not type an empty string`() {
        let wire = Wire()
        #expect(make(wire).enterText("") == false)
        #expect(wire.sent.isEmpty)
    }
}
