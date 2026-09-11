import Vapor

protocol TTSService: Sendable {
    /// Synthesise text and return a complete WAV file (globally peak-normalised).
    func synthesize(text: String, voice: String) async throws -> Data

    /// Synthesise text sentence-by-sentence, yielding raw 16-bit little-endian PCM
    /// chunks (at `sampleRate` Hz, mono, no WAV header) as each sentence completes.
    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error>

    /// Native sample rate of this engine in Hz (e.g. 24000 for PocketTTS, 22050 for AVSpeech).
    var sampleRate: Int { get }

    /// Default voice name used when the caller does not specify a voice.
    var defaultVoice: String { get }

    /// All voice names supported by this engine.
    var availableVoices: [String] { get }

    /// Language code for a given voice name (e.g. "de-DE", "en-US").
    /// Returns "en" as fallback when the language cannot be determined.
    func language(for voiceName: String) -> String

    /// All language codes for a voice name (e.g. ["de-DE", "en-GB", ...]).
    /// Default returns ["en"].
    func languages(for voiceName: String) -> [String]
}

// MARK: - Default implementation
extension TTSService {
    func language(for voiceName: String) -> String {
        "en"
    }

    func languages(for voiceName: String) -> [String] {
        [language(for: voiceName)]
    }
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
