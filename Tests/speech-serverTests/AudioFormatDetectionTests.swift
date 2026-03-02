import XCTest

@testable import speech_server

final class AudioFormatDetectionTests: XCTestCase {
    // MARK: - Filename-based detection

    func testWAVFilenameExtension() {
        XCTAssertEqual(audioFileExtension(filename: "audio.wav", header: Data()), ".wav")
    }

    func testMP3FilenameExtension() {
        XCTAssertEqual(audioFileExtension(filename: "track.mp3", header: Data()), ".mp3")
    }

    func testM4AFilenameExtension() {
        XCTAssertEqual(audioFileExtension(filename: "clip.m4a", header: Data()), ".m4a")
    }

    func testFLACFilenameExtension() {
        XCTAssertEqual(audioFileExtension(filename: "song.flac", header: Data()), ".flac")
    }

    func testAIFFFilenameExtension() {
        XCTAssertEqual(audioFileExtension(filename: "sound.aiff", header: Data()), ".aiff")
    }

    func testOGGFilenameExtension() {
        XCTAssertEqual(audioFileExtension(filename: "voice.ogg", header: Data()), ".ogg")
    }

    func testCaseInsensitiveExtension() {
        XCTAssertEqual(audioFileExtension(filename: "AUDIO.WAV", header: Data()), ".wav")
        XCTAssertEqual(audioFileExtension(filename: "Track.MP3", header: Data()), ".mp3")
    }

    // MARK: - Filename priority over magic bytes

    func testFilenameOverridesWAVMagic() {
        // mp3 filename, but WAV magic bytes → filename wins
        let wavMagic = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        XCTAssertEqual(audioFileExtension(filename: "upload.mp3", header: wavMagic), ".mp3")
    }

    // MARK: - Magic byte detection (no/unknown filename extension)

    func testWAVMagicBytes() {
        // RIFF....WAVE
        let header = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x08, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".wav")
    }

    func testFLACMagicBytes() {
        // fLaC
        let header = Data([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".flac")
    }

    func testMP3ID3Header() {
        // ID3
        let header = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".mp3")
    }

    func testMP3SyncBytesFFfb() {
        let header = Data([0xFF, 0xFB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".mp3")
    }

    func testMP3SyncBytesFFf3() {
        let header = Data([0xFF, 0xF3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".mp3")
    }

    func testM4AFtypHeader() {
        // bytes 4–7 == "ftyp"
        let header = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".m4a")
    }

    func testAIFFHeader() {
        // FORM....AIFF
        let header = Data([0x46, 0x4F, 0x52, 0x4D, 0x00, 0x00, 0x00, 0x00, 0x41, 0x49, 0x46, 0x46])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".aiff")
    }

    func testAIFCHeader() {
        // FORM....AIFC
        let header = Data([0x46, 0x4F, 0x52, 0x4D, 0x00, 0x00, 0x00, 0x00, 0x41, 0x49, 0x46, 0x43])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".aiff")
    }

    // MARK: - Fallback

    func testUnknownMagicBytesReturnWAV() {
        let header = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".wav")
    }

    func testShortHeaderReturnWAV() {
        // Fewer than 12 bytes → fallback
        let header = Data([0x52, 0x49, 0x46, 0x46])
        XCTAssertEqual(audioFileExtension(filename: "upload", header: header), ".wav")
    }

    func testEmptyHeaderAndUnknownFilename() {
        XCTAssertEqual(audioFileExtension(filename: "upload", header: Data()), ".wav")
    }
}
