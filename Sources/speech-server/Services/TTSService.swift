import Vapor

protocol TTSService: Sendable {
    /// Synthesise text and return a complete WAV file (globally peak-normalised).
    func synthesize(text: String, voice: String) async throws -> Data

    /// Synthesise text sentence-by-sentence, yielding raw 16-bit little-endian PCM
    /// chunks (24 kHz mono, no WAV header) as each sentence completes.
    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error>
}

// MARK: - Vapor DI

struct TTSServiceKey: StorageKey {
    typealias Value = any TTSService
}

extension Application {
    var ttsService: any TTSService {
        get { storage[TTSServiceKey.self]! }
        set { storage[TTSServiceKey.self] = newValue }
    }
}

extension Request {
    var ttsService: any TTSService {
        application.ttsService
    }
}
