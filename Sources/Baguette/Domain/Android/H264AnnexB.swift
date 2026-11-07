import Foundation

/// scrcpy ships H.264 as Annex-B (start-code delimited); the browser's
/// WebCodecs path in `frame-decoder.js` wants AVCC (length-prefixed
/// frames plus an avcC description). This is the pure conversion.
enum H264AnnexB {
    /// Split a byte stream on `00 00 01` / `00 00 00 01` start codes.
    /// The extra zero of a four-byte code belongs to the code, not to
    /// the unit before it. Bytes ahead of the first start code are
    /// not a unit and are dropped.
    static func nalus(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                // A zero immediately before 00 00 01 makes it a 4-byte code.
                let codeStart = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                starts.append((codeStart, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Data] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].code : bytes.count
            if start.payload < end { units.append(Data(bytes[start.payload..<end])) }
        }
        return units
    }

    /// The same access unit with each start code replaced by a 4-byte
    /// big-endian length — AVCC with `lengthSizeMinusOne = 3`.
    static func lengthPrefixed(_ annexB: Data) -> Data {
        var out = Data()
        for unit in nalus(in: annexB) {
            let n = UInt32(unit.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            out.append(unit)
        }
        return out
    }

    /// The avcC configuration record for a config packet carrying an SPS
    /// and a PPS. `nil` when either is missing — a decoder cannot be
    /// configured from half a description.
    static func avcConfiguration(from config: Data) -> Data? {
        let units = nalus(in: config)
        guard let sps = units.first(where: { ($0.first ?? 0) & 0x1F == 7 }), sps.count >= 4,
              let pps = units.first(where: { ($0.first ?? 0) & 0x1F == 8 })
        else { return nil }
        let s = [UInt8](sps)
        var out = Data([1, s[1], s[2], s[3], 0xFF, 0xE1])
        out.append(contentsOf: [UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)])
        out.append(sps)
        out.append(1)
        out.append(contentsOf: [UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)])
        out.append(pps)
        return out
    }
}
