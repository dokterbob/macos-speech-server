import XCTest
import Yams
@testable import speech_server

final class WyomingConfigTests: XCTestCase {

    func testDefaultWyomingPort() {
        let config = ServerConfig()
        XCTAssertEqual(config.wyoming.port, 10300)
    }

    func testWyomingPortSet() throws {
        let yaml = """
        wyoming:
          port: 10500
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.wyoming.port, 10500)
    }

    func testWyomingPortZeroDisabled() throws {
        let yaml = """
        wyoming:
          port: 0
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.wyoming.port, 0)
    }

    func testWyomingAbsentGivesDefault() throws {
        let yaml = "stt:\n  engine: parakeet"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.wyoming.port, 10300)
    }

    func testWyomingEmptyBlockGivesDefault() throws {
        let yaml = "wyoming: {}"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.wyoming.port, 10300)
    }

    func testFullConfigIncludingWyoming() throws {
        let yaml = """
        server:
          host: "0.0.0.0"
          port: 9090
        wyoming:
          port: 10300
        stt:
          engine: parakeet
        tts:
          engine: pocket_tts
        """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.server.host, "0.0.0.0")
        XCTAssertEqual(config.server.port, 9090)
        XCTAssertEqual(config.wyoming.port, 10300)
        XCTAssertEqual(config.stt.engine, .parakeet)
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }
}
