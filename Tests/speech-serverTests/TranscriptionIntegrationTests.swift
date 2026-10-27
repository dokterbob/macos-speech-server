import XCTVapor
import XCTest

@testable import speech_server

final class TranscriptionIntegrationTests: XCTestCase {
    var app: Application!
    private let boundary = "TestBoundary1234567890"

    override func setUp() async throws {
        app = try await sharedTestApp()
    }

    // MARK: - Fixture helpers

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "Fixture '\(name).\(ext)' not found in bundle"
        )
        return try Data(contentsOf: url)
    }

    private var fixtureWAV: Data { get throws { try fixture("test", "wav") } }

    private func transcriptionBody(
        file: Data,
        filename: String = "test.wav",
        fields: [(name: String, value: String)] = []
    ) -> Data {
        makeMultipartBody(boundary: boundary, file: file, filename: filename, fields: fields)
    }

    private func transcriptionHeaders() -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
        return headers
    }

    // MARK: - Success paths

    func testWAVTranscriptionJSON() async throws {
        let wav = try fixtureWAV
        let body = transcriptionBody(file: wav)

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoded = try res.content.decode(TranscriptionResponseJSON.self)
            XCTAssertFalse(decoded.text.isEmpty, "Transcription text should be non-empty")
        }
    }

    func testWAVTranscriptionText() async throws {
        let wav = try fixtureWAV
        let body = transcriptionBody(file: wav, fields: [(name: "response_format", value: "text")])

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.type, "text")
            let text = res.body.string
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Plain text response should be non-empty")
        }
    }

    func testWAVTranscriptionVerboseJSON() async throws {
        let wav = try fixtureWAV
        let body = transcriptionBody(file: wav, fields: [(name: "response_format", value: "verbose_json")])

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoded = try res.content.decode(TranscriptionResponseVerbose.self)
            XCTAssertEqual(decoded.task, "transcribe")
            XCTAssertFalse(decoded.text.isEmpty)
            XCTAssertGreaterThan(decoded.duration, 0)
            let segments = try XCTUnwrap(decoded.segments, "verbose_json should include segments")
            XCTAssertFalse(segments.isEmpty, "Should have at least one segment")
        }
    }

    func testVerboseJSONWithWordTimestamps() async throws {
        let wav = try fixtureWAV
        let body = transcriptionBody(
            file: wav,
            fields: [
                (name: "response_format", value: "verbose_json"),
                (name: "timestamp_granularities[]", value: "word"),
                (name: "timestamp_granularities[]", value: "segment"),
            ])

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoded = try res.content.decode(TranscriptionResponseVerbose.self)
            XCTAssertFalse(decoded.text.isEmpty)
            let words = try XCTUnwrap(decoded.words, "Should include words array when requested")
            XCTAssertFalse(words.isEmpty, "Words array should be non-empty")
        }
    }

    func testV1RouteWorks() async throws {
        let wav = try fixtureWAV
        let body = transcriptionBody(file: wav)

        try await app.test(
            .POST, "/v1/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoded = try res.content.decode(TranscriptionResponseJSON.self)
            XCTAssertFalse(decoded.text.isEmpty)
        }
    }

    // MARK: - Format coverage

    func testAIFFTranscription() async throws {
        let aiff = try fixture("test", "aiff")
        let body = transcriptionBody(file: aiff, filename: "test.aiff")

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoded = try res.content.decode(TranscriptionResponseJSON.self)
            XCTAssertFalse(decoded.text.isEmpty, "AIFF transcription should produce non-empty text")
        }
    }

    func testLongM4ATranscription() async throws {
        let m4a = try fixture("test_long", "m4a")
        let body = transcriptionBody(file: m4a, filename: "test_long.m4a")

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoded = try res.content.decode(TranscriptionResponseJSON.self)
            XCTAssertFalse(decoded.text.isEmpty, "Long M4A transcription should produce non-empty text")
        }
    }

    func testLongWAVTranscription() async throws {
        let wav = try fixture("test_long", "wav")
        let body = transcriptionBody(file: wav, filename: "test_long.wav")

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let verbose = try res.content.decode(TranscriptionResponseJSON.self)
            XCTAssertFalse(verbose.text.isEmpty, "Long WAV transcription should produce non-empty text")
        }
    }

    // MARK: - Error paths

    func testMissingFileField() async throws {
        // Multipart with only a model field, no "file" field
        let boundary2 = "NoBoundary999"
        var body = Data()
        let crlf = "\r\n"
        body += "--\(boundary2)\(crlf)".data(using: .utf8)!
        body += "Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)".data(using: .utf8)!
        body += "whisper-1\(crlf)".data(using: .utf8)!
        body += "--\(boundary2)--\(crlf)".data(using: .utf8)!

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary2)")

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: headers,
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertTrue(errorResp.error.message.contains("file"), "Error should mention 'file'")
        }
    }

    func testEmptyFileField() async throws {
        let body = transcriptionBody(file: Data())  // zero-byte file

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: transcriptionHeaders(),
            body: ByteBuffer(data: body)
        ) { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertFalse(errorResp.error.message.isEmpty)
        }
    }

    func testMissingBoundaryReturns400() async throws {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "multipart/form-data")  // no boundary param

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: headers,
            body: ByteBuffer(data: Data())
        ) { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertTrue(
                errorResp.error.message.lowercased().contains("boundary"),
                "Error should mention missing boundary")
        }
    }

    func testErrorResponseIsOpenAIShaped() async throws {
        // Any 4xx error should have the OpenAI error envelope
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "multipart/form-data")

        try await app.test(
            .POST, "/audio/transcriptions",
            headers: headers,
            body: ByteBuffer(data: Data())
        ) { res async throws in
            XCTAssertGreaterThanOrEqual(res.status.code, 400)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertFalse(errorResp.error.message.isEmpty)
            XCTAssertFalse(errorResp.error.type.isEmpty)
        }
    }
}

// MARK: - ByteBuffer convenience

extension ByteBuffer {
    fileprivate var string: String {
        var copy = self
        return copy.readString(length: copy.readableBytes) ?? ""
    }
}
