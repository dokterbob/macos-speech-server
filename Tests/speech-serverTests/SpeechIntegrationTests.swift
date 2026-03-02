import XCTVapor
import XCTest

@testable import speech_server

final class SpeechIntegrationTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await sharedTestApp()
    }

    override func tearDown() async throws {}

    // MARK: - Request helpers

    private func postSpeech(
        input: String,
        voice: String? = nil,
        responseFormat: String? = nil,
        speed: Double? = nil,
        afterResponse: (XCTHTTPResponse) async throws -> Void = { _ in }
    ) async throws {
        var bodyDict: [String: Any] = ["model": "tts-1", "input": input]
        if let voice { bodyDict["voice"] = voice }
        if let responseFormat { bodyDict["response_format"] = responseFormat }
        if let speed { bodyDict["speed"] = speed }

        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)

        try await app.test(
            .POST, "/audio/speech",
            beforeRequest: { req in
                req.headers.replaceOrAdd(name: .contentType, value: "application/json")
                req.body = ByteBuffer(data: bodyData)
            },
            afterResponse: afterResponse
        )
    }

    // MARK: - Success paths

    func testSynthesizeWAV() async throws {
        try await postSpeech(input: "Hello, world.") { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.type, "audio")
            XCTAssertEqual(res.headers.contentType?.subType, "wav")

            var body = res.body
            let bytes = body.readBytes(length: body.readableBytes) ?? []
            XCTAssertGreaterThanOrEqual(bytes.count, 12, "WAV response must have at least 12 bytes")
            XCTAssertEqual(Array(bytes[0..<4]), [0x52, 0x49, 0x46, 0x46], "Should start with RIFF")
            XCTAssertEqual(Array(bytes[8..<12]), [0x57, 0x41, 0x56, 0x45], "Should contain WAVE marker")
        }
    }

    func testSynthesizePCM() async throws {
        try await postSpeech(input: "Hello.", responseFormat: "pcm") { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.type, "audio")
            XCTAssertEqual(res.headers.contentType?.subType, "pcm")
            XCTAssertGreaterThan(res.body.readableBytes, 0, "PCM response body should be non-empty")
        }
    }

    func testV1RouteWorks() async throws {
        let bodyData = try JSONSerialization.data(withJSONObject: ["model": "tts-1", "input": "Hi there."])
        try await app.test(
            .POST, "/v1/audio/speech",
            beforeRequest: { req in
                req.headers.replaceOrAdd(name: .contentType, value: "application/json")
                req.body = ByteBuffer(data: bodyData)
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            }
        )
    }

    // MARK: - Validation errors (400)

    func testEmptyInputReturns400() async throws {
        try await postSpeech(input: "") { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertTrue(errorResp.error.message.lowercased().contains("input"))
        }
    }

    func testInputTooLongReturns400() async throws {
        let longInput = String(repeating: "a", count: 4097)
        try await postSpeech(input: longInput) { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertTrue(errorResp.error.message.lowercased().contains("4096"))
        }
    }

    func testInvalidSpeedTooSlowReturns400() async throws {
        try await postSpeech(input: "Hello.", speed: 0.1) { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertTrue(errorResp.error.message.lowercased().contains("speed"))
        }
    }

    func testInvalidSpeedTooFastReturns400() async throws {
        try await postSpeech(input: "Hello.", speed: 5.0) { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertTrue(errorResp.error.message.lowercased().contains("speed"))
        }
    }

    func testInvalidFormatReturns400() async throws {
        try await postSpeech(input: "Hello.", responseFormat: "mp3") { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertTrue(errorResp.error.message.lowercased().contains("response_format"))
        }
    }

    func testInvalidVoiceReturns400() async throws {
        try await postSpeech(input: "Hello.", voice: "nova") { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertTrue(
                errorResp.error.message.lowercased().contains("nova")
                    || errorResp.error.message.lowercased().contains("voice"),
                "Error message should mention the invalid voice or 'voice' field"
            )
        }
    }

    func testErrorResponseIsOpenAIShaped() async throws {
        try await postSpeech(input: "") { res async throws in
            XCTAssertGreaterThanOrEqual(res.status.code, 400)
            let errorResp = try res.content.decode(OpenAIErrorResponse.self)
            XCTAssertFalse(errorResp.error.message.isEmpty)
            XCTAssertEqual(errorResp.error.type, "invalid_request_error")
            XCTAssertNil(errorResp.error.param)
            XCTAssertNil(errorResp.error.code)
        }
    }
}
