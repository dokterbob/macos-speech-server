import XCTest

@testable import speech_server

final class WyomingWAVWriterTests: XCTestCase {
    // MARK: - WAV header structure

    func testWAVHeaderSignatures() {
        let writer = WyomingWAVWriter()
        let wav = writer.makeWAV()

        // RIFF
        XCTAssertEqual(wav[0..<4], Data("RIFF".utf8))
        // WAVE
        XCTAssertEqual(wav[8..<12], Data("WAVE".utf8))
        // fmt
        XCTAssertEqual(wav[12..<16], Data("fmt ".utf8))
        // data
        XCTAssertEqual(wav[36..<40], Data("data".utf8))
    }

    func testWAVHeaderSizesWithNoPCM() {
        let writer = WyomingWAVWriter()
        let wav = writer.makeWAV()

        // Total size field (bytes 4-7): dataSize + 36 = 0 + 36 = 36
        let totalSize = readUInt32LE(wav, offset: 4)
        XCTAssertEqual(totalSize, 36)

        // fmt sub-chunk size (bytes 16-19): 16
        let fmtSize = readUInt32LE(wav, offset: 16)
        XCTAssertEqual(fmtSize, 16)

        // data sub-chunk size (bytes 40-43): 0
        let dataSize = readUInt32LE(wav, offset: 40)
        XCTAssertEqual(dataSize, 0)

        // Total WAV = 44 bytes (header only)
        XCTAssertEqual(wav.count, 44)
    }

    func testWAVHeaderFormatFields() {
        let writer = WyomingWAVWriter(sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let wav = writer.makeWAV()

        // Audio format (bytes 20-21): 1 = PCM
        let audioFormat = readUInt16LE(wav, offset: 20)
        XCTAssertEqual(audioFormat, 1)

        // Channels (bytes 22-23): 1
        let channels = readUInt16LE(wav, offset: 22)
        XCTAssertEqual(channels, 1)

        // Sample rate (bytes 24-27): 16000
        let sampleRate = readUInt32LE(wav, offset: 24)
        XCTAssertEqual(sampleRate, 16000)

        // Byte rate (bytes 28-31): 16000 * 1 * 16/8 = 32000
        let byteRate = readUInt32LE(wav, offset: 28)
        XCTAssertEqual(byteRate, 32000)

        // Block align (bytes 32-33): 1 * 16/8 = 2
        let blockAlign = readUInt16LE(wav, offset: 32)
        XCTAssertEqual(blockAlign, 2)

        // Bits per sample (bytes 34-35): 16
        let bitsPerSample = readUInt16LE(wav, offset: 34)
        XCTAssertEqual(bitsPerSample, 16)
    }

    func testWAVWithPCMData() {
        var writer = WyomingWAVWriter()
        let pcm = Data(repeating: 0x42, count: 100)
        writer.append(pcm)

        let wav = writer.makeWAV()

        // Total file = 44 (header) + 100 (PCM) = 144
        XCTAssertEqual(wav.count, 144)

        // Total size field: 100 + 36 = 136
        let totalSize = readUInt32LE(wav, offset: 4)
        XCTAssertEqual(totalSize, 136)

        // data sub-chunk size: 100
        let dataSize = readUInt32LE(wav, offset: 40)
        XCTAssertEqual(dataSize, 100)

        // PCM bytes at offset 44
        XCTAssertEqual(wav[44..<144], pcm)
    }

    // MARK: - Multi-chunk append

    func testMultiChunkAppend() {
        var writer = WyomingWAVWriter()
        let chunk1 = Data([0x01, 0x02])
        let chunk2 = Data([0x03, 0x04])
        let chunk3 = Data([0x05, 0x06])
        writer.append(chunk1)
        writer.append(chunk2)
        writer.append(chunk3)

        XCTAssertEqual(writer.byteCount, 6)
        XCTAssertFalse(writer.isEmpty)

        let wav = writer.makeWAV()
        XCTAssertEqual(wav.count, 50)  // 44 + 6
        XCTAssertEqual(wav[44...], Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
    }

    func testEmptyWriter() {
        let writer = WyomingWAVWriter()
        XCTAssertEqual(writer.byteCount, 0)
        XCTAssertTrue(writer.isEmpty)
        XCTAssertEqual(writer.makeWAV().count, 44)  // header only
    }

    // MARK: - Custom sample rates

    func testCustomSampleRate() {
        let writer = WyomingWAVWriter(sampleRate: 24000, channels: 1, bitsPerSample: 16)
        let wav = writer.makeWAV()
        let sampleRate = readUInt32LE(wav, offset: 24)
        XCTAssertEqual(sampleRate, 24000)
        let byteRate = readUInt32LE(wav, offset: 28)
        XCTAssertEqual(byteRate, 48000)  // 24000 * 1 * 16/8
    }

    func testStereoConfiguration() {
        let writer = WyomingWAVWriter(sampleRate: 44100, channels: 2, bitsPerSample: 16)
        let wav = writer.makeWAV()
        let channels = readUInt16LE(wav, offset: 22)
        XCTAssertEqual(channels, 2)
        let byteRate = readUInt32LE(wav, offset: 28)
        XCTAssertEqual(byteRate, 176400)  // 44100 * 2 * 16/8
        let blockAlign = readUInt16LE(wav, offset: 32)
        XCTAssertEqual(blockAlign, 4)  // 2 * 16/8
    }

    // MARK: - writeToTempFile

    func testWriteToTempFile() throws {
        var writer = WyomingWAVWriter()
        writer.append(Data(repeating: 0x00, count: 32))

        let url = try writer.writeToTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "wav")

        let readBack = try Data(contentsOf: url)
        XCTAssertEqual(readBack, writer.makeWAV())
    }

    func testWriteToTempFileProducesUniqueURLs() throws {
        let writer = WyomingWAVWriter()
        let url1 = try writer.writeToTempFile()
        let url2 = try writer.writeToTempFile()
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        XCTAssertNotEqual(url1, url2)
    }

    // MARK: - Helpers

    private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        return lo | (hi << 8)
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
