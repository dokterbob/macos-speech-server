import XCTest
import Yams

@testable import speech_server

final class KokoroConfigTests: XCTestCase {
    // MARK: - Engine parsing

    func testDefaultEngineIsPocketTTS() {
        let config = ServerConfig()
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }

    func testParseKokoroEngine() throws {
        let yaml = "tts:\n  engine: kokoro\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .kokoro)
    }

    func testPocketTTSEngineStillParses() throws {
        let yaml = "tts:\n  engine: pocket_tts\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }

    func testAVSpeechEngineStillParses() throws {
        let yaml = "tts:\n  engine: avspeech\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .avspeech)
    }

    // MARK: - KokoroSettings defaults

    func testKokoroDefaultSettings() {
        let settings = KokoroSettings()
        XCTAssertNil(settings.defaultVoice)
    }

    func testDefaultConfigHasNoKokoroBlock() {
        let config = ServerConfig()
        XCTAssertNil(config.tts.kokoro)
    }

    // MARK: - KokoroSettings YAML parsing

    func testParseKokoroWithCustomVoice() throws {
        let yaml = """
            tts:
              engine: kokoro
              kokoro:
                default_voice: am_adam
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .kokoro)
        XCTAssertEqual(config.tts.kokoro?.defaultVoice, "am_adam")
    }

    func testMinimalKokoroConfigUsesDefaults() throws {
        let yaml = "tts:\n  engine: kokoro\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        let settings = config.tts.kokoro ?? KokoroSettings()
        XCTAssertNil(settings.defaultVoice)
    }

    func testEmptyKokoroBlockUsesDefaults() throws {
        let yaml = """
            tts:
              engine: kokoro
              kokoro: {}
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        let settings = config.tts.kokoro ?? KokoroSettings()
        XCTAssertNil(settings.defaultVoice)
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
        XCTAssertNil(config.tts.kokoro)
    }

    func testAVSpeechBlockUnaffected() throws {
        let yaml = """
            tts:
              engine: avspeech
              avspeech:
                default_voice: Samantha
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .avspeech)
        XCTAssertEqual(config.tts.avspeech?.defaultVoice, "Samantha")
        XCTAssertNil(config.tts.kokoro)
    }
}
