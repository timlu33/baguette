import Testing
import Foundation
@testable import Baguette

@Suite("AdbLocator")
struct AdbLocatorTests {

    private func locate(
        env: [String: String] = [:],
        existing: Set<String>,
        home: String = "/Users/me"
    ) -> String? {
        AdbLocator.find(environment: env, home: home, exists: { existing.contains($0) })
    }

    @Test func `should prefer the path named by BAGUETTE_ADB`() {
        let found = locate(
            env: ["BAGUETTE_ADB": "/custom/adb", "ANDROID_HOME": "/sdk"],
            existing: ["/custom/adb", "/sdk/platform-tools/adb"]
        )
        #expect(found == "/custom/adb")
    }

    @Test func `should look inside ANDROID_HOME then ANDROID_SDK_ROOT`() {
        #expect(locate(env: ["ANDROID_HOME": "/sdk"], existing: ["/sdk/platform-tools/adb"]) == "/sdk/platform-tools/adb")
        #expect(locate(env: ["ANDROID_SDK_ROOT": "/root"], existing: ["/root/platform-tools/adb"]) == "/root/platform-tools/adb")
    }

    @Test func `should find the Android Studio default install under the home folder`() {
        let path = "/Users/me/Library/Android/sdk/platform-tools/adb"
        #expect(locate(existing: [path]) == path)
    }

    @Test func `should find a Homebrew adb`() {
        #expect(locate(existing: ["/opt/homebrew/bin/adb"]) == "/opt/homebrew/bin/adb")
        #expect(locate(existing: ["/usr/local/bin/adb"]) == "/usr/local/bin/adb")
    }

    @Test func `should search PATH last`() {
        let found = locate(env: ["PATH": "/a:/b"], existing: ["/b/adb"])
        #expect(found == "/b/adb")
    }

    @Test func `should find nothing when adb is not installed`() {
        #expect(locate(existing: []) == nil)
    }

    @Test func `should ignore a BAGUETTE_ADB that points at nothing`() {
        let found = locate(env: ["BAGUETTE_ADB": "/missing/adb"], existing: ["/opt/homebrew/bin/adb"])
        #expect(found == "/opt/homebrew/bin/adb")
    }
}
