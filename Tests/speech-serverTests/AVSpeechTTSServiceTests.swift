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
        guard let firstName = service.availableVoices.first else {
            throw XCTSkip("No system voices available")
        }
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

    // MARK: - Language reporting

    func testLanguageForKnownVoice() throws {
        // Every system voice must have a language code that is non-empty
        // and conforms to a locale pattern (e.g. "de-DE", "en-US", "it-IT").
        XCTAssertFalse(service.availableVoices.isEmpty)

        for voiceName in service.availableVoices {
            let lang = service.language(for: voiceName)
            XCTAssertFalse(lang.isEmpty, "Voice '\(voiceName)' must have a non-empty language code")
            // Expect pattern like "de-DE" or "en-US" — at least contains a hyphen
            XCTAssertTrue(
                lang.contains("-"),
                "Voice '\(voiceName)' language '\(lang)' should be a locale code (e.g. 'de-DE')"
            )
        }
    }

    func testLanguageForCaseInsensitiveLookup() throws {
        guard let firstVoice = service.availableVoices.first else {
            throw XCTSkip("No system voices available")
        }
        let lower = service.language(for: firstVoice.lowercased())
        let upper = service.language(for: firstVoice.uppercased())
        XCTAssertEqual(lower, upper, "Language lookup must be case-insensitive")
    }

    /// REGRESSION TEST: on main (before this patch) every voice returned "en".
    /// This test verifies that non-English voices now report their actual locale.
    /// Some voices (Eddy, Sandy, etc.) appear once per locale with the same name;
    /// the reported language may be any of the locales offered for that name, but
    /// never the bare "en" fallback (which would mean the lookup failed).
    func testNonEnglishVoicesReportCorrectLanguage() throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()

        try XCTSkipIf(
            voices.isEmpty,
            "No system voices available"
        )

        // Check deduplicated voice names have non-English language codes
        var seenNames: Set<String> = []
        for avVoice in voices where seenNames.insert(avVoice.name).inserted {
            let lang = service.language(for: avVoice.name)
            XCTAssertTrue(
                !lang.isEmpty && lang != "en",
                "Voice '\(avVoice.name)' should report a locale like 'de-DE', got '\(lang)'"
            )
            XCTAssertTrue(
                lang.contains("-"),
                "Voice '\(avVoice.name)' language '\(lang)' should be a locale code (e.g. 'de-DE')"
            )
        }
    }

    /// REGRESSION TEST: language(for:) must report the locale of the voice that
    /// synthesis actually resolves. Identifiers are unique, so passing an
    /// identifier must return exactly that voice's locale.
    func testLanguageMatchesVoiceForUniqueIdentifiers() throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        try XCTSkipIf(voices.isEmpty, "No system voices available")

        for voice in voices {
            XCTAssertEqual(
                service.language(for: voice.identifier), voice.language,
                "language(for: identifier) must return the exact locale of that voice"
            )
        }
    }

    /// REGRESSION TEST: names can exist in several locales (Eddy, Sandy, …).
    /// languages(for:) must expose every locale that exists for the name, so a
    /// multi-locale voice never advertises just one arbitrary language.
    func testLanguagesForNameIncludeEveryLocale() throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        try XCTSkipIf(voices.isEmpty, "No system voices available")

        var seen: Set<String> = []
        for voice in voices where seen.insert(voice.name).inserted {
            let langs = service.languages(for: voice.name)
            XCTAssertTrue(
                langs.contains(voice.language),
                "languages(for: '\(voice.name)') must include '\(voice.language)', got \(langs)"
            )
            XCTAssertTrue(
                langs.contains(service.language(for: voice.name)),
                "language(for:) result must be one of languages(for:) for '\(voice.name)'"
            )
        }
    }

    // MARK: - Synthesize with language

    func testSynthesizeWithGermanVoiceUsesCorrectLanguage() async throws {
        // Find a German voice (deduplicated by name)
        var seenNames: Set<String> = []
        let germanVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de-") && seenNames.insert($0.name).inserted }

        try XCTSkipIf(germanVoices.isEmpty, "No German system voice available")

        guard let germanVoice = germanVoices.first else {
            XCTFail("No German voice found after skip")
            return
        }
        // Identifier path is unique: must report exactly the German locale.
        XCTAssertEqual(
            service.language(for: germanVoice.identifier), germanVoice.language,
            "German voice identifier must report its exact de-* locale"
        )
        // Name path may resolve any of the name's locales, but it must be one
        // of them and never the bare "en" fallback.
        let nameLang = service.language(for: germanVoice.name)
        XCTAssertTrue(
            service.languages(for: germanVoice.name).contains(nameLang),
            "language(for: name) must be one of the name's locales, got '\(nameLang)'"
        )
        XCTAssertNotEqual(
            nameLang, "en",
            "language(for: '\(germanVoice.name)') must not fall back to 'en' — the name exists in the voice list"
        )
    }
}
