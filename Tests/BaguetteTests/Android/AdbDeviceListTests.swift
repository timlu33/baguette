import Testing
import Foundation
@testable import Baguette

@Suite("AdbDeviceList")
struct AdbDeviceListTests {

    private let output = """
    * daemon not running; starting now at tcp:5037
    * daemon started successfully
    List of devices attached
    emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
    R5CT1234ABC            device usb:1-1 product:b0qxxx model:SM_S908B device:b0q transport_id:2
    0123456789             unauthorized usb:1-2 transport_id:3
    192.168.1.9:5555       offline transport_id:4

    """

    @Test func `should list every device adb reports and skip daemon chatter`() {
        let devices = AdbDeviceList.parse(output)
        #expect(devices.map(\.serial) == ["emulator-5554", "R5CT1234ABC", "0123456789", "192.168.1.9:5555"])
    }

    @Test func `should read the state of each device`() {
        let states = AdbDeviceList.parse(output).map(\.state)
        #expect(states == [.device, .device, .unauthorized, .offline])
    }

    @Test func `should name a device after its model with spaces for underscores`() {
        let devices = AdbDeviceList.parse(output)
        #expect(devices[1].model == "SM_S908B")
        #expect(devices[1].name == "SM S908B")
    }

    @Test func `should fall back to the serial as a name when adb reports no model`() {
        let devices = AdbDeviceList.parse(output)
        #expect(devices[2].name == "0123456789")
    }

    @Test func `should call only a ready device streamable`() {
        let ready = AdbDeviceList.parse(output).map(\.isReady)
        #expect(ready == [true, true, false, false])
    }

    @Test func `should list nothing when adb prints only the header`() {
        #expect(AdbDeviceList.parse("List of devices attached\n\n") == [])
    }

    @Test func `should project connected devices as sorted-key JSON`() {
        let json = AdbDeviceList.json(AdbDeviceList.parse(output).prefix(1).map { $0 })
        #expect(json == #"{"connected":[{"model":"sdk_gphone64_arm64","name":"sdk gphone64 arm64","ready":true,"serial":"emulator-5554","state":"device"}]}"#)
    }

    @Test func `should carry the reason adb is unavailable beside an empty device list`() {
        let json = AdbDeviceList.json([], unavailable: "adb was not found")
        #expect(json == #"{"connected":[],"unavailable":"adb was not found"}"#)
    }
}
