import Testing
import Foundation
@testable import Baguette

@Suite("AndroidKeycode")
struct AndroidKeycodeTests {

    private func key(_ code: String) -> KeyboardKey { KeyboardKey.from(wireCode: code)! }

    @Test func `should map letters digits and named keys onto Android keycodes`() {
        #expect(AndroidKeycode.from(key("KeyA")) == 29)
        #expect(AndroidKeycode.from(key("KeyZ")) == 54)
        #expect(AndroidKeycode.from(key("Digit0")) == 7)
        #expect(AndroidKeycode.from(key("Digit1")) == 8)
        #expect(AndroidKeycode.from(key("Digit9")) == 16)
        #expect(AndroidKeycode.from(key("Enter")) == 66)
        #expect(AndroidKeycode.from(key("Escape")) == 111)
        #expect(AndroidKeycode.from(key("Backspace")) == 67)
        #expect(AndroidKeycode.from(key("Tab")) == 61)
        #expect(AndroidKeycode.from(key("Space")) == 62)
    }

    @Test func `should map arrows and punctuation`() {
        #expect(AndroidKeycode.from(key("ArrowUp")) == 19)
        #expect(AndroidKeycode.from(key("ArrowDown")) == 20)
        #expect(AndroidKeycode.from(key("ArrowLeft")) == 21)
        #expect(AndroidKeycode.from(key("ArrowRight")) == 22)
        #expect(AndroidKeycode.from(key("Comma")) == 55)
        #expect(AndroidKeycode.from(key("Period")) == 56)
        #expect(AndroidKeycode.from(key("Minus")) == 69)
        #expect(AndroidKeycode.from(key("Slash")) == 76)
    }

    @Test func `should map the numeric keypad`() {
        #expect(AndroidKeycode.from(key("Numpad0")) == 144)
        #expect(AndroidKeycode.from(key("Numpad9")) == 153)
        #expect(AndroidKeycode.from(key("NumpadEnter")) == 160)
    }

    @Test func `should map a hardware button onto the key Android listens for`() {
        #expect(AndroidKeycode.from(.home) == 3)
        #expect(AndroidKeycode.from(.appSwitcher) == 187)
        #expect(AndroidKeycode.from(.power) == 26)
        #expect(AndroidKeycode.from(.lock) == 26)
        #expect(AndroidKeycode.from(.volumeUp) == 24)
        #expect(AndroidKeycode.from(.volumeDown) == 25)
    }

    @Test func `should have no keycode for a button Android does not have`() {
        #expect(AndroidKeycode.from(.digitalCrown) == nil)
        #expect(AndroidKeycode.from(.action) == nil)
    }

    @Test func `should fold held modifiers into one meta state`() {
        #expect(AndroidKeycode.metaState(for: []) == 0)
        #expect(AndroidKeycode.metaState(for: [.shift]) == 0x41)
        #expect(AndroidKeycode.metaState(for: [.shift, .control]) == 0x41 | 0x3000)
        #expect(AndroidKeycode.metaState(for: [.option]) == 0x12)
        #expect(AndroidKeycode.metaState(for: [.command]) == 0x30000)
    }
}
