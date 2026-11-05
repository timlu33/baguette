import Testing
import Foundation
@testable import Baguette

@Suite("ScrcpyLaunch")
struct ScrcpyLaunchTests {

    @Test func `should name the abstract socket after the session id in eight hex digits`() {
        #expect(ScrcpyLaunch(scid: 0x1A2B).socketName == "scrcpy_00001a2b")
    }

    @Test func `should open with the server version then key=value options`() {
        let launch = ScrcpyLaunch(scid: 1)
        #expect(launch.arguments.first == ScrcpyLaunch.serverVersion)
        #expect(launch.arguments.dropFirst().allSatisfy { $0.contains("=") })
    }

    @Test func `should ask for H264 video and control but no audio`() {
        let args = ScrcpyLaunch(scid: 1).arguments
        #expect(args.contains("video_codec=h264"))
        #expect(args.contains("audio=false"))
        #expect(args.contains("control=true"))
    }

    @Test func `should make the device listen so the host can connect after adb forward`() {
        let args = ScrcpyLaunch(scid: 1).arguments
        #expect(args.contains("tunnel_forward=true"))
        #expect(args.contains("send_dummy_byte=true"))
        #expect(args.contains("send_frame_meta=true"))
        #expect(args.contains("send_codec_meta=true"))
        #expect(args.contains("send_device_meta=true"))
        #expect(args.contains("raw_stream=false") || !args.contains { $0.hasPrefix("raw_stream") })
    }

    @Test func `should carry the session id as eight hex digits`() {
        #expect(ScrcpyLaunch(scid: 0xBEEF).arguments.contains("scid=0000beef"))
    }

    @Test func `should pass the size bitrate and frame rate caps`() {
        let args = ScrcpyLaunch(scid: 1, maxSize: 1280, bitRate: 4_000_000, maxFps: 30).arguments
        #expect(args.contains("max_size=1280"))
        #expect(args.contains("video_bit_rate=4000000"))
        #expect(args.contains("max_fps=30"))
    }

    @Test func `should leave a cap off when it is zero so the device keeps native resolution`() {
        let args = ScrcpyLaunch(scid: 1, maxSize: 0, bitRate: 0, maxFps: 0).arguments
        #expect(!args.contains { $0.hasPrefix("max_size") })
        #expect(!args.contains { $0.hasPrefix("video_bit_rate") })
        #expect(!args.contains { $0.hasPrefix("max_fps") })
    }

    @Test func `should not sync the clipboard behind the user's back`() {
        #expect(ScrcpyLaunch(scid: 1).arguments.contains("clipboard_autosync=false"))
    }

    @Test func `should leave no cleanup process behind the server on the device`() {
        #expect(ScrcpyLaunch(scid: 1).arguments.contains("cleanup=false"))
    }

    @Test func `should run the server jar through app_process`() {
        let shell = ScrcpyLaunch(scid: 1).shellCommand(jar: "/data/local/tmp/scrcpy-server.jar")
        #expect(shell.prefix(3) == ["CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/"])
        #expect(shell[3] == "com.genymobile.scrcpy.Server")
        #expect(shell[4] == ScrcpyLaunch.serverVersion)
    }

    @Test func `should read the port adb forward prints`() {
        #expect(ScrcpyLaunch.port(fromForwardOutput: "54321\n") == 54321)
        #expect(ScrcpyLaunch.port(fromForwardOutput: "garbage") == nil)
        #expect(ScrcpyLaunch.port(fromForwardOutput: "0") == nil)
    }
}
