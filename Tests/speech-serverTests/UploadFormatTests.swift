import XCTVapor
import XCTest

@testable import speech_server

/// Every format Core Audio decodes must reach the STT service decodable, whatever filename the client sends: the
/// format is detected from the file's content, never from its name. Uses `DecodingSTTService`, so no model loads.
final class UploadFormatTests: XCTestCase {
    private var app: Application!
    private let boundary = "UploadFormatBoundary"

    /// The fixtures in `Fixtures/formats`: the same 0.5 s clip in each format (ADTS AAC decodes ~0.14 s longer: it
    /// carries no length, so encoder padding stays in).
    private let fixtures = [
        "voice.wav", "voice.mp3", "voice-id3.mp3", "voice.m4a", "voice.aac", "voice.flac", "voice.aiff",
        "voice.aifc", "voice.ogg",
    ]

    private struct Verbose: Content {
        let duration: Double
    }

    override func setUp() async throws {
        app = try await Application.make(.testing)
        app.serverConfig = ServerConfig()
        app.middleware.use(OpenAIErrorMiddleware())
        app.sttService = DecodingSTTService()
        try app.register(collection: TranscriptionController())
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    func testEachFormatDecodesWithItsOwnExtension() async throws {
        for name in fixtures {
            try await assertDecodes(name, uploadedAs: name)
        }
    }

    func testExtensionCaseDoesNotMatter() async throws {
        for name in fixtures {
            try await assertDecodes(name, uploadedAs: name.uppercased())
        }
    }

    func testEachFormatDecodesUnderEveryOtherFormatsExtension() async throws {
        let extensions = Set(fixtures.map { ($0 as NSString).pathExtension })
        for name in fixtures {
            let own = (name as NSString).pathExtension
            for wrong in extensions.subtracting([own]).sorted() {
                try await assertDecodes(name, uploadedAs: "voice.\(wrong)")
            }
        }
    }

    func testEachFormatDecodesWithoutAnExtension() async throws {
        for name in fixtures {
            try await assertDecodes(name, uploadedAs: "upload")
        }
    }

    func testUndecodableContentIsRejected() async throws {
        let garbage = Data((0..<64).map { UInt8($0) })
        for filename in ["upload", "upload.wav"] {
            try await app.test(.POST, "/audio/transcriptions", headers: headers(), body: body(garbage, filename)) {
                response async throws in
                XCTAssertNotEqual(response.status, .ok, "garbage uploaded as \(filename)")
            }
        }
    }

    // MARK: - Helpers

    private func assertDecodes(_ fixture: String, uploadedAs filename: String) async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: fixture, withExtension: nil, subdirectory: "Fixtures/formats"),
            "Fixture '\(fixture)' not found in bundle")
        let fields = [(name: "response_format", value: "verbose_json")]
        try await app.test(
            .POST, "/audio/transcriptions", headers: headers(),
            body: body(try Data(contentsOf: url), filename, fields: fields)
        ) { response async throws in
            XCTAssertEqual(response.status, .ok, "\(fixture) uploaded as \(filename)")
            guard response.status == .ok else { return }
            let duration = try response.content.decode(Verbose.self).duration
            XCTAssertEqual(duration, 0.5, accuracy: 0.15, "\(fixture) uploaded as \(filename)")
        }
    }

    private func body(_ file: Data, _ filename: String, fields: [(name: String, value: String)] = []) -> ByteBuffer {
        ByteBuffer(data: makeMultipartBody(boundary: boundary, file: file, filename: filename, fields: fields))
    }

    private func headers() -> HTTPHeaders {
        ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
    }
}
