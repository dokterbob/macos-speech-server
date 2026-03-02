import XCTVapor
import XCTest

@testable import speech_server

/// TTS → STT round-trip: synthesize text, then transcribe the resulting audio
/// and verify the transcription resembles the original input.
///
/// This exercises multi-sentence TTS chunking (PocketTTS sentence boundaries)
/// and multi-segment STT (VAD splitting of longer audio).
final class RoundTripIntegrationTests: XCTestCase {
    var app: Application!
    private let boundary = "RoundTripBoundary42"

    override func setUp() async throws {
        app = try await sharedTestApp()
    }

    override func tearDown() async throws {}

    // MARK: - Round-trip test

    func testRoundTripMultiSentence() async throws {
        let originalText =
            "Hello world. The quick brown fox jumps over the lazy dog. This is a test of the speech pipeline."

        // Step 1: Synthesize via TTS → WAV bytes
        let bodyData = try JSONSerialization.data(withJSONObject: [
            "model": "tts-1",
            "input": originalText,
            "response_format": "wav",
        ])

        var wavData = Data()
        try await app.test(
            .POST, "/audio/speech",
            beforeRequest: { req in
                req.headers.replaceOrAdd(name: .contentType, value: "application/json")
                req.body = ByteBuffer(data: bodyData)
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok, "TTS synthesis should succeed")
                var body = res.body
                let bytes = body.readBytes(length: body.readableBytes) ?? []
                wavData = Data(bytes)
                XCTAssertGreaterThan(
                    wavData.count, 44,
                    "Synthesized audio must be larger than a WAV header")
            }
        )

        // Step 2: Transcribe the synthesized audio via STT
        let multipartBody = makeMultipartBody(
            boundary: boundary,
            file: wavData,
            filename: "synth.wav"
        )

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")

        var transcribedText = ""
        try await app.test(
            .POST, "/audio/transcriptions",
            headers: headers,
            body: ByteBuffer(data: multipartBody)
        ) { res async throws in
            XCTAssertEqual(res.status, .ok, "Transcription should succeed")
            let decoded = try res.content.decode(TranscriptionResponseJSON.self)
            transcribedText = decoded.text
            XCTAssertFalse(transcribedText.isEmpty, "Transcription should produce non-empty text")
        }

        // Step 3: Verify similarity — word overlap > 0.4 (TTS→STT is lossy)
        let similarity = wordOverlapRatio(original: originalText, transcribed: transcribedText)
        XCTAssertGreaterThan(
            similarity, 0.4,
            "Transcription '\(transcribedText)' has too little overlap with original '\(originalText)' (ratio: \(similarity))"
        )
    }
}
