import Testing
import Foundation
import Mockable
@testable import Baguette

/// An Android input surface that writes down what it was asked to do,
/// so gestures can be judged by the state they leave behind.
final class RecordingAndroidInput: AndroidInput, @unchecked Sendable {
    private(set) var log: [String] = []

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool { log.append("tap"); return true }
    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool { log.append("swipe"); return true }
    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool { log.append("touch1"); return true }
    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool { log.append("touch2"); return true }
    func button(_ button: DeviceButton, duration: Double) -> Bool { log.append("button"); return true }
    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool { log.append("key"); return true }
    func scroll(deltaX: Double, deltaY: Double) -> Bool { log.append("scroll"); return true }
    func twoFingerPath(start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double) -> Bool {
        log.append("twoFingerPath"); return true
    }
    func pointer(_ phase: GesturePhase, id: Int, at point: Point, size: Size, pressure: Double) -> Bool {
        log.append("pointer \(phase.rawValue) #\(id) (\(point.x),\(point.y)) in \(size.width)x\(size.height) p=\(pressure)")
        return true
    }
    func navigate(_ action: NavigationAction) -> Bool { log.append("navigate \(action.rawValue)"); return true }
    func enterText(_ text: String) -> Bool { log.append("text \(text)"); return true }
}

@Suite("Android gestures")
struct AndroidGestureTests {

    private func run(_ json: String, on input: any Input) throws -> Bool {
        let dict = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        return try GestureRegistry.android.parse(dict).execute(on: input)
    }

    @Test func `should land a finger by id with the pressure the page sent`() throws {
        let input = RecordingAndroidInput()
        let ok = try run(#"{"type":"pointer-down","id":1,"x":10,"y":20,"width":100,"height":200,"pressure":0.5}"#, on: input)
        #expect(ok)
        #expect(input.log == ["pointer down #1 (10.0,20.0) in 100.0x200.0 p=0.5"])
    }

    @Test func `should land finger zero at full pressure when the page names neither`() throws {
        let input = RecordingAndroidInput()
        _ = try run(#"{"type":"pointer-move","x":1,"y":2,"width":3,"height":4}"#, on: input)
        #expect(input.log == ["pointer move #0 (1.0,2.0) in 3.0x4.0 p=1.0"])
    }

    @Test func `should lift a finger at zero pressure unless told otherwise`() throws {
        let input = RecordingAndroidInput()
        _ = try run(#"{"type":"pointer-up","id":2,"x":1,"y":2,"width":3,"height":4}"#, on: input)
        #expect(input.log == ["pointer up #2 (1.0,2.0) in 3.0x4.0 p=0.0"])
    }

    @Test func `should refuse a pointer gesture without a screen size`() {
        #expect(throws: GestureError.self) {
            _ = try GestureRegistry.android.parse(["type": "pointer-down", "x": 1, "y": 2])
        }
    }

    @Test func `should press a system navigation key by name`() throws {
        let input = RecordingAndroidInput()
        #expect(try run(#"{"type":"nav","action":"back"}"#, on: input))
        #expect(try run(#"{"type":"nav","action":"recents"}"#, on: input))
        #expect(input.log == ["navigate back", "navigate recents"])
    }

    @Test func `should refuse a navigation action Android does not know`() {
        #expect(throws: GestureError.self) {
            _ = try GestureRegistry.android.parse(["type": "nav", "action": "teleport"])
        }
    }

    @Test func `should hand typed text to the device whole`() throws {
        let input = RecordingAndroidInput()
        #expect(try run(#"{"type":"text","text":"你好 hello"}"#, on: input))
        #expect(input.log == ["text 你好 hello"])
    }

    @Test func `should still understand the shared tap swipe and button gestures`() throws {
        let input = RecordingAndroidInput()
        _ = try run(#"{"type":"tap","x":1,"y":2,"width":3,"height":4}"#, on: input)
        _ = try run(#"{"type":"button","button":"home"}"#, on: input)
        #expect(input.log == ["tap", "button"])
    }

    @Test func `should do nothing when the input surface is not an Android device`() throws {
        let ios = MockInput()
        #expect(try run(#"{"type":"nav","action":"home"}"#, on: ios) == false)
        #expect(try run(#"{"type":"pointer-down","x":1,"y":2,"width":3,"height":4}"#, on: ios) == false)
    }

    @Test func `should keep the iOS registry free of Android only gestures`() {
        #expect(throws: GestureError.self) {
            _ = try GestureRegistry.standard.parse(["type": "nav", "action": "home"])
        }
    }
}
