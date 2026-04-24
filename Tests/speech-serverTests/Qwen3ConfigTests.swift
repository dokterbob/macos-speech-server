import XCTest
import Yams

@testable import speech_server

final class Qwen3ConfigTests: XCTestCase {
    // MARK: - Engine parsing

    func testDefaultEngineIsParakeet() {
        let config = ServerConfig()
        XCTAssertEqual(config.stt.engine, .parakeet)
    }

    func testParseQwen3Engine() throws {
        let yaml = "stt:\n  engine: qwen3\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.engine, .qwen3)
    }

    func testParakeetEngineStillParses() throws {
        let yaml = "stt:\n  engine: parakeet\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.engine, .parakeet)
    }

    // MARK: - Qwen3STTSettings defaults

    func testQwen3DefaultSettings() {
        let settings = Qwen3STTSettings()
        XCTAssertEqual(settings.variant, "int8")
        XCTAssertNil(settings.language)
    }

    func testDefaultConfigHasNoQwen3Block() {
        let config = ServerConfig()
        XCTAssertNil(config.stt.qwen3)
    }

    // MARK: - Qwen3STTSettings YAML parsing

    func testParseQwen3WithCustomVariant() throws {
        let yaml = """
            stt:
              engine: qwen3
              qwen3:
                variant: f32
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.engine, .qwen3)
        XCTAssertEqual(config.stt.qwen3?.variant, "f32")
        XCTAssertNil(config.stt.qwen3?.language)
    }

    func testParseQwen3WithLanguage() throws {
        let yaml = """
            stt:
              engine: qwen3
              qwen3:
                language: en
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.qwen3?.language, "en")
        XCTAssertEqual(config.stt.qwen3?.variant, "int8")
    }

    func testParseQwen3WithAllSettings() throws {
        let yaml = """
            stt:
              engine: qwen3
              qwen3:
                variant: f32
                language: fr
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.qwen3?.variant, "f32")
        XCTAssertEqual(config.stt.qwen3?.language, "fr")
    }

    func testMinimalQwen3ConfigUsesDefaults() throws {
        let yaml = "stt:\n  engine: qwen3\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        let settings = config.stt.qwen3 ?? Qwen3STTSettings()
        XCTAssertEqual(settings.variant, "int8")
        XCTAssertNil(settings.language)
    }

    func testEmptyQwen3BlockUsesDefaults() throws {
        let yaml = """
            stt:
              engine: qwen3
              qwen3: {}
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        let settings = config.stt.qwen3 ?? Qwen3STTSettings()
        XCTAssertEqual(settings.variant, "int8")
        XCTAssertNil(settings.language)
    }

    // MARK: - Coexistence with Parakeet

    func testParakeetBlockUnaffected() throws {
        let yaml = """
            stt:
              engine: parakeet
              parakeet:
                model_version: v2
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.stt.engine, .parakeet)
        XCTAssertEqual(config.stt.parakeet?.modelVersion, "v2")
        XCTAssertNil(config.stt.qwen3)
    }
}
