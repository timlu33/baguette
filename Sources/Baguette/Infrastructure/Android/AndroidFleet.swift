import Foundation

/// The Android devices reachable through adb. A thin facade: what to
/// ask adb and how to read the answer, with `Adb` doing the spawning.
/// `adb` is `nil` when no executable was found — the fleet then reports
/// nothing and says why, so the UI can show an install hint instead of
/// an empty, unexplained list.
final class AndroidFleet: @unchecked Sendable {
    let adb: (any Adb)?

    init(adb: (any Adb)?) {
        self.adb = adb
    }

    /// The production fleet: adb wherever `AdbLocator` finds it.
    static func discover() -> AndroidFleet {
        AndroidFleet(adb: AdbLocator.find().map { HostAdb(executable: $0) })
    }

    var unavailableReason: String? {
        adb == nil ? AndroidError.adbNotFound.description : nil
    }

    func devices() throws -> [AndroidDevice] {
        guard let adb else { return [] }
        return AdbDeviceList.parse(String(decoding: try adb.run(["devices", "-l"]), as: UTF8.self))
    }

    func find(serial: String) throws -> AndroidDevice? {
        try devices().first { $0.serial == serial }
    }

    /// One PNG of the device's screen, straight from `screencap`.
    func screenshot(serial: String) throws -> Data {
        guard let adb else { throw AndroidError.adbNotFound }
        let png = try adb.run(["-s", serial, "exec-out", "screencap", "-p"])
        guard png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { throw AndroidError.notAScreenshot }
        return png
    }
}
