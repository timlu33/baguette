import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("AndroidSessions")
struct AndroidSessionsTests {

    private let fixtures = ScrcpySessionTests()

    private func sessions(adb: FakeAdb, jar: URL?) -> AndroidSessions {
        AndroidSessions(fleet: AndroidFleet(adb: adb), jar: { jar })
    }

    @Test func `should share one running server between two viewers of the same phone`() throws {
        let server = try FakeScrcpyServer(script: fixtures.script)
        let adb = FakeAdb(forwardPort: server.port)
        let sessions = sessions(adb: adb, jar: try fixtures.jar())
        let first = try sessions.acquire(serial: "abc", options: .init())
        let second = try sessions.acquire(serial: "abc", options: .init())
        defer { sessions.stopAll() }
        #expect(first === second)
        #expect(adb.log.filter { $0.contains("app_process") }.count == 1)
    }

    @Test func `should start a fresh server when asked to restart with new options`() throws {
        let server = try FakeScrcpyServer(script: fixtures.script)
        let adb = FakeAdb(forwardPort: server.port)
        let sessions = sessions(adb: adb, jar: try fixtures.jar())
        let first = try sessions.acquire(serial: "abc", options: .init())
        defer { sessions.stopAll() }
        let second = try sessions.acquire(serial: "abc", options: .init(maxSize: 800), restart: true)
        #expect(first !== second)
        #expect(adb.log.filter { $0.contains("app_process") }.count == 2)
        #expect(adb.log.last { $0.contains("app_process") }?.contains("max_size=800") == true)
    }

    @Test func `should refuse a phone adb does not list`() throws {
        let sessions = sessions(adb: FakeAdb(forwardPort: 1), jar: try fixtures.jar())
        #expect(throws: AndroidError.unknownDevice("ghost")) {
            _ = try sessions.acquire(serial: "ghost", options: .init())
        }
    }

    @Test func `should refuse a phone that has not authorised this Mac`() throws {
        let adb = FakeAdb(forwardPort: 1)
        adb.deviceListing = "List of devices attached\nabc unauthorized\n"
        let sessions = sessions(adb: adb, jar: try fixtures.jar())
        #expect(throws: AndroidError.deviceNotReady(serial: "abc", state: "unauthorized")) {
            _ = try sessions.acquire(serial: "abc", options: .init())
        }
    }

    @Test func `should say adb is missing rather than that the phone is`() {
        let sessions = AndroidSessions(fleet: AndroidFleet(adb: nil), jar: { nil })
        #expect(throws: AndroidError.adbNotFound) {
            _ = try sessions.acquire(serial: "abc", options: .init())
        }
    }

    @Test func `should say the server jar is missing when it is not shipped`() {
        let sessions = sessions(adb: FakeAdb(forwardPort: 1), jar: nil)
        #expect(throws: AndroidError.serverJarMissing) {
            _ = try sessions.acquire(serial: "abc", options: .init())
        }
    }

    @Test func `should read stream options from the query string`() {
        let query = ["maxSize": "1024", "bitrate": "4000000", "fps": "30"]
        let options = AndroidSessions.Options(query: { query[$0] })
        #expect(options == AndroidSessions.Options(maxSize: 1024, bitRate: 4_000_000, maxFps: 30))
    }

    @Test func `should default every stream option the query leaves out`() {
        #expect(AndroidSessions.Options(query: { _ in nil }) == AndroidSessions.Options())
    }

    @Test func `should keep stream options inside what the device encoder can do`() {
        let wild = ["maxSize": "999999", "bitrate": "1", "fps": "9000"]
        let options = AndroidSessions.Options(query: { wild[$0] })
        #expect(options.maxSize == 4096)
        #expect(options.bitRate == 500_000)
        #expect(options.maxFps == 120)
    }

    @Test func `should let zero mean native resolution`() {
        let options = AndroidSessions.Options(query: { $0 == "maxSize" ? "0" : nil })
        #expect(options.maxSize == 0)
    }

    @Test func `should ignore a stream option that is not a number`() {
        let options = AndroidSessions.Options(query: { $0 == "fps" ? "fast" : nil })
        #expect(options.maxFps == AndroidSessions.Options().maxFps)
    }
}
