import AVFoundation
import XCTest

@testable import speech_server

/// Tests for AVSpeechTTSService.
///
/// These tests exercise the real AVSpeechSynthesizer (no model download needed — the
/// system voices ship with macOS). They are fast (~1s each on a warm system).
final class AVSpeechTTSServiceTests: XCTestCase {
    private var service: AVSpeechTTSService!

    override func setUp() {
        super.setUp()
        service = AVSpeechTTSService()
    }

    // MARK: - Voice enumeration

    func testAvailableVoicesNotEmpty() {
        XCTAssertFalse(service.availableVoices.isEmpty, "macOS must have at least one system voice")
    }

    func testDefaultVoiceInAvailableVoices() {
        XCTAssertTrue(
            service.availableVoices.contains(service.defaultVoice),
            "defaultVoice '\(service.defaultVoice)' must appear in availableVoices"
        )
    }

    func testAvailableVoicesAreSorted() {
        XCTAssertEqual(service.availableVoices, service.availableVoices.sorted())
    }

    // MARK: - Sample rate

    func testDefaultSampleRate() {
        XCTAssertEqual(service.sampleRate, 22_050)
    }

    func testCustomSampleRateFromSettings() {
        var settings = AVSpeechSettings()
        settings.sampleRate = 44_100
        let customService = AVSpeechTTSService(settings: settings)
        XCTAssertEqual(customService.sampleRate, 44_100)
    }

    // MARK: - Voice lookup via settings

    func testConfiguredDefaultVoice() {
        let firstName = AVSpeechSynthesisVoice.speechVoices().first?.name ?? "Samantha"
        var settings = AVSpeechSettings()
        settings.defaultVoice = firstName
        let svc = AVSpeechTTSService(settings: settings)
        XCTAssertEqual(svc.defaultVoice, firstName)
    }

    // MARK: - synthesize

    func testSynthesizeReturnsWAVData() async throws {
        let voice = service.defaultVoice
        let data = try await service.synthesize(text: "Hello.", voice: voice)
        // WAV starts with "RIFF"
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        // Must have at least the 44-byte header + some audio
        XCTAssertGreaterThan(data.count, 44)
    }

    func testSynthesizeContainsWAVEMarker() async throws {
        let data = try await service.synthesize(text: "Test.", voice: service.defaultVoice)
        XCTAssertEqual(data[8..<12], Data("WAVE".utf8))
    }

    func testSynthesizeInvalidVoiceThrows() async {
        do {
            _ = try await service.synthesize(
                text: "Hello.", voice: "this_voice_does_not_exist_xyz_abc")
            XCTFail("Expected voiceNotFound error")
        }
        catch let error as AVSpeechTTSError {
            if case .voiceNotFound = error {
                // expected
            }
            else {
                XCTFail("Unexpected AVSpeechTTSError: \(error)")
            }
        }
        catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSynthesizeSampleRateInWAVHeader() async throws {
        let data = try await service.synthesize(text: "Hello.", voice: service.defaultVoice)
        // Sample rate is at bytes 24-27 (LE UInt32) per RIFF/WAVE spec
        let rate = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(rate), service.sampleRate)
    }

    // MARK: - synthesizeStream

    func testSynthesizeStreamYieldsAtLeastOneChunk() async throws {
        let stream = service.synthesizeStream(text: "Hello world.", voice: service.defaultVoice)
        var chunkCount = 0
        for try await chunk in stream {
            XCTAssertFalse(chunk.isEmpty)
            chunkCount += 1
        }
        XCTAssertGreaterThan(chunkCount, 0, "synthesizeStream must yield at least one PCM chunk")
    }

    func testSynthesizeStreamChunksAreEvenLength() async throws {
        // 16-bit PCM must be an even number of bytes per chunk
        let stream = service.synthesizeStream(text: "Test sentence.", voice: service.defaultVoice)
        for try await chunk in stream {
            XCTAssertEqual(chunk.count % 2, 0, "Each PCM chunk must have an even byte count")
        }
    }

    func testSynthesizeStreamInvalidVoiceThrows() async {
        let stream = service.synthesizeStream(
            text: "Hello.", voice: "this_voice_does_not_exist_xyz_abc")
        do {
            for try await _ in stream {}
            XCTFail("Expected voiceNotFound error")
        }
        catch let error as AVSpeechTTSError {
            if case .voiceNotFound = error {
                // expected
            }
            else {
                XCTFail("Unexpected AVSpeechTTSError: \(error)")
            }
        }
        catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Voice lookup (short name and identifier)

    func testShortNameLookupIsCaseInsensitive() async throws {
        let firstName = service.availableVoices.first!
        // Lower-case should resolve
        let data = try await service.synthesize(text: "Hi.", voice: firstName.lowercased())
        XCTAssertGreaterThan(data.count, 44)
    }

    func testFullIdentifierLookup() async throws {
        // Use the first available voice's full identifier
        guard let avVoice = AVSpeechSynthesisVoice.speechVoices().first else {
            throw XCTSkip("No system voices available")
        }
        let data = try await service.synthesize(text: "Hi.", voice: avVoice.identifier)
        XCTAssertGreaterThan(data.count, 44)
    }
}
