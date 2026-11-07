import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import Baguette

/// Plays the device's side of scrcpy's tunnel on loopback: accepts the
/// video connection first, then the control one, exactly as the real
/// server does behind `adb forward`.
final class FakeScrcpyServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var received = Data()
    private var control: Int32 = -1

    init(script: @escaping @Sendable () -> Data) throws {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw AndroidError.adbFailed("fake server bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))

        let thread = Thread { [self] in
            // One video + control pair per session, in order, until the
            // listener is closed.
            while true {
                let video = accept(listener, nil, nil)
                if video < 0 { break }
                let payload = script()
                payload.withUnsafeBytes { _ = send(video, $0.baseAddress, payload.count, 0) }
                let controlFD = accept(listener, nil, nil)
                if controlFD < 0 { break }
                lock.withLock { control = controlFD; received = Data() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = recv(controlFD, &buffer, buffer.count, 0)
                    if n <= 0 { break }
                    lock.withLock { received.append(contentsOf: buffer[0..<n]) }
                }
            }
        }
        thread.start()
    }

    var controlBytes: Data { lock.withLock { received } }

    func waitForControlBytes(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if controlBytes.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    deinit { _ = close(listener) }
}

final class FakeAdb: Adb, @unchecked Sendable {
    let forwardPort: Int
    private let lock = NSLock()
    private var calls: [[String]] = []
    var serverExitsImmediately = false
    var deviceListing = "List of devices attached\nabc device model:Pixel_8\n"

    init(forwardPort: Int) { self.forwardPort = forwardPort }

    var log: [[String]] { lock.withLock { calls } }

    func run(_ arguments: [String]) throws -> Data {
        lock.withLock { calls.append(arguments) }
        if arguments == ["devices", "-l"] { return Data(deviceListing.utf8) }
        if arguments.contains("forward"), !arguments.contains("--remove") {
            return Data("\(forwardPort)\n".utf8)
        }
        return Data()
    }

    func spawn(
        _ arguments: [String],
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any AdbProcess {
        lock.withLock { calls.append(arguments) }
        if serverExitsImmediately {
            onOutput(Data("Exception in thread main: version mismatch".utf8))
            onExit(1)
        }
        return FakeProcess()
    }
}

final class FakeProcess: AdbProcess, @unchecked Sendable {
    func terminate() {}
}

@Suite("ScrcpySession")
struct ScrcpySessionTests {

    func script() -> Data {
        var data = Data([0])                                   // dummy byte
        var name = Data("Pixel".utf8); name.append(Data(repeating: 0, count: 59))
        data.append(name)
        data.append(contentsOf: [0x68, 0x32, 0x36, 0x34, 0, 0, 0x02, 0xD0, 0, 0, 0x05, 0x00]) // h264 720×1280
        func packet(_ flags: UInt64, _ payload: [UInt8]) -> Data {
            var p = Data()
            for shift in stride(from: 56, through: 0, by: -8) { p.append(UInt8((flags >> UInt64(shift)) & 0xFF)) }
            p.append(contentsOf: [0, 0, 0, UInt8(payload.count)])
            p.append(contentsOf: payload)
            return p
        }
        data.append(packet(1 << 63, [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1F, 0xAC, 0, 0, 0, 1, 0x68, 0xEE, 0x3C, 0x80]))
        data.append(packet(1 << 62, [0, 0, 0, 1, 0x65, 9, 9]))
        data.append(packet(0, [0, 0, 0, 1, 0x41, 9]))
        return data
    }

    func jar() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-scrcpy-\(UUID().uuidString).jar")
        try Data([1]).write(to: url)
        return url
    }

    @Test func `should start the server, connect both sockets and stream frames to a viewer`() throws {
        let server = try FakeScrcpyServer(script: script)
        let adb = FakeAdb(forwardPort: server.port)
        let session = ScrcpySession(serial: "abc", jar: try jar(), launch: ScrcpyLaunch(scid: 0xAB), adb: adb)
        final class Tags: @unchecked Sendable {
            let lock = NSLock(); var values: [UInt8] = []
            func add(_ chunk: Data) { lock.withLock { if let t = AVCCEnvelope.unwrap(chunk)?.tag { values.append(t) } } }
        }
        let tags = Tags()
        session.screen.attach(id: UUID()) { tags.add($0) }

        try session.start()
        defer { session.stop() }

        #expect(session.screen.size == Size(width: 720, height: 1280))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, tags.lock.withLock({ tags.values.count }) < 3 { Thread.sleep(forTimeInterval: 0.01) }
        #expect(tags.lock.withLock { tags.values } == [
            AVCCEnvelope.descriptionTag, AVCCEnvelope.keyframeTag, AVCCEnvelope.deltaTag,
        ])
    }

    @Test func `should push the jar, forward the abstract socket and run the server through app_process`() throws {
        let server = try FakeScrcpyServer(script: script)
        let adb = FakeAdb(forwardPort: server.port)
        let session = ScrcpySession(serial: "abc", jar: try jar(), launch: ScrcpyLaunch(scid: 0xAB), adb: adb)
        try session.start()
        defer { session.stop() }

        let log = adb.log
        #expect(log[0].prefix(3) == ["-s", "abc", "push"])
        #expect(log[1] == ["-s", "abc", "forward", "tcp:0", "localabstract:scrcpy_000000ab"])
        let shell = try #require(log.first { $0.contains("app_process") })
        #expect(shell.prefix(3) == ["-s", "abc", "shell"])
        #expect(shell.contains("com.genymobile.scrcpy.Server"))
        #expect(shell.contains("scid=000000ab"))
    }

    @Test func `should write input to the device as control messages`() throws {
        let server = try FakeScrcpyServer(script: script)
        let session = ScrcpySession(
            serial: "abc", jar: try jar(), launch: ScrcpyLaunch(scid: 1), adb: FakeAdb(forwardPort: server.port)
        )
        try session.start()
        defer { session.stop() }

        #expect(session.input.pointer(.down, id: 0, at: Point(x: 10, y: 20), size: Size(width: 720, height: 1280), pressure: 1))
        #expect(server.waitForControlBytes(32))
        let bytes = [UInt8](server.controlBytes.prefix(32))
        #expect(bytes[0] == 2 && bytes[1] == 0)                          // inject touch, down
        #expect(Array(bytes[10..<18]) == [0, 0, 0, 10, 0, 0, 0, 20])     // x, y
        #expect(Array(bytes[18..<22]) == [0x02, 0xD0, 0x05, 0x00])       // 720 × 1280
    }

    @Test func `should ask the device for a keyframe when a viewer joins`() throws {
        let server = try FakeScrcpyServer(script: script)
        let session = ScrcpySession(
            serial: "abc", jar: try jar(), launch: ScrcpyLaunch(scid: 1), adb: FakeAdb(forwardPort: server.port)
        )
        try session.start()
        defer { session.stop() }
        session.screen.attach(id: UUID()) { _ in }
        #expect(server.waitForControlBytes(1))
        #expect(server.controlBytes.first == 17)                          // RESET_VIDEO
    }

    @Test func `should fail start-up with the device's own words when the server dies`() throws {
        let server = try FakeScrcpyServer(script: script)
        let adb = FakeAdb(forwardPort: server.port)
        adb.serverExitsImmediately = true
        let session = ScrcpySession(serial: "abc", jar: try jar(), launch: ScrcpyLaunch(scid: 1), adb: adb)
        do {
            try session.start()
            Issue.record("start should have thrown")
        } catch let error as AndroidError {
            #expect(error.description.contains("version mismatch"))
        }
    }

    @Test func `should refuse to start without the server jar`() {
        let session = ScrcpySession(
            serial: "abc", jar: URL(fileURLWithPath: "/nonexistent.jar"),
            launch: ScrcpyLaunch(scid: 1), adb: FakeAdb(forwardPort: 1)
        )
        #expect(throws: AndroidError.serverJarMissing) { try session.start() }
    }

    @Test func `should report the end of the session once`() throws {
        let server = try FakeScrcpyServer(script: script)
        let session = ScrcpySession(
            serial: "abc", jar: try jar(), launch: ScrcpyLaunch(scid: 1), adb: FakeAdb(forwardPort: server.port)
        )
        final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0 }
        let ended = Count()
        session.onEnd = { _ in ended.lock.withLock { ended.n += 1 } }
        try session.start()
        session.stop()
        session.stop()
        #expect(ended.lock.withLock { ended.n } == 1)
    }
}
