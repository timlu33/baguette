import Testing
import Foundation
@testable import Baguette

@Suite("ScrcpyVideoParser")
struct ScrcpyVideoParserTests {

    private func deviceName(_ name: String) -> Data {
        var data = Data(name.utf8)
        data.append(Data(repeating: 0, count: 64 - data.count))
        return data
    }

    private func codecHeader(width: UInt32, height: UInt32, codec: UInt32 = 0x6832_3634) -> Data {
        var data = Data()
        for value in [codec, width, height] {
            data.append(contentsOf: [
                UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ])
        }
        return data
    }

    private func packet(flags: UInt64, payload: [UInt8]) -> Data {
        var data = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((flags >> UInt64(shift)) & 0xFF))
        }
        let size = UInt32(payload.count)
        data.append(contentsOf: [
            UInt8(size >> 24), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        data.append(contentsOf: payload)
        return data
    }

    private let configFlag: UInt64 = 1 << 63
    private let keyFlag: UInt64 = 1 << 62

    @Test func `should skip the dummy byte then read the device name and the video size`() {
        var parser = ScrcpyVideoParser(expectsDummyByte: true)
        var bytes = Data([0])
        bytes.append(deviceName("Pixel 8"))
        bytes.append(codecHeader(width: 720, height: 1600))
        #expect(parser.push(bytes) == [
            .deviceName("Pixel 8"),
            .video(width: 720, height: 1600),
        ])
    }

    @Test func `should read the device name first when no dummy byte is expected`() {
        var parser = ScrcpyVideoParser(expectsDummyByte: false)
        var bytes = deviceName("Emu")
        bytes.append(codecHeader(width: 1, height: 2))
        #expect(parser.push(bytes) == [.deviceName("Emu"), .video(width: 1, height: 2)])
    }

    @Test func `should tell a config packet from a key frame and a delta frame`() {
        var parser = ScrcpyVideoParser(expectsDummyByte: false)
        var bytes = deviceName("x")
        bytes.append(codecHeader(width: 1, height: 1))
        bytes.append(packet(flags: configFlag, payload: [1, 2]))
        bytes.append(packet(flags: keyFlag | 7, payload: [3]))
        bytes.append(packet(flags: 9, payload: [4, 5, 6]))
        let events = parser.push(bytes)
        #expect(events.dropFirst(2) == [
            .config(Data([1, 2])),
            .frame(Data([3]), keyFrame: true),
            .frame(Data([4, 5, 6]), keyFrame: false),
        ][...])
    }

    @Test func `should wait for the rest of a packet that arrives in pieces`() {
        var parser = ScrcpyVideoParser(expectsDummyByte: false)
        var head = deviceName("x")
        head.append(codecHeader(width: 1, height: 1))
        _ = parser.push(head)
        let whole = packet(flags: 5, payload: [9, 9, 9, 9])
        #expect(parser.push(whole.prefix(3)) == [])
        #expect(parser.push(whole.dropFirst(3).prefix(10)) == [])
        #expect(parser.push(whole.dropFirst(13)) == [.frame(Data([9, 9, 9, 9]), keyFrame: false)])
    }

    @Test func `should refuse a codec other than H264`() {
        var parser = ScrcpyVideoParser(expectsDummyByte: false)
        var bytes = deviceName("x")
        bytes.append(codecHeader(width: 1, height: 1, codec: 0x6832_3635))
        let events = parser.push(bytes)
        #expect(events.count == 2)
        guard case .failure = events[1] else {
            Issue.record("expected a failure event, got \(events)")
            return
        }
    }

    @Test func `should refuse an absurd packet size instead of buffering it`() {
        var parser = ScrcpyVideoParser(expectsDummyByte: false)
        var bytes = deviceName("x")
        bytes.append(codecHeader(width: 1, height: 1))
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1, 0x7F, 0xFF, 0xFF, 0xFF])
        let events = parser.push(bytes)
        guard case .failure = events.last else {
            Issue.record("expected a failure event, got \(events)")
            return
        }
    }
}
