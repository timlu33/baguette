import Foundation

/// Why an Android operation could not be done, in words fit to show the user.
enum AndroidError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case adbNotFound
    case adbFailed(String)
    case unknownDevice(String)
    case deviceNotReady(serial: String, state: String)
    case serverJarMissing
    case startupFailed(String)
    case notAScreenshot

    var description: String {
        switch self {
        case .adbNotFound:
            return "adb was not found. Install Android platform-tools (brew install android-platform-tools) or set BAGUETTE_ADB to the adb path."
        case .adbFailed(let detail):
            return "adb failed: \(detail)"
        case .unknownDevice(let serial):
            return "no Android device \(serial) — check `adb devices`"
        case .deviceNotReady(let serial, let state):
            return state == "unauthorized"
                ? "\(serial) is unauthorized — unlock the phone and accept the USB debugging prompt"
                : "\(serial) is \(state), not ready to stream"
        case .serverJarMissing:
            return "the bundled scrcpy server (Resources/Android/scrcpy-server-v\(ScrcpyLaunch.serverVersion)) is missing — rebuild baguette"
        case .startupFailed(let detail):
            return "could not start the scrcpy server on the device: \(detail)"
        case .notAScreenshot:
            return "the device did not return a PNG screenshot"
        }
    }

    var errorDescription: String? { description }
}
