import Foundation

/// Reads the picture size out of an H.264 sequence parameter set, so the
/// host knows the live video size even after the phone rotates (scrcpy
/// sends the size once, at connect, and a rotation only re-sends a new SPS).
enum H264SPS {
    /// - Parameter sps: the NAL unit including its one-byte header.
    /// - Returns: `nil` for a stream this reader does not understand
    ///   (scaling lists, truncation) — callers keep the size they had.
    static func dimensions(of sps: Data) -> Size? {
        guard sps.count > 4 else { return nil }
        var reader = BitReader(unescaped(Array(sps.dropFirst())))
        guard let profile = reader.bits(8) else { return nil }
        guard reader.skip(16) else { return nil }          // constraint flags + level
        guard reader.ue() != nil else { return nil }        // seq_parameter_set_id

        var chromaFormat = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let chroma = reader.ue() else { return nil }
            chromaFormat = chroma
            if chroma == 3, reader.bits(1) == nil { return nil }   // separate_colour_plane_flag
            guard reader.ue() != nil, reader.ue() != nil else { return nil } // bit depths
            guard reader.bits(1) != nil else { return nil }                  // qpprime bypass
            guard let scaling = reader.bits(1), scaling == 0 else { return nil }
        }

        guard reader.ue() != nil else { return nil }        // log2_max_frame_num_minus4
        guard let pocType = reader.ue() else { return nil }
        if pocType == 0 {
            guard reader.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard reader.bits(1) != nil, reader.se() != nil, reader.se() != nil,
                  let cycle = reader.ue(), cycle <= 255 else { return nil }
            for _ in 0..<cycle { guard reader.se() != nil else { return nil } }
        }
        guard reader.ue() != nil, reader.bits(1) != nil else { return nil } // refs, gaps

        guard let widthMBs = reader.ue(), let heightUnits = reader.ue(),
              let frameMBsOnly = reader.bits(1) else { return nil }
        if frameMBsOnly == 0, reader.bits(1) == nil { return nil }          // mb_adaptive
        guard reader.bits(1) != nil else { return nil }                      // direct_8x8
        guard let cropping = reader.bits(1) else { return nil }

        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if cropping == 1 {
            guard let l = reader.ue(), let r = reader.ue(), let t = reader.ue(), let b = reader.ue()
            else { return nil }
            crop = (l, r, t, b)
        }

        let heightFactor = 2 - frameMBsOnly
        // 4:2:0 and 4:2:2 halve the chroma width; 4:2:0 also halves its height.
        let unitX = (chromaFormat == 1 || chromaFormat == 2) ? 2 : 1
        let unitY = (chromaFormat == 1 ? 2 : 1) * heightFactor
        let width = (widthMBs + 1) * 16 - (crop.left + crop.right) * unitX
        let height = heightFactor * (heightUnits + 1) * 16 - (crop.top + crop.bottom) * unitY
        guard width > 0, height > 0 else { return nil }
        return Size(width: Double(width), height: Double(height))
    }

    /// Drop the `03` of every `00 00 03` — the escape that keeps a start
    /// code from appearing inside a NAL unit.
    private static func unescaped(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    private struct BitReader {
        private let bytes: [UInt8]
        private var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bits(_ count: Int) -> Int? {
            guard position + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                value = value << 1 | Int((bytes[position / 8] >> UInt8(7 - position % 8)) & 1)
                position += 1
            }
            return value
        }

        mutating func skip(_ count: Int) -> Bool { bits(count) != nil }

        /// Unsigned Exp-Golomb.
        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let bit = bits(1) else { return nil }
                if bit == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = zeros == 0 ? 0 : bits(zeros) else { return nil }
            return (1 << zeros) - 1 + rest
        }

        /// Signed Exp-Golomb.
        mutating func se() -> Int? {
            guard let k = ue() else { return nil }
            return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
        }
    }
}
