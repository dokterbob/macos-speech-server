import XCTest
import Yams

@testable import speech_server

final class AVSpeechConfigTests: XCTestCase {
    // MARK: - Engine parsing

    func testDefaultEngineIsPocketTTS() {
        let config = ServerConfig()
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }

    func testParseAVSpeechEngine() throws {
        let yaml = "tts:\n  engine: avspeech\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .avspeech)
    }

    func testPocketTTSEngineStillParses() throws {
        let yaml = "tts:\n  engine: pocket_tts\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }

    // MARK: - AVSpeechSettings defaults

    func testAVSpeechDefaultSettings() {
        let settings = AVSpeechSettings()
        XCTAssertNil(settings.defaultVoice)
        XCTAssertEqual(settings.sampleRate, 22_050)
    }

    func testDefaultConfigHasNoAVSpeechBlock() {
        let config = ServerConfig()
        XCTAssertNil(config.tts.avspeech)
    }

    // MARK: - AVSpeechSettings YAML parsing

    func testParseAVSpeechWithCustomVoice() throws {
        let yaml = """
            tts:
              engine: avspeech
              avspeech:
                default_voice: Samantha
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .avspeech)
        XCTAssertEqual(config.tts.avspeech?.defaultVoice, "Samantha")
    }

    func testParseAVSpeechWithCustomSampleRate() throws {
        let yaml = """
            tts:
              engine: avspeech
              avspeech:
                sample_rate: 44100
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.avspeech?.sampleRate, 44_100)
    }

    func testParseAVSpeechWithBothFields() throws {
        let yaml = """
            tts:
              engine: avspeech
              avspeech:
                default_voice: Daniel
                sample_rate: 22050
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.avspeech?.defaultVoice, "Daniel")
        XCTAssertEqual(config.tts.avspeech?.sampleRate, 22_050)
    }

    func testMinimalAVSpeechConfigUsesDefaults() throws {
        let yaml = "tts:\n  engine: avspeech\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        let settings = config.tts.avspeech ?? AVSpeechSettings()
        XCTAssertNil(settings.defaultVoice)
        XCTAssertEqual(settings.sampleRate, 22_050)
    }

    func testEmptyAVSpeechBlockUsesDefaults() throws {
        let yaml = """
            tts:
              engine: avspeech
              avspeech: {}
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        let settings = config.tts.avspeech ?? AVSpeechSettings()
        XCTAssertNil(settings.defaultVoice)
        XCTAssertEqual(settings.sampleRate, 22_050)
    }

    // MARK: - Coexistence with other engines

    func testPocketTTSBlockUnaffected() throws {
        let yaml = """
            tts:
              engine: pocket_tts
              pocket_tts:
                sanitize_emoji: false
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .pocketTts)
        XCTAssertEqual(config.tts.pocketTts?.sanitizeEmoji, false)
        XCTAssertNil(config.tts.avspeech)
    }
}
