import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("AndroidFleet")
struct AndroidFleetTests {

    @Test func `should list the devices adb reports`() throws {
        let adb = MockAdb()
        given(adb).run(.value(["devices", "-l"]))
            .willReturn(Data("List of devices attached\nabc123 device model:Pixel_8 transport_id:1\n".utf8))
        let devices = try AndroidFleet(adb: adb).devices()
        #expect(devices.map(\.serial) == ["abc123"])
        #expect(devices.first?.name == "Pixel 8")
    }

    @Test func `should list nothing, without failing, when adb is not installed`() throws {
        #expect(try AndroidFleet(adb: nil).devices().isEmpty)
        #expect(AndroidFleet(adb: nil).unavailableReason != nil)
    }

    @Test func `should have no reason to give when adb is installed`() {
        #expect(AndroidFleet(adb: MockAdb()).unavailableReason == nil)
    }

    @Test func `should find a device by serial among the ones adb lists`() throws {
        let adb = MockAdb()
        given(adb).run(.any).willReturn(Data("List of devices attached\nabc device\nxyz offline\n".utf8))
        let fleet = AndroidFleet(adb: adb)
        #expect(try fleet.find(serial: "abc")?.isReady == true)
        #expect(try fleet.find(serial: "xyz")?.isReady == false)
        #expect(try fleet.find(serial: "nope") == nil)
    }

    @Test func `should take a screenshot through adb exec-out screencap`() throws {
        let adb = MockAdb()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        given(adb).run(.value(["-s", "abc", "exec-out", "screencap", "-p"])).willReturn(png)
        #expect(try AndroidFleet(adb: adb).screenshot(serial: "abc") == png)
    }

    @Test func `should refuse a screenshot when adb is not installed`() {
        #expect(throws: AndroidError.self) { _ = try AndroidFleet(adb: nil).screenshot(serial: "abc") }
    }

    @Test func `should refuse a screenshot that is not a PNG`() {
        let adb = MockAdb()
        given(adb).run(.any).willReturn(Data("error: closed".utf8))
        #expect(throws: AndroidError.self) { _ = try AndroidFleet(adb: adb).screenshot(serial: "abc") }
    }
}
