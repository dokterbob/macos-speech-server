import FluidAudio
import Foundation
import Logging

final class KokoroTTSService: TTSService, @unchecked Sendable {
    let sampleRate: Int = TtsConstants.audioSampleRate
    private(set) var defaultVoice: String = TtsConstants.recommendedVoice
    let availableVoices: [String] = TtsConstants.availableVoices.sorted()

    private var manager: KokoroTtsManager?
    private var logger: Logger = {
        var l = Logger(label: "KokoroTTSService")
        l.logLevel = .notice
        return l
    }()

    func initialize(settings: KokoroSettings = KokoroSettings()) async throws {
        let voiceId = settings.defaultVoice ?? TtsConstants.recommendedVoice
        let m = KokoroTtsManager(defaultVoice: voiceId)
        try await m.initialize()
        self.manager = m
        self.defaultVoice = voiceId
    }

    // Returns a complete WAV file produced directly by KokoroTtsManager.synthesize().
    func synthesize(text: String, voice: String) async throws -> Data {
        guard let manager = manager else {
            throw KokoroTTSError.notInitialized
        }
        guard availableVoices.contains(voice) else {
            throw KokoroTTSError.voiceNotFound(voice)
        }
        logger.notice("Kokoro synthesize: \(text.prefix(80))...")
        let data = try await manager.synthesize(text: text, voice: voice)
        logger.notice("Kokoro synthesis done: \(data.count) bytes")
        return data
    }

    // Yields raw 16-bit little-endian PCM (24 kHz mono, no WAV header) one chunk per
    // sentence. All Float32 samples for a sentence are collected from KokoroSynthesizer
    // chunk results, peak-normalised once, and converted to PCM16.
    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        guard availableVoices.contains(voice) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: KokoroTTSError.voiceNotFound(voice))
            }
        }

        let sentences = detectSentences(text)
        logger.notice("Kokoro synthesizeStream: \(sentences.count) sentence(s)")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let manager = self.manager else {
                        throw KokoroTTSError.notInitialized
                    }
                    for sentence in sentences {
                        let result = try await manager.synthesizeDetailed(
                            text: sentence, voice: voice)
                        let allSamples = result.chunks.flatMap { $0.samples }
                        if !allSamples.isEmpty {
                            continuation.yield(float32ToPCM16(allSamples))
                        }
                    }
                    continuation.finish()
                }
                catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Errors

enum KokoroTTSError: Error, CustomStringConvertible {
    case notInitialized
    case voiceNotFound(String)

    var description: String {
        switch self {
        case .notInitialized:
            return "Kokoro TTS service has not been initialized."
        case .voiceNotFound(let voice):
            return "Voice '\(voice)' is not available. Use a Kokoro voice ID (e.g. 'af_heart', 'am_adam')."
        }
    }
}
