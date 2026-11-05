import Foundation

/// The scrcpy sessions currently running, one per device, shared by
/// every browser watching that device. The first viewer starts it, the
/// last one's departure stops it — after a short grace period, so a page
/// reload doesn't pay the second-or-two server start-up twice.
final class AndroidSessions: @unchecked Sendable {
    /// How long an unwatched session lingers before it is torn down.
    static let idleGrace: TimeInterval = 5

    struct Options: Equatable, Sendable {
        var maxSize = 1600
        var bitRate = 8_000_000
        var maxFps = 60

        init(maxSize: Int = 1600, bitRate: Int = 8_000_000, maxFps: Int = 60) {
            self.maxSize = maxSize
            self.bitRate = bitRate
            self.maxFps = maxFps
        }

        /// `?maxSize=&bitrate=&fps=`, each clamped to what a phone's
        /// hardware encoder will accept. `maxSize=0` keeps the native size.
        init(query: (String) -> String?) {
            func number(_ key: String) -> Int? { query(key).flatMap { Int($0) } }
            self.init()
            if let size = number("maxSize") { maxSize = size == 0 ? 0 : Swift.max(240, Swift.min(size, 4096)) }
            if let rate = number("bitrate") { bitRate = Swift.max(500_000, Swift.min(rate, 40_000_000)) }
            if let fps = number("fps") { maxFps = Swift.max(1, Swift.min(fps, 120)) }
        }
    }

    private struct Entry {
        let session: ScrcpySession
        let options: Options
        var viewers: Int
        var generation: Int
    }

    private let fleet: AndroidFleet
    private let jar: @Sendable () -> URL?
    private let lock = NSLock()
    /// Serialises start-ups: two browsers opening the same phone at the
    /// same moment must end up sharing one server, not racing two.
    private let startGate = NSLock()
    private var entries: [String: Entry] = [:]
    private var nextScid: UInt32 = UInt32.random(in: 1...0x7FFF_FFFF)

    init(fleet: AndroidFleet, jar: @escaping @Sendable () -> URL? = { AndroidResources.serverJar }) {
        self.fleet = fleet
        self.jar = jar
    }

    /// The device's session with a viewer counted against it, starting
    /// one if none runs. `restart` replaces a running session so new
    /// options take effect. Blocks while the server starts.
    func acquire(serial: String, options: Options, restart: Bool = false) throws -> ScrcpySession {
        startGate.lock()
        defer { startGate.unlock() }

        if restart, let old = lock.withLock({ entries.removeValue(forKey: serial) }) {
            old.session.stop()
        }
        if let existing: ScrcpySession = lock.withLock({
            guard var entry = entries[serial] else { return nil }
            entry.viewers += 1
            entry.generation += 1
            entries[serial] = entry
            return entry.session
        }) {
            return existing
        }

        guard let adb = fleet.adb else { throw AndroidError.adbNotFound }
        guard let device = try fleet.find(serial: serial) else { throw AndroidError.unknownDevice(serial) }
        guard device.isReady else { throw AndroidError.deviceNotReady(serial: serial, state: device.state.wire) }
        guard let jar = jar() else { throw AndroidError.serverJarMissing }

        let scid: UInt32 = lock.withLock {
            defer { nextScid = nextScid >= 0x7FFF_FFFF ? 1 : nextScid + 1 }
            return nextScid
        }
        let session = ScrcpySession(
            serial: serial,
            jar: jar,
            launch: ScrcpyLaunch(scid: scid, maxSize: options.maxSize, bitRate: options.bitRate, maxFps: options.maxFps),
            adb: adb
        )
        session.onEnd = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.lock.withLock {
                if self.entries[serial]?.session === session { self.entries[serial] = nil }
            }
        }
        try session.start()
        lock.withLock { entries[serial] = Entry(session: session, options: options, viewers: 1, generation: 0) }
        log("[android] streaming \(serial) (scid \(session.launch.scidHex))")
        return session
    }

    /// Return a viewer. The session stops once nobody has held it for
    /// `idleGrace` seconds.
    func release(serial: String, session: ScrcpySession) {
        let generation: Int? = lock.withLock {
            guard var entry = entries[serial], entry.session === session else { return nil }
            entry.viewers = max(0, entry.viewers - 1)
            entry.generation += 1
            entries[serial] = entry
            return entry.viewers == 0 ? entry.generation : nil
        }
        guard let generation else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.idleGrace) { [weak self] in
            guard let self else { return }
            let expired: ScrcpySession? = self.lock.withLock {
                guard let entry = self.entries[serial], entry.session === session,
                      entry.viewers == 0, entry.generation == generation else { return nil }
                self.entries[serial] = nil
                return entry.session
            }
            if let expired {
                log("[android] idle, stopping \(serial)")
                expired.stop()
            }
        }
    }

    /// Stop everything — on server shutdown.
    func stopAll() {
        let all = lock.withLock { () -> [ScrcpySession] in
            defer { entries.removeAll() }
            return entries.values.map(\.session)
        }
        all.forEach { $0.stop() }
    }
}
