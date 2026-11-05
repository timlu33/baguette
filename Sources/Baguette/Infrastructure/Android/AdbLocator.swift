import Foundation

/// Finds the `adb` executable. baguette does not bundle platform-tools
/// (Google's licence and size make that the user's install), so it looks
/// where Android developers keep it, most deliberate choice first.
enum AdbLocator {
    static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let explicit = environment["BAGUETTE_ADB"], !explicit.isEmpty { candidates.append(explicit) }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environment[key], !sdk.isEmpty { candidates.append("\(sdk)/platform-tools/adb") }
        }
        candidates.append("\(home)/Library/Android/sdk/platform-tools/adb") // Android Studio on macOS
        candidates.append("/opt/homebrew/bin/adb")                          // Homebrew, Apple silicon
        candidates.append("/usr/local/bin/adb")                             // Homebrew, Intel
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(directory)/adb")
        }
        return candidates.first(where: exists)
    }
}
