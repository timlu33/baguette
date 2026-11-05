import Testing
import Foundation
@testable import Baguette

@Suite("AndroidScreen")
struct AndroidScreenTests {

    private final class Viewer: @unchecked Sendable {
        var chunks: [Data] = []
        var tags: [UInt8] { chunks.compactMap { AVCCEnvelope.unwrap($0)?.tag } }
    }

    private let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC])
    private let pps = Data([0x68, 0xEE, 0x3C, 0x80])
    private var config: Data {
        var d = Data([0, 0, 0, 1]); d.append(sps)
        d.append(contentsOf: [0, 0, 0, 1]); d.append(pps)
        return d
    }
    private func unit(_ byte: UInt8) -> Data { Data([0, 0, 0, 1, byte, 1, 2, 3]) }

    @Test func `should send each attached viewer the description then every frame in order`() {
        let screen = AndroidScreen()
        let viewer = Viewer()
        screen.attach(id: UUID()) { viewer.chunks.append($0) }
        screen.ingest(.config(config))
        screen.ingest(.frame(unit(0x65), keyFrame: true))
        screen.ingest(.frame(unit(0x41), keyFrame: false))
        #expect(viewer.tags == [AVCCEnvelope.descriptionTag, AVCCEnvelope.keyframeTag, AVCCEnvelope.deltaTag])
    }

    @Test func `should hand a late viewer the cached description at once`() {
        let screen = AndroidScreen()
        screen.ingest(.config(config))
        let viewer = Viewer()
        screen.attach(id: UUID()) { viewer.chunks.append($0) }
        #expect(viewer.tags == [AVCCEnvelope.descriptionTag])
    }

    @Test func `should hold a late viewer back from deltas until a keyframe arrives`() {
        let screen = AndroidScreen()
        screen.ingest(.config(config))
        let viewer = Viewer()
        screen.attach(id: UUID()) { viewer.chunks.append($0) }
        screen.ingest(.frame(unit(0x41), keyFrame: false))
        screen.ingest(.frame(unit(0x41), keyFrame: false))
        #expect(viewer.tags == [AVCCEnvelope.descriptionTag])
        screen.ingest(.frame(unit(0x65), keyFrame: true))
        screen.ingest(.frame(unit(0x41), keyFrame: false))
        #expect(viewer.tags == [
            AVCCEnvelope.descriptionTag, AVCCEnvelope.keyframeTag, AVCCEnvelope.deltaTag,
        ])
    }

    @Test func `should not disturb a viewer that is already live when another joins`() {
        let screen = AndroidScreen()
        let first = Viewer()
        screen.attach(id: UUID()) { first.chunks.append($0) }
        screen.ingest(.config(config))
        screen.ingest(.frame(unit(0x65), keyFrame: true))
        screen.attach(id: UUID()) { _ in }
        screen.ingest(.frame(unit(0x41), keyFrame: false))
        #expect(first.tags == [AVCCEnvelope.descriptionTag, AVCCEnvelope.keyframeTag, AVCCEnvelope.deltaTag])
    }

    @Test func `should ask the device for a fresh keyframe when a viewer joins`() {
        let screen = AndroidScreen()
        final class Counter: @unchecked Sendable { var n = 0 }
        let asked = Counter()
        screen.onKeyframeNeeded = { asked.n += 1 }
        screen.attach(id: UUID()) { _ in }
        #expect(asked.n == 1)
    }

    @Test func `should stop sending to a viewer that left`() {
        let screen = AndroidScreen()
        let viewer = Viewer()
        let id = UUID()
        screen.attach(id: id) { viewer.chunks.append($0) }
        screen.detach(id: id)
        screen.ingest(.config(config))
        #expect(viewer.chunks.isEmpty)
        #expect(screen.viewerCount == 0)
    }

    @Test func `should require a new keyframe after the device re-sends its config`() {
        let screen = AndroidScreen()
        let viewer = Viewer()
        screen.attach(id: UUID()) { viewer.chunks.append($0) }
        screen.ingest(.config(config))
        screen.ingest(.frame(unit(0x65), keyFrame: true))
        screen.ingest(.config(config))          // device rotated: new encoder
        screen.ingest(.frame(unit(0x41), keyFrame: false))
        #expect(viewer.tags == [
            AVCCEnvelope.descriptionTag, AVCCEnvelope.keyframeTag, AVCCEnvelope.descriptionTag,
        ])
    }

    @Test func `should wrap frames as length prefixed AVCC`() throws {
        let screen = AndroidScreen()
        let viewer = Viewer()
        screen.attach(id: UUID()) { viewer.chunks.append($0) }
        screen.ingest(.config(config))
        screen.ingest(.frame(unit(0x65), keyFrame: true))
        let frame = try #require(AVCCEnvelope.unwrap(viewer.chunks[1]))
        #expect([UInt8](frame.payload) == [0, 0, 0, 4, 0x65, 1, 2, 3])
    }

    @Test func `should report the size the device declared`() {
        let screen = AndroidScreen()
        #expect(screen.size == Size(width: 0, height: 0))
        screen.ingest(.video(width: 720, height: 1600))
        #expect(screen.size == Size(width: 720, height: 1600))
    }

    @Test func `should ignore a config packet that has no PPS`() {
        let screen = AndroidScreen()
        let viewer = Viewer()
        screen.attach(id: UUID()) { viewer.chunks.append($0) }
        var onlySPS = Data([0, 0, 0, 1]); onlySPS.append(sps)
        screen.ingest(.config(onlySPS))
        #expect(viewer.chunks.isEmpty)
    }
}
