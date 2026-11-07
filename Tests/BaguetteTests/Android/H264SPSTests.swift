import Testing
import Foundation
@testable import Baguette

/// Writes the fields of a sequence parameter set the way the spec lays
/// them out, so the parser is judged against the format and not against
/// its own idea of it.
private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var used = 0

    mutating func bit(_ value: Int) {
        if used % 8 == 0 { bytes.append(0) }
        if value != 0 { bytes[bytes.count - 1] |= UInt8(0x80 >> (used % 8)) }
        used += 1
    }

    mutating func bits(_ value: Int, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) { bit((value >> shift) & 1) }
    }

    mutating func ue(_ value: Int) {
        let coded = value + 1
        let length = Int.bitWidth - coded.leadingZeroBitCount
        bits(0, count: length - 1)
        bits(coded, count: length)
    }

    mutating func se(_ value: Int) { ue(value > 0 ? 2 * value - 1 : -2 * value) }
}

@Suite("H264SPS")
struct H264SPSTests {

    private func sps(
        profile: Int = 100,
        widthMBs: Int,
        heightMapUnits: Int,
        frameMBsOnly: Bool = true,
        crop: (left: Int, right: Int, top: Int, bottom: Int)? = nil,
        pocType: Int = 0,
        scalingMatrix: Bool = false
    ) -> Data {
        var w = BitWriter()
        w.bits(profile, count: 8); w.bits(0, count: 8); w.bits(40, count: 8)
        w.ue(0)                                   // seq_parameter_set_id
        if [100, 110, 122, 244].contains(profile) {
            w.ue(1)                               // chroma_format_idc 4:2:0
            w.ue(0); w.ue(0)                      // bit depths
            w.bit(0)                              // qpprime_y_zero_transform_bypass
            w.bit(scalingMatrix ? 1 : 0)
        }
        w.ue(0)                                   // log2_max_frame_num_minus4
        w.ue(pocType)
        if pocType == 0 { w.ue(0) } else if pocType == 1 {
            w.bit(0); w.se(0); w.se(0); w.ue(2); w.se(1); w.se(-1)
        }
        w.ue(4)                                   // max_num_ref_frames
        w.bit(0)                                  // gaps_in_frame_num_allowed
        w.ue(widthMBs - 1)
        w.ue(heightMapUnits - 1)
        w.bit(frameMBsOnly ? 1 : 0)
        if !frameMBsOnly { w.bit(0) }             // mb_adaptive_frame_field
        w.bit(1)                                  // direct_8x8_inference
        if let crop {
            w.bit(1); w.ue(crop.left); w.ue(crop.right); w.ue(crop.top); w.ue(crop.bottom)
        } else { w.bit(0) }
        w.bit(0)                                  // vui_parameters_present
        w.bit(1)                                  // rbsp stop bit
        return Data([0x67] + w.bytes)
    }

    @Test func `should read the size of an uncropped High profile stream`() {
        // 45 × 80 macroblocks = 720 × 1280.
        #expect(H264SPS.dimensions(of: sps(widthMBs: 45, heightMapUnits: 80)) == Size(width: 720, height: 1280))
    }

    @Test func `should subtract the crop rectangle from the macroblock size`() {
        // 1080 is not a multiple of 16: 68 MBs = 1088, cropped by 8 rows (4 units of 2).
        let data = sps(widthMBs: 120, heightMapUnits: 68, crop: (0, 0, 0, 4))
        #expect(H264SPS.dimensions(of: data) == Size(width: 1920, height: 1080))
    }

    @Test func `should read a Baseline profile SPS that has no chroma fields`() {
        let data = sps(profile: 66, widthMBs: 20, heightMapUnits: 15)
        #expect(H264SPS.dimensions(of: data) == Size(width: 320, height: 240))
    }

    @Test func `should double the height of an interlaced stream's map units`() {
        let data = sps(widthMBs: 20, heightMapUnits: 8, frameMBsOnly: false)
        #expect(H264SPS.dimensions(of: data) == Size(width: 320, height: 256))
    }

    @Test func `should skip over a picture order count type one cycle`() {
        let data = sps(widthMBs: 10, heightMapUnits: 10, pocType: 1)
        #expect(H264SPS.dimensions(of: data) == Size(width: 160, height: 160))
    }

    @Test func `should read through emulation prevention bytes`() {
        // 0x0000 in the payload is escaped as 00 00 03; width of 45 MBs is not
        // one, so build a size whose coded bits contain two zero bytes.
        var escaped = Data()
        var zeros = 0
        for byte in sps(widthMBs: 45, heightMapUnits: 80) {
            if zeros >= 2, byte <= 3 { escaped.append(3); zeros = 0 }
            escaped.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        #expect(H264SPS.dimensions(of: escaped) == Size(width: 720, height: 1280))
    }

    @Test func `should give up on a stream with scaling lists rather than guess`() {
        #expect(H264SPS.dimensions(of: sps(widthMBs: 45, heightMapUnits: 80, scalingMatrix: true)) == nil)
    }

    @Test func `should give up on a truncated SPS`() {
        #expect(H264SPS.dimensions(of: Data([0x67, 0x64])) == nil)
        #expect(H264SPS.dimensions(of: Data()) == nil)
    }
}
