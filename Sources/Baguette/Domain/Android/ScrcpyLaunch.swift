import Foundation

/// How to start the official scrcpy server on a device: the argument
/// list `app_process` hands to `com.genymobile.scrcpy.Server`, and the
/// socket name it will listen on. Pure value; spawning is elsewhere.
///
/// Targets the **v3.3.3** server. The server aborts when its version
/// string disagrees with the first argument, so the jar baguette ships
/// and `serverVersion` must move together.
struct ScrcpyLaunch: Equatable, Sendable {
    static let serverVersion = "3.3.3"
    static let serverClass = "com.genymobile.scrcpy.Server"

    /// Session id: names the abstract socket so concurrent sessions on
    /// one device do not collide.
    let scid: UInt32
    /// Longest side in pixels; `0` keeps the device's native size.
    let maxSize: Int
    /// Video bit rate in bits per second; `0` takes scrcpy's default (8 Mbit/s).
    let bitRate: Int
    /// Frame-rate cap; `0` means uncapped.
    let maxFps: Int

    init(scid: UInt32, maxSize: Int = 0, bitRate: Int = 0, maxFps: Int = 0) {
        self.scid = scid
        self.maxSize = max(0, maxSize)
        self.bitRate = max(0, bitRate)
        self.maxFps = max(0, maxFps)
    }

    var scidHex: String { String(format: "%08x", scid) }
    var socketName: String { "scrcpy_\(scidHex)" }

    /// Version first, then `key=value` options.
    var arguments: [String] {
        var args = [
            Self.serverVersion,
            "scid=\(scidHex)",
            "log_level=info",
            "video=true",
            "audio=false",
            "control=true",
            "video_codec=h264",
            // Forward tunnel: the device listens, the host connects
            // after `adb forward`. The dummy byte lets the host tell a
            // live tunnel from one adb accepted but the device didn't.
            "tunnel_forward=true",
            "send_dummy_byte=true",
            "send_device_meta=true",
            "send_codec_meta=true",
            "send_frame_meta=true",
            "raw_stream=false",
            "clipboard_autosync=false",
            "cleanup=false",
        ]
        if maxSize > 0 { args.append("max_size=\(maxSize)") }
        if bitRate > 0 { args.append("video_bit_rate=\(bitRate)") }
        if maxFps > 0 { args.append("max_fps=\(maxFps)") }
        return args
    }

    /// The argv after `adb -s <serial> shell`.
    func shellCommand(jar: String) -> [String] {
        ["CLASSPATH=\(jar)", "app_process", "/", Self.serverClass] + arguments
    }

    /// `adb forward tcp:0 …` prints the port it picked.
    static func port(fromForwardOutput output: String) -> Int? {
        guard let port = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else { return nil }
        return port
    }
}
