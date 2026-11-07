import Foundation

/// One running scrcpy server on one device and the two sockets to it:
/// video (device → host) and control (host → device).
///
/// Start-up, in order — each step is the same thing the official
/// desktop client does:
///   1. `adb push` the server jar to the device,
///   2. `adb forward tcp:0 localabstract:scrcpy_<scid>`,
///   3. run the server (`app_process`) through `adb shell`,
///   4. connect the video socket and read the dummy byte that proves the
///      device is really listening (retrying while it boots),
///   5. connect the control socket,
///   6. wait for the device name + video size.
///
/// Integration-only: every decision with logic in it is a tested value
/// (`ScrcpyLaunch`, `ScrcpyVideoParser`, `AndroidScreen`, `ScrcpyInput`).
final class ScrcpySession: @unchecked Sendable {
    let serial: String
    let launch: ScrcpyLaunch
    let screen = AndroidScreen()
    let input: ScrcpyInput

    /// Fires once, on any thread, when the session is over for any reason.
    var onEnd: (@Sendable (String?) -> Void)?

    private let adb: any Adb
    private let jar: URL
    private let remoteJar: String
    private let wire = ControlWire()

    private let lock = NSLock()
    private var server: (any AdbProcess)?
    private var video: TCPConnection?
    private var forwardedPort: Int?
    private var stopped = false
    private var ended = false
    private var serverOutput = ""
    private var serverExited = false

    private static let startupTimeout: TimeInterval = 15

    init(serial: String, jar: URL, launch: ScrcpyLaunch, adb: any Adb) {
        self.serial = serial
        self.jar = jar
        self.launch = launch
        self.adb = adb
        self.remoteJar = "/data/local/tmp/baguette-scrcpy-\(launch.scidHex).jar"
        let wire = self.wire
        let screen = self.screen
        self.input = ScrcpyInput(
            screen: { screen.size },
            send: { wire.send($0) }
        )
        screen.onKeyframeNeeded = { _ = wire.send(.resetVideo) }
    }

    /// True from a successful `start()` until the stream ends.
    var isRunning: Bool { lock.withLock { !stopped && !ended && video != nil } }

    /// Ask the device encoder for a fresh keyframe (and description).
    func requestKeyframe() { _ = wire.send(.resetVideo) }

    /// Blocks until the first frame header arrives. Call off the
    /// cooperative pool. Throws `AndroidError`; the session cleans up
    /// after itself on failure.
    func start() throws {
        do {
            try boot()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let (alreadyStopped, port, process, videoSocket): (Bool, Int?, (any AdbProcess)?, TCPConnection?) =
            lock.withLock {
                defer { stopped = true }
                return (stopped, forwardedPort, server, video)
            }
        guard !alreadyStopped else { return }
        videoSocket?.close()
        wire.close()
        process?.terminate()
        // Housekeeping off-thread: removing the forward and the jar
        // costs two adb round trips nobody should wait for.
        let adb = self.adb, serial = self.serial, remoteJar = self.remoteJar
        DispatchQueue.global(qos: .utility).async {
            if let port { _ = try? adb.run(["-s", serial, "forward", "--remove", "tcp:\(port)"]) }
            _ = try? adb.run(["-s", serial, "shell", "rm", "-f", remoteJar])
        }
        finish(reason: nil)
    }

    // MARK: start-up

    private func boot() throws {
        guard FileManager.default.fileExists(atPath: jar.path) else { throw AndroidError.serverJarMissing }

        _ = try adb.run(["-s", serial, "push", jar.path, remoteJar])

        let forward = try adb.run(["-s", serial, "forward", "tcp:0", "localabstract:\(launch.socketName)"])
        guard let port = ScrcpyLaunch.port(fromForwardOutput: String(decoding: forward, as: UTF8.self)) else {
            throw AndroidError.startupFailed("adb forward gave no port")
        }
        lock.withLock { forwardedPort = port }

        let process = try adb.spawn(
            ["-s", serial, "shell"] + launch.shellCommand(jar: remoteJar),
            onOutput: { [weak self] data in self?.collect(data) },
            onExit: { [weak self] _ in self?.serverDidExit() }
        )
        lock.withLock { server = process }

        let videoSocket = try connectVideo(port: port)
        lock.withLock { video = videoSocket }
        let controlSocket = try connectControl(port: port)
        wire.attach(controlSocket)

        let ready = DispatchSemaphore(value: 0)
        let readyFlag = ReadyFlag()
        startVideoReader(videoSocket) {
            if readyFlag.fire() { ready.signal() }
        }
        startControlDrain(controlSocket)

        if ready.wait(timeout: .now() + Self.startupTimeout) == .timedOut {
            throw AndroidError.startupFailed("no video from the device within \(Int(Self.startupTimeout)) s\(outputSuffix())")
        }
        if lock.withLock({ stopped }) {
            throw AndroidError.startupFailed("the stream ended during start-up\(outputSuffix())")
        }
    }

    /// `adb forward` accepts connections before the device is
    /// listening, so a refused or empty connection is retried until the
    /// dummy byte arrives (as scrcpy's own client does).
    private func connectVideo(port: Int) throws -> TCPConnection {
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            if lock.withLock({ serverExited }) {
                throw AndroidError.startupFailed("the server exited immediately\(outputSuffix())")
            }
            if let socket = try? TCPConnection.connect(port: port) {
                // adb accepts the connection before the device does; a
                // device that never answers must not hang start-up.
                socket.setReceiveTimeout(1)
                if let dummy = socket.readExactly(1), dummy.count == 1 {
                    socket.setReceiveTimeout(0)
                    return socket
                }
                socket.close()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AndroidError.startupFailed("the server never started listening\(outputSuffix())")
    }

    private func connectControl(port: Int) throws -> TCPConnection {
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error = AndroidError.startupFailed("control socket refused")
        while Date() < deadline {
            do { return try TCPConnection.connect(port: port) } catch { lastError = error }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw lastError
    }

    // MARK: pumps

    private func startVideoReader(_ socket: TCPConnection, onReady: @escaping @Sendable () -> Void) {
        let screen = self.screen
        let thread = Thread { [weak self] in
            // The dummy byte was consumed while connecting.
            var parser = ScrcpyVideoParser(expectsDummyByte: false)
            var failure: String?
            reading: while let chunk = socket.read(maxBytes: 256 * 1024) {
                for event in parser.push(chunk) {
                    if case .failure(let message) = event { failure = message; break reading }
                    screen.ingest(event)
                    if case .video = event { onReady() }
                }
            }
            onReady() // unblock start() if the stream died before any frame
            self?.finish(reason: failure)
            self?.stop()
        }
        thread.name = "baguette.scrcpy.video.\(serial)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The device writes clipboard and ack messages back on the control
    /// socket; nothing here uses them, but an unread socket would
    /// eventually stall the server.
    private func startControlDrain(_ socket: TCPConnection) {
        let thread = Thread { [weak self] in
            while socket.read(maxBytes: 4096) != nil {}
            self?.stop()
        }
        thread.name = "baguette.scrcpy.control.\(serial)"
        thread.start()
    }

    // MARK: server output

    private func collect(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            serverOutput += text
            if serverOutput.count > 4096 { serverOutput = String(serverOutput.suffix(4096)) }
        }
    }

    private func serverDidExit() {
        lock.withLock { serverExited = true }
        stop()
    }

    private func outputSuffix() -> String {
        let tail = lock.withLock { serverOutput }.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "" : " — device said: \(tail.suffix(600))"
    }

    private func finish(reason: String?) {
        let callback: (@Sendable (String?) -> Void)? = lock.withLock {
            guard !ended else { return nil }
            ended = true
            return onEnd
        }
        callback?(reason)
    }

    // MARK: helpers

    /// The control socket as a thread-safe sink the input script writes to.
    private final class ControlWire: @unchecked Sendable {
        private let lock = NSLock()
        private var socket: TCPConnection?
        private var closed = false

        func attach(_ socket: TCPConnection) {
            lock.withLock {
                if closed { socket.close() } else { self.socket = socket }
            }
        }

        func send(_ message: ScrcpyControlMessage) -> Bool {
            // One writer at a time keeps messages whole on the wire.
            lock.lock()
            defer { lock.unlock() }
            guard let socket, !closed else { return false }
            return socket.write(message.bytes)
        }

        func close() {
            let socket: TCPConnection? = lock.withLock {
                closed = true
                defer { self.socket = nil }
                return self.socket
            }
            socket?.close()
        }
    }

    private final class ReadyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
    }
}
