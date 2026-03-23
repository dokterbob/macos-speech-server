import XCTest

@testable import speech_server

/// Tests for KokoroTTSService.
///
/// These tests exercise the real KokoroTtsManager from FluidAudio.
/// Model download is required on first run and cached after that.
final class KokoroTTSServiceTests: XCTestCase {
    // nonisolated(unsafe): initialization is serialized via DispatchSemaphore in setUp.
    nonisolated(unsafe) private static var sharedService: KokoroTTSService?

    override class func setUp() {
        super.setUp()
        // Initialize once per test class run to avoid repeated model downloads.
        let service = KokoroTTSService()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                try await service.initialize()
                sharedService = service
            }
            catch {
                // Service stays nil; tests that need it will fail with a clear message.
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    private var service: KokoroTTSService {
        guard let s = Self.sharedService else {
            XCTFail("KokoroTTSService failed to initialize — model download may have failed")
            return KokoroTTSService()
        }
        return s
    }

    // MARK: - Voice enumeration

    func testAvailableVoicesNotEmpty() {
        XCTAssertFalse(service.availableVoices.isEmpty)
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

    func testSampleRateIs24000() {
        XCTAssertEqual(service.sampleRate, 24_000)
    }

    // MARK: - Default voice

    func testDefaultVoiceIsAfHeart() {
        let defaultService = KokoroTTSService()
        XCTAssertEqual(defaultService.defaultVoice, "af_heart")
    }

    func testCustomDefaultVoiceFromSettings() async throws {
        var settings = KokoroSettings()
        settings.defaultVoice = "am_adam"
        let customService = KokoroTTSService()
        try await customService.initialize(settings: settings)
        XCTAssertEqual(customService.defaultVoice, "am_adam")
    }

    // MARK: - synthesize

    func testSynthesizeReturnsWAVData() async throws {
        let data = try await service.synthesize(text: "Hello.", voice: service.defaultVoice)
        // WAV starts with "RIFF"
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        // Must have at least the 44-byte header + some audio
        XCTAssertGreaterThan(data.count, 44)
    }

    func testSynthesizeInvalidVoiceThrows() async {
        do {
            _ = try await service.synthesize(
                text: "Hello.", voice: "this_voice_does_not_exist_xyz_abc")
            XCTFail("Expected voiceNotFound error")
        }
        catch let error as KokoroTTSError {
            if case .voiceNotFound = error {
                // expected
            }
            else {
                XCTFail("Unexpected KokoroTTSError: \(error)")
            }
        }
        catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - synthesizeStream

    func testSynthesizeStreamYieldsChunks() async throws {
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
        catch let error as KokoroTTSError {
            if case .voiceNotFound = error {
                // expected
            }
            else {
                XCTFail("Unexpected KokoroTTSError: \(error)")
            }
        }
        catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
