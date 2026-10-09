import XCTVapor
import XCTest

@testable import speech_server

final class DiarizationControllerTests: XCTestCase {
    func testDefaultAndFalsePreserveJSONShapeWithoutLoadingDiarizer() async throws {
        for fields: [(name: String, value: String)] in [[], [("diarize", "false")]] {
            try await check(fields: fields) { response, calls in
                XCTAssertEqual(response.status, .ok)
                let json =
                    try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                XCTAssertEqual(json?.count, 1)
                XCTAssertEqual(json?["text"] as? String, "Hello. Hi.")
                XCTAssertEqual(calls, 0)
            }
        }
    }

    func testDiarizedJSONAndVerboseHaveSpeakerSegmentsOnBothRoutes() async throws {
        for path in ["/audio/transcriptions", "/v1/audio/transcriptions"] {
            for format in ["json", "verbose_json"] {
                try await check(
                    path: path,
                    fields: [("diarize", "true"), ("response_format", format), ("timestamp_granularities[]", "word")]
                ) { response, calls in
                    XCTAssertEqual(response.status, .ok)
                    let json = try response.content.decode(TranscriptionResponseJSON.self)
                    XCTAssertEqual(json.text, "Hello. Hi.")
                    let segments = try XCTUnwrap(json.segments)
                    XCTAssertEqual(segments.compactMap(\.speaker), ["speaker_0", "speaker_1"])
                    XCTAssertEqual(segments.map(\.text), ["Hello.", "Hi."])
                    XCTAssertEqual(segments.map(\.start), [0.1, 2.1])
                    XCTAssertEqual(segments.map(\.end), [1, 3])
                    XCTAssertEqual(segments.map(\.id), [0, 1])
                    XCTAssertEqual(calls, 1)
                }
            }
        }
    }

    func testInvalidBooleanAndTextFormatReturnOpenAIErrorsWithoutDiarization() async throws {
        for fields: [(name: String, value: String)] in [
            [("diarize", "yes")], [("diarize", "true"), ("response_format", "text")],
        ] {
            try await check(fields: fields) { response, calls in
                XCTAssertEqual(response.status, .badRequest)
                let error = try response.content.decode(OpenAIErrorResponse.self)
                XCTAssertTrue(error.error.message.contains("diarize"))
                XCTAssertEqual(calls, 0)
            }
        }
    }

    func testDiarizationFailureUsesExistingErrorEnvelope() async throws {
        try await check(fields: [("diarize", "true")], fail: true) { response, calls in
            XCTAssertEqual(response.status, .internalServerError)
            let error = try response.content.decode(OpenAIErrorResponse.self)
            XCTAssertEqual(error.error.type, "server_error")
            XCTAssertEqual(calls, 1)
        }
    }

    func testQwenStyleSegmentsKeepTextAndTimingWithoutWordTimestamps() async throws {
        try await check(fields: [("diarize", "true")], wordTimestamps: false) { response, calls in
            XCTAssertEqual(response.status, .ok)
            let json = try response.content.decode(TranscriptionResponseJSON.self)
            let segments = try XCTUnwrap(json.segments)
            XCTAssertEqual(segments.count, 1)
            XCTAssertEqual(segments.first?.speaker, "speaker_0")
            XCTAssertEqual(segments.first?.text, "Hello. Hi.")
            XCTAssertEqual(segments.first?.start, 0)
            XCTAssertEqual(segments.first?.end, 4)
            XCTAssertEqual(calls, 1)
        }
    }

    func testDisabledVerboseWordOnlyKeepsOriginalGranularity() async throws {
        try await check(fields: [("response_format", "verbose_json"), ("timestamp_granularities[]", "word")]) {
            response, calls in
            let verbose = try response.content.decode(TranscriptionResponseVerbose.self)
            XCTAssertNil(verbose.segments)
            XCTAssertEqual(verbose.words?.count, 2)
            XCTAssertEqual(calls, 0)
        }
    }

    func testSilenceDoesNotLoadDiarizationModels() async throws {
        try await check(fields: [("diarize", "true")], silent: true) { response, calls in
            XCTAssertEqual(response.status, .ok)
            let json = try response.content.decode(TranscriptionResponseJSON.self)
            XCTAssertEqual(json.text, "")
            XCTAssertEqual(json.segments?.count, 0)
            XCTAssertEqual(calls, 0)
        }
    }

    private func check(
        path: String = "/v1/audio/transcriptions",
        fields: [(name: String, value: String)], fail: Bool = false, silent: Bool = false,
        wordTimestamps: Bool = true,
        verify: (XCTHTTPResponse, Int) throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            app.serverConfig = ServerConfig()
            app.sttService = TimedSTTMock(silent: silent, wordTimestamps: wordTimestamps)
            let diarizer = CountingDiarizer(fail: fail)
            app.diarizationService = diarizer
            app.middleware.use(OpenAIErrorMiddleware())
            try routes(app)
            let boundary = "DiarizationTestBoundary"
            let body = makeMultipartBody(
                boundary: boundary, file: Data([1, 2, 3]), filename: "test.wav", fields: fields)
            var headers = HTTPHeaders()
            headers.contentType = .init(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
            try await app.test(.POST, path, headers: headers, body: ByteBuffer(data: body)) { response async throws in
                let calls = await diarizer.calls
                try verify(response, calls)
            }
        }
        catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

private struct TimedSTTMock: STTService {
    let silent: Bool
    let wordTimestamps: Bool
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        if silent { return TranscriptionResult(text: "", duration: 4, words: [], segments: []) }
        let words: [WordTiming] =
            wordTimestamps
            ? [
                WordTiming(word: "Hello.", start: 0.1, end: 1),
                WordTiming(word: "Hi.", start: 2.1, end: 3),
            ] : []
        return TranscriptionResult(
            text: "Hello. Hi.", duration: 4, words: words,
            segments: [SegmentResult(text: "Hello. Hi.", start: 0, end: 4, words: words, confidence: 1)])
    }
}

private actor CountingDiarizer: DiarizationService {
    var calls = 0
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    func diarize(audioURL: URL) async throws -> [SpeakerTurn] {
        calls += 1
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        if fail { throw MockServiceError.failed }
        return [
            SpeakerTurn(speaker: "speaker_0", start: 0, end: 2),
            SpeakerTurn(speaker: "speaker_1", start: 2, end: 4),
        ]
    }
}
