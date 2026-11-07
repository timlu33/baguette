import Foundation

/// Reads scrcpy's video socket, device → host. Pure and incremental:
/// feed it whatever the socket returned and it hands back the events
/// that are complete so far, keeping the rest for the next push.
///
/// The stream is: one dummy byte (the server writes it first when the
/// tunnel is "forward", so the host can tell a dead tunnel from a live
/// one), a 64-byte NUL-padded device name, a 12-byte codec header
/// (codec id, width, height), then packets — each an 8-byte
/// `pts | flags` word, a 4-byte size, and that many bytes of H.264.
struct ScrcpyVideoParser: Sendable {
    enum Event: Equatable, Sendable {
        case deviceName(String)
        case video(width: Int, height: Int)
        /// The SPS/PPS packet, Annex-B.
        case config(Data)
        /// One access unit, Annex-B.
        case frame(Data, keyFrame: Bool)
        /// The stream cannot continue; the parser emits nothing after it.
        case failure(String)
    }

    private enum Stage { case dummy, deviceName, codec, packetHeader, packetBody(size: Int, flags: UInt64), failed }

    static let h264: UInt32 = 0x6832_3634
    static let deviceNameLength = 64
    /// Far above a real keyframe, far below a runaway: a corrupt size
    /// field must fail the stream, not allocate a gigabyte.
    static let maxPacketSize = 16 << 20

    private static let configFlag: UInt64 = 1 << 63
    private static let keyFrameFlag: UInt64 = 1 << 62

    private var stage: Stage
    private var buffer = Data()

    init(expectsDummyByte: Bool) {
        stage = expectsDummyByte ? .dummy : .deviceName
    }

    mutating func push(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while let event = step() {
            if let event { events.append(event) }
            if case .failed = stage { break }
        }
        return events
    }

    /// `nil`: need more bytes. `.some(nil)`: advanced without an event.
    private mutating func step() -> Event?? {
        switch stage {
        case .failed:
            return nil

        case .dummy:
            guard take(1) != nil else { return nil }
            stage = .deviceName
            return .some(nil)

        case .deviceName:
            guard let raw = take(Self.deviceNameLength) else { return nil }
            let bytes = raw.prefix { $0 != 0 }
            stage = .codec
            return .deviceName(String(decoding: bytes, as: UTF8.self))

        case .codec:
            guard let raw = take(12) else { return nil }
            let codec = Self.uint32(raw, 0)
            guard codec == Self.h264 else {
                stage = .failed
                return .failure("unsupported video codec 0x\(String(codec, radix: 16)) — only H.264 is handled")
            }
            stage = .packetHeader
            return .video(width: Int(Self.uint32(raw, 4)), height: Int(Self.uint32(raw, 8)))

        case .packetHeader:
            guard let raw = take(12) else { return nil }
            let flags = Self.uint64(raw, 0)
            let size = Int(Self.uint32(raw, 8))
            guard size <= Self.maxPacketSize else {
                stage = .failed
                return .failure("video packet of \(size) bytes is implausible — stream is corrupt")
            }
            stage = .packetBody(size: size, flags: flags)
            return .some(nil)

        case .packetBody(let size, let flags):
            guard let body = take(size) else { return nil }
            stage = .packetHeader
            if flags & Self.configFlag != 0 { return .config(body) }
            return .frame(body, keyFrame: flags & Self.keyFrameFlag != 0)
        }
    }

    private mutating func take(_ count: Int) -> Data? {
        guard buffer.count >= count else { return nil }
        let head = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return head
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let s = data.startIndex + offset
        return UInt32(data[s]) << 24 | UInt32(data[s + 1]) << 16 | UInt32(data[s + 2]) << 8 | UInt32(data[s + 3])
    }

    private static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(uint32(data, offset)) << 32 | UInt64(uint32(data, offset + 4))
    }
}
