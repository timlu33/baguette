import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Android routes — the `/android` sibling of the `/simulators` and
/// `/devices` trees. A phone is addressed by its adb serial.
///
/// ```text
/// GET  /android.json                    → adb devices (+ why none, if adb is missing)
/// GET  /android/:udid                   → the Android page (android.html)
/// GET  /android/:udid/screenshot.png    → one frame via `adb exec-out screencap`
/// POST /android/:udid/input             → one gesture envelope → its ack
/// WS   /android/:udid/stream            → AVCC video down, gestures up
///        ?maxSize=1600&bitrate=8000000&fps=60   (only when this opens the session)
///        &restart=1                              (replace a running session)
/// ```
///
/// `:udid` is the adb serial, URL-encoded (`192.168.1.9:5555` carries a
/// colon). The name stays `:udid` so `Server.udidParam` — the one
/// positional rule every route obeys — reads it unchanged.
///
/// The video is the device's own H.264, passed through un-decoded: the
/// scrcpy server encodes on the phone, `AndroidScreen` re-wraps it as
/// the AVCC envelope `frame-decoder.js` already plays, and nothing on
/// the Mac decodes or re-encodes it. Gestures use the same wire as the
/// simulator's (`wire.md`), plus `pointer-*`, `nav` and `text`.
extension Server {
    func registerAndroidRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?,
        trustedWebSocketUpgrade: @escaping @Sendable (Request, BasicWebSocketRequestContext)
            async throws -> RouterShouldUpgrade
    ) {
        let fleet = self.androidFleet
        let sessions = self.androidSessions

        router.get("/android.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            do {
                let devices = try await Self.offLoop { try fleet.devices() }
                return Self.androidJSONText(AdbDeviceList.json(devices, unavailable: fleet.unavailableReason))
            } catch {
                // adb itself failed (daemon wedged, timeout): say so, but keep the shape.
                return Self.androidJSONText(AdbDeviceList.json([], unavailable: "\(error)"))
            }
        }

        // The page: same pattern as `/simulators/:udid` → sim.html.
        router.get("/android/:udid") { _, _ in Self.staticAsset("android.html") }

        router.get("/android/:udid/screenshot.png") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let serial = Self.udidParam(r)
            guard !serial.isEmpty else {
                return Self.androidError("missing device serial", status: .badRequest)
            }
            do {
                let png = try await Self.offLoop { try fleet.screenshot(serial: serial) }
                return Response(
                    status: .ok,
                    headers: [.contentType: "image/png", .cacheControl: "no-cache"],
                    body: .init(byteBuffer: ByteBuffer(data: png))
                )
            } catch {
                return Self.androidError(error, status: Self.androidStatus(for: error))
            }
        }

        router.post("/android/:udid/input") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let serial = Self.udidParam(r)
            guard !serial.isEmpty else {
                return Self.androidError("missing device serial", status: .badRequest)
            }
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let body = buffer.map { String(buffer: $0) } ?? ""
            do {
                let session = try await Self.offLoop {
                    try sessions.acquire(serial: serial, options: AndroidSessions.Options())
                }
                defer { sessions.release(serial: serial, session: session) }
                let ack = await Self.androidDispatch(line: body, on: session)
                return Self.androidJSONText(ack)
            } catch {
                return Self.androidError(error, status: Self.androidStatus(for: error))
            }
        }

        router.ws(
            "/android/:udid/stream",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            let query = context.request.uri.queryParameters
            let options = AndroidSessions.Options(query: { key in query.get(key).map { String($0) } })
            let restart = query.get("restart").map { String($0) == "1" } ?? false
            await Self.androidStreamWS(
                serial: Self.udidParam(context.request),
                options: options,
                restart: restart,
                sessions: sessions,
                inbound: inbound,
                outbound: outbound
            )
        }
    }

    // MARK: - stream socket

    private static func androidStreamWS(
        serial: String,
        options: AndroidSessions.Options,
        restart: Bool,
        sessions: AndroidSessions,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !serial.isEmpty else {
            try? await outbound.write(.text(androidErrorFrame("missing device serial")))
            return
        }

        let session: ScrcpySession
        do {
            session = try await offLoop { try sessions.acquire(serial: serial, options: options, restart: restart) }
        } catch {
            try? await outbound.write(.text(androidErrorFrame("\(error)")))
            return
        }

        let sink = WebSocketFrameSink(outbound: outbound, format: .avcc)
        let viewer = UUID()
        session.screen.attach(id: viewer) { sink.write($0) }
        defer {
            session.screen.detach(id: viewer)
            sessions.release(serial: serial, session: session)
        }

        // The phone unplugged, or the server died: end the socket so
        // the page can say so rather than freeze on the last frame.
        let watchdog = Task {
            while session.isRunning && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if !Task.isCancelled {
                try? await outbound.close(.goingAway, reason: "device disconnected")
            }
        }
        defer { watchdog.cancel() }

        let dispatcher = GestureDispatcher(input: session.input, registry: .android)
        let gestures = androidGestureQueue(serial: serial)
        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                if androidControlKind(line) != nil {
                    // `force_idr` / `snapshot`: a fresh keyframe is the
                    // nearest thing a passthrough stream has to either.
                    session.requestKeyframe()
                    continue
                }
                // One serial queue per socket keeps a touch's down /
                // move / up in order, and keeps a swipe's sleeps off
                // the event loop.
                gestures.async { _ = dispatcher.dispatch(line: line) }
            }
        } catch {
            // socket closed; defers clean up
        }
    }

    /// `force_idr` and `snapshot` are the stream controls a keyframe
    /// answers. `set_bitrate` / `set_fps` / `set_scale` are accepted
    /// and ignored: scrcpy fixes them at server start (reconnect with
    /// `?restart=1` and new options instead).
    static func androidControlKind(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = dict["type"] as? String else { return nil }
        return kind == "force_idr" || kind == "snapshot" ? kind : nil
    }

    private static func androidGestureQueue(serial: String) -> DispatchQueue {
        DispatchQueue(label: "baguette.android.gestures.\(serial)", qos: .userInteractive)
    }

    private static func androidDispatch(line: String, on session: ScrcpySession) async -> String {
        let dispatcher = GestureDispatcher(input: session.input, registry: .android)
        return await withCheckedContinuation { continuation in
            androidGestureQueue(serial: session.serial).async {
                continuation.resume(returning: dispatcher.dispatch(line: line))
            }
        }
    }

    // MARK: - helpers

    /// Run blocking work (adb, a server start-up) off the event loop.
    private static func offLoop<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func androidStatus(for error: any Error) -> HTTPResponse.Status {
        switch error as? AndroidError {
        case .adbNotFound:       return .serviceUnavailable
        case .unknownDevice:     return .notFound
        case .deviceNotReady:    return .conflict
        default:                 return .internalServerError
        }
    }

    private static func androidJSONText(_ text: String) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: text))
        )
    }

    private static func androidError(_ error: any Error, status: HTTPResponse.Status) -> Response {
        androidError("\(error)", status: status)
    }

    private static func androidError(_ message: String, status: HTTPResponse.Status) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: androidErrorFrame(message)))
        )
    }

    static func androidErrorFrame(_ message: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message], options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"ok":false}"#
    }
}
