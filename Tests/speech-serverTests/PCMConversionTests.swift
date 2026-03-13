import XCTest

@testable import speech_server

final class PCMConversionTests: XCTestCase {
    // MARK: - float32ToPCM16

    func testEmptySamplesProducesEmptyData() {
        let data = float32ToPCM16([])
        XCTAssertTrue(data.isEmpty)
    }

    func testSilenceConvertsToZeroPCM() {
        let samples: [Float] = [0.0, 0.0, 0.0]
        let data = float32ToPCM16(samples)
        // Peak is 0, so maxVal falls back to 1.0; all samples → 0 → Int16(0)
        XCTAssertEqual(data.count, samples.count * 2)
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
    }

    func testPositivePeakClipsToMaxInt16() {
        let samples: [Float] = [1.0]
        let data = float32ToPCM16(samples)
        XCTAssertEqual(data.count, 2)
        // Peak-normalised 1.0 → 32767
        let value = data.withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(value, 32767)
    }

    func testNegativePeakClipsToMinInt16() {
        let samples: [Float] = [-1.0]
        let data = float32ToPCM16(samples)
        XCTAssertEqual(data.count, 2)
        let value = data.withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(value, -32767)
    }

    func testPeakNormalisationScalesAll() {
        // Peak is 0.5 — should be normalised to 32767
        let samples: [Float] = [0.5, -0.25]
        let data = float32ToPCM16(samples)
        XCTAssertEqual(data.count, 4)
        let v0 = data[0..<2].withUnsafeBytes { $0.load(as: Int16.self) }
        let v1 = data[2..<4].withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(v0, 32767)  // 0.5/0.5 * 32767 = 32767
        // -0.25 / 0.5 * 32767 = -16383 (allow ±1 for rounding)
        XCTAssertTrue(abs(Int32(v1) - (-16383)) <= 1, "Expected v1 ≈ -16383, got \(v1)")
    }

    func testOutputIsLittleEndian() {
        let samples: [Float] = [1.0]
        let data = float32ToPCM16(samples)
        // 32767 in LE = 0xFF 0x7F
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0x7F)
    }

    // MARK: - makeWAV

    func testMakeWAVStartsWithRIFF() {
        let wav = makeWAV(pcmData: Data(repeating: 0, count: 4), sampleRate: 22_050)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
    }

    func testMakeWAVContainsWAVEHeader() {
        let wav = makeWAV(pcmData: Data(repeating: 0, count: 4), sampleRate: 22_050)
        XCTAssertEqual(wav[8..<12], Data("WAVE".utf8))
    }

    func testMakeWAVTotalSize() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = makeWAV(pcmData: pcm, sampleRate: 22_050)
        // 44-byte header + 100 bytes PCM
        XCTAssertEqual(wav.count, 44 + pcm.count)
    }

    func testMakeWAVSampleRateField() {
        let wav = makeWAV(pcmData: Data(count: 4), sampleRate: 44_100)
        // Sample rate is at bytes 24-27 (LE UInt32)
        let rate = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(rate), 44_100)
    }

    func testMakeWAVDataChunkContainsPCM() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let wav = makeWAV(pcmData: pcm, sampleRate: 22_050)
        // "data" marker at bytes 36-39
        XCTAssertEqual(wav[36..<40], Data("data".utf8))
        // PCM payload at bytes 44+
        XCTAssertEqual(wav.suffix(pcm.count), pcm)
    }

    func testMakeWAVFileSizeField() {
        let pcmSize = 200
        let pcm = Data(repeating: 0, count: pcmSize)
        let wav = makeWAV(pcmData: pcm, sampleRate: 22_050)
        // File size field at bytes 4-7 = 36 + dataSize
        let fileSize = wav[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(fileSize), 36 + pcmSize)
    }
}
