import Testing
import Foundation
import HTTPTypes
@testable import Baguette

/// The Android routes' decisions, judged without a socket: which HTTP
/// status each failure earns, which stream-control lines mean "send a
/// keyframe", and that the page the router serves ships with every
/// script it loads (a missing `<script>` is a blank page, not an error).
@Suite("Server Android routes")
struct AndroidRoutesTests {

    @Test func `should answer 503 when adb is not installed`() {
        #expect(Server.androidStatus(for: AndroidError.adbNotFound) == .serviceUnavailable)
    }

    @Test func `should answer 404 for a phone adb does not list`() {
        #expect(Server.androidStatus(for: AndroidError.unknownDevice("x")) == .notFound)
    }

    @Test func `should answer 409 for a phone that is not ready to stream`() {
        #expect(Server.androidStatus(for: AndroidError.deviceNotReady(serial: "x", state: "offline")) == .conflict)
    }

    @Test func `should answer 500 for any other failure`() {
        #expect(Server.androidStatus(for: AndroidError.startupFailed("boom")) == .internalServerError)
        #expect(Server.androidStatus(for: CocoaError(.fileNoSuchFile)) == .internalServerError)
    }

    @Test func `should treat force_idr and snapshot as a request for a keyframe`() {
        #expect(Server.androidControlKind(#"{"type":"force_idr"}"#) == "force_idr")
        #expect(Server.androidControlKind(#"{"type":"snapshot"}"#) == "snapshot")
    }

    @Test func `should leave every other line for the gesture dispatcher`() {
        #expect(Server.androidControlKind(#"{"type":"pointer-down","x":1,"y":1,"width":2,"height":2}"#) == nil)
        #expect(Server.androidControlKind(#"{"type":"set_bitrate","bitrate":1}"#) == nil)
        #expect(Server.androidControlKind("not json") == nil)
    }

    @Test func `should frame an error as a failed ack the page can show`() {
        #expect(Server.androidErrorFrame(#"adb said "no""#) == #"{"error":"adb said \"no\"","ok":false}"#)
    }

    @Test func `should ship the Android page with every script it loads`() throws {
        let web = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Baguette/Resources/Web")
        let html = try String(contentsOf: web.appendingPathComponent("android.html"), encoding: .utf8)
        let scripts = html.components(separatedBy: #"<script src=""#).dropFirst()
            .compactMap { $0.components(separatedBy: #"""#).first }
        #expect(scripts.contains("/android.js"))
        for script in scripts {
            #expect(
                FileManager.default.fileExists(atPath: web.appendingPathComponent(String(script.dropFirst())).path),
                "android.html loads \(script), which is not in Resources/Web"
            )
        }
    }

    @Test func `should ship the official scrcpy server jar beside its licence`() {
        let android = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Baguette/Resources/Android")
        #expect(FileManager.default.fileExists(atPath: android.appendingPathComponent(AndroidResources.serverJarName).path))
        #expect(FileManager.default.fileExists(atPath: android.appendingPathComponent("LICENSE-scrcpy").path))
    }
}
