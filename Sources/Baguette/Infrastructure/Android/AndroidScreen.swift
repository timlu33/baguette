import Foundation

/// The live picture of one Android device, fanned out to every browser
/// watching it. scrcpy hands over one H.264 stream; this turns it into
/// the AVCC envelope `frame-decoder.js` already decodes and gives each
/// viewer a decodable start: the cached description at once, then
/// frames from the first keyframe on. A viewer that joins mid-GOP never
/// sees a delta it has no reference for.
final class AndroidScreen: @unchecked Sendable {
    private struct Viewer {
        let sink: @Sendable (Data) -> Void
        var awaitingKeyframe: Bool
    }

    private let lock = NSLock()
    private var viewers: [UUID: Viewer] = [:]
    private var description: Data?
    private var lastSize = Size(width: 0, height: 0)

    /// Called (outside the lock) when a viewer attaches, so the session
    /// can ask the device for a fresh keyframe rather than make the
    /// newcomer wait out the encoder's keyframe interval.
    var onKeyframeNeeded: (@Sendable () -> Void)?

    var size: Size { lock.withLock { lastSize } }
    var viewerCount: Int { lock.withLock { viewers.count } }

    func attach(id: UUID, sink: @escaping @Sendable (Data) -> Void) {
        let replay: Data? = lock.withLock {
            viewers[id] = Viewer(sink: sink, awaitingKeyframe: true)
            return description
        }
        if let replay { sink(replay) }
        onKeyframeNeeded?()
    }

    func detach(id: UUID) {
        lock.withLock { viewers[id] = nil }
    }

    func ingest(_ event: ScrcpyVideoParser.Event) {
        switch event {
        case .video(let width, let height):
            lock.withLock { lastSize = Size(width: Double(width), height: Double(height)) }

        case .config(let annexB):
            guard let avcC = H264AnnexB.avcConfiguration(from: annexB) else { return }
            let chunk = AVCCEnvelope.description(avcc: avcC)
            let sps = H264AnnexB.nalus(in: annexB).first { ($0.first ?? 0) & 0x1F == 7 }
            let sinks: [@Sendable (Data) -> Void] = lock.withLock {
                description = chunk
                if let size = sps.flatMap({ H264SPS.dimensions(of: $0) }) { lastSize = size }
                // A new description means a new decoder state: nothing
                // before the next keyframe can be decoded against it.
                for id in viewers.keys { viewers[id]?.awaitingKeyframe = true }
                return viewers.values.map(\.sink)
            }
            for sink in sinks { sink(chunk) }

        case .frame(let annexB, let keyFrame):
            let payload = H264AnnexB.lengthPrefixed(annexB)
            guard !payload.isEmpty else { return }
            let chunk = keyFrame ? AVCCEnvelope.keyframe(avcc: payload) : AVCCEnvelope.delta(avcc: payload)
            let sinks: [@Sendable (Data) -> Void] = lock.withLock {
                var ready: [@Sendable (Data) -> Void] = []
                for (id, viewer) in viewers {
                    if keyFrame { viewers[id]?.awaitingKeyframe = false }
                    if keyFrame || !viewer.awaitingKeyframe { ready.append(viewer.sink) }
                }
                return ready
            }
            for sink in sinks { sink(chunk) }

        case .deviceName, .failure:
            break
        }
    }
}
