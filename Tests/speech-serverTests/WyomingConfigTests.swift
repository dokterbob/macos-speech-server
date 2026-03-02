import XCTest
import Yams

@testable import speech_server

final class WyomingConfigTests: XCTestCase {
    func testDefaultWyomingPort() {
        let config = ServerConfig()
        XCTAssertEqual(config.servers.wyoming.port, 10300)
    }

    func testDefaultWyomingHost() {
        let config = ServerConfig()
        XCTAssertEqual(config.servers.wyoming.host, "127.0.0.1")
    }

    func testWyomingPortSet() throws {
        let yaml = """
            servers:
              wyoming:
                port: 10500
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.servers.wyoming.port, 10500)
    }

    func testWyomingHostSet() throws {
        let yaml = """
            servers:
              wyoming:
                host: "0.0.0.0"
                port: 10300
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.servers.wyoming.host, "0.0.0.0")
        XCTAssertEqual(config.servers.wyoming.port, 10300)
    }

    func testWyomingPortZeroDisabled() throws {
        let yaml = """
            servers:
              wyoming:
                port: 0
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.servers.wyoming.port, 0)
    }

    func testWyomingAbsentGivesDefault() throws {
        let yaml = "stt:\n  engine: parakeet"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.servers.wyoming.port, 10300)
        XCTAssertEqual(config.servers.wyoming.host, "127.0.0.1")
    }

    func testWyomingEmptyBlockGivesDefault() throws {
        let yaml = """
            servers:
              wyoming: {}
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.servers.wyoming.port, 10300)
        XCTAssertEqual(config.servers.wyoming.host, "127.0.0.1")
    }

    func testFullConfigIncludingWyoming() throws {
        let yaml = """
            servers:
              http:
                host: "0.0.0.0"
                port: 9090
              wyoming:
                host: "0.0.0.0"
                port: 10300
            stt:
              engine: parakeet
            tts:
              engine: pocket_tts
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.servers.http.host, "0.0.0.0")
        XCTAssertEqual(config.servers.http.port, 9090)
        XCTAssertEqual(config.servers.wyoming.host, "0.0.0.0")
        XCTAssertEqual(config.servers.wyoming.port, 10300)
        XCTAssertEqual(config.stt.engine, .parakeet)
        XCTAssertEqual(config.tts.engine, .pocketTts)
    }
}
