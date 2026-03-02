import Foundation

@testable import speech_server

// MARK: - Mock TTS Service

struct MockTTSService: TTSService {
    /// PCM chunks to yield from synthesizeStream (no WAV header, raw 16-bit PCM).
    let chunks: [Data]
    /// If true, both synthesize and synthesizeStream throw MockServiceError.failed.
    let shouldFail: Bool

    init(chunks: [Data] = [], shouldFail: Bool = false) {
        self.chunks = chunks
        self.shouldFail = shouldFail
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        if shouldFail { throw MockServiceError.failed }
        return chunks.reduce(Data(), +)
    }

    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        let shouldFail = self.shouldFail
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            if shouldFail {
                continuation.finish(throwing: MockServiceError.failed)
                return
            }
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

// MARK: - Mock STT Service

struct MockSTTService: STTService {
    /// The transcript text to return from transcribe.
    let transcript: String
    /// If true, transcribe throws MockServiceError.failed.
    let shouldFail: Bool

    init(transcript: String = "test transcription", shouldFail: Bool = false) {
        self.transcript = transcript
        self.shouldFail = shouldFail
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        if shouldFail { throw MockServiceError.failed }
        return TranscriptionResult(text: transcript, duration: 1.0, words: [], segments: [])
    }
}

// MARK: - Error

enum MockServiceError: Error, Equatable {
    case failed
}
