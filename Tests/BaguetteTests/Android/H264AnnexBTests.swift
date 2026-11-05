import Testing
import Foundation
@testable import Baguette

@Suite("H264AnnexB")
struct H264AnnexBTests {

    private let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC])
    private let pps = Data([0x68, 0xEE, 0x3C, 0x80])
    private let idr = Data([0x65, 0x88, 0x84, 0x00])

    @Test func `should split a stream on both three and four byte start codes`() {
        var stream = Data([0, 0, 0, 1]); stream.append(sps)
        stream.append(contentsOf: [0, 0, 1]); stream.append(pps)
        #expect(H264AnnexB.nalus(in: stream) == [sps, pps])
    }

    @Test func `should not leak the zero of a four byte start code into the previous unit`() {
        var stream = Data([0, 0, 1]); stream.append(sps)
        stream.append(contentsOf: [0, 0, 0, 1]); stream.append(idr)
        #expect(H264AnnexB.nalus(in: stream) == [sps, idr])
    }

    @Test func `should find no units in bytes without a start code`() {
        #expect(H264AnnexB.nalus(in: Data([1, 2, 3, 4])) == [])
    }

    @Test func `should rewrite start codes as four byte big-endian lengths`() {
        var stream = Data([0, 0, 0, 1]); stream.append(idr)
        #expect([UInt8](H264AnnexB.lengthPrefixed(stream)) == [0, 0, 0, 4, 0x65, 0x88, 0x84, 0x00])
    }

    @Test func `should build an avcC description from the SPS and PPS`() {
        var config = Data([0, 0, 0, 1]); config.append(sps)
        config.append(contentsOf: [0, 0, 0, 1]); config.append(pps)
        let avcC = H264AnnexB.avcConfiguration(from: config)
        #expect(avcC.map { [UInt8]($0) } == [
            1, 0x64, 0x00, 0x1F, 0xFF,
            0xE1, 0, 5, 0x67, 0x64, 0x00, 0x1F, 0xAC,
            1, 0, 4, 0x68, 0xEE, 0x3C, 0x80,
        ])
    }

    @Test func `should round trip a built avcC through the existing parameter-set parser`() {
        var config = Data([0, 0, 0, 1]); config.append(sps)
        config.append(contentsOf: [0, 0, 0, 1]); config.append(pps)
        let parsed = H264AnnexB.avcConfiguration(from: config).flatMap { AVCCParameterSets.parse(avcC: $0) }
        #expect(parsed?.sps == [sps])
        #expect(parsed?.pps == [pps])
        #expect(parsed?.naluHeaderLength == 4)
    }

    @Test func `should build no description when the config lacks a PPS`() {
        var config = Data([0, 0, 0, 1]); config.append(sps)
        #expect(H264AnnexB.avcConfiguration(from: config) == nil)
    }
}
