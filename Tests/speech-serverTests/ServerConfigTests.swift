import XCTest
import Yams
@testable import speech_server

final class ServerConfigTests: XCTestCase {

    // MARK: - Default values

    func testDefaultConfig() {
        let config = ServerConfig()
        XCTAssertEqual(config.server.host, "127.0.0.1")
        XCTAssertEqual(config.server.port, 8080)
        XCTAssertEqual(config.server.logLevel, "notice")
        XCTAssertEqual(config.server.uploadLimitMB, 500)
        XCTAssertEqual(config.stt.engine, .parakeet)
        XCTAssertNil(config.stt.parakeet)
        XCTAssertEqual(config.tts.engine, .pocketTts)
        XCTAssertNil(config.tts.pocketTts)
    }

    func testPocketTtsDefaultSettings() {
        let settings = PocketTtsSettings()
        XCTAssertTrue(settings.sanitizeEmoji)
    }

    func testPocketTtsSanitizeEmojiDisabled() throws {
        let yaml = """
        tts:
          engine: pocket_tts
          pocket_tts:
            sanitize_emoji: false
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.pocketTts?.sanitizeEmoji, false)
    }

    func testPocketTtsSanitizeEmojiExplicitTrue() throws {
        let yaml = """
        tts:
          engine: pocket_tts
          pocket_tts:
            sanitize_emoji: true
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.pocketTts?.sanitizeEmoji, true)
    }

    func testPocketTtsEmptyBlockGivesDefaultSanitizeEmoji() throws {
        let yaml = """
        tts:
          engine: pocket_tts
          pocket_tts: {}
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.pocketTts?.sanitizeEmoji, true)
    }

    func testPocketTtsBlockAbsentGivesNilSettings() throws {
        let yaml = "tts:\n  engine: pocket_tts"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertNil(config.tts.pocketTts)
    }

    // MARK: - YAML parsing

    func testFullYAMLRoundTrip() throws {
        let yaml = """
        server:
          host: "0.0.0.0"
          port: 9090
          log_level: debug
          upload_limit_mb: 100
        stt:
          engine: parakeet
          parakeet:
            model_version: v2
        tts:
          engine: pocket_tts
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.server.host, "0.0.0.0")
        XCTAssertEqual(config.server.port, 9090)
        XCTAssertEqual(config.server.logLevel, "debug")
        XCTAssertEqual(config.server.uploadLimitMB, 100)
        XCTAssertEqual(config.stt.engine, .parakeet)
        XCTAssertEqual(config.stt.parakeet?.modelVersion, "v2")
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }

    func testPartialYAMLEngineOnly() throws {
        let yaml = "stt:\n  engine: parakeet"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.engine, .parakeet)
        // All other fields fall back to defaults
        XCTAssertEqual(config.server.host, "127.0.0.1")
        XCTAssertEqual(config.server.port, 8080)
        XCTAssertEqual(config.server.uploadLimitMB, 500)
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }

    func testParakeetV2ModelVersion() throws {
        let yaml = """
        stt:
          engine: parakeet
          parakeet:
            model_version: v2
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.parakeet?.modelVersion, "v2")
    }

    func testDefaultModelVersionWhenParakeetBlockPresent() throws {
        let yaml = """
        stt:
          engine: parakeet
          parakeet: {}
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.parakeet?.modelVersion, "v3")
    }

    func testDefaultModelVersionWhenParakeetBlockAbsent() throws {
        let yaml = "stt:\n  engine: parakeet"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        // parakeet block absent → settings is nil; caller uses "v3" as default
        XCTAssertNil(config.stt.parakeet)
    }

    func testEmptyYAMLProducesAllDefaults() throws {
        let config = try YAMLDecoder().decode(ServerConfig.self, from: "{}")
        XCTAssertEqual(config.server.host, "127.0.0.1")
        XCTAssertEqual(config.server.port, 8080)
        XCTAssertEqual(config.server.logLevel, "notice")
        XCTAssertEqual(config.server.uploadLimitMB, 500)
        XCTAssertEqual(config.stt.engine, .parakeet)
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }

    func testServerSubsectionOnly() throws {
        let yaml = """
        server:
          port: 1234
          host: "0.0.0.0"
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.server.port, 1234)
        XCTAssertEqual(config.server.host, "0.0.0.0")
        XCTAssertEqual(config.server.logLevel, "notice")     // default
        XCTAssertEqual(config.server.uploadLimitMB, 500)     // default
        XCTAssertEqual(config.stt.engine, .parakeet)         // default
    }
}
