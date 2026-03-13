import AVFoundation
import Foundation
import Logging

/// TTS service backed by macOS's built-in `AVSpeechSynthesizer`.
///
/// Zero model downloads; uses Apple's Neural TTS engine on macOS 14+.
/// Supports all 150+ system voices, including Personal Voice.
///
/// Concurrency notes:
/// - All stored properties are immutable `let`, so `Sendable` conformance is genuine.
/// - `voiceLookup` stores identifier strings (not `AVSpeechSynthesisVoice` objects)
///   to avoid questions about the framework type's `Sendable` status.
/// - Each `write()` call creates a fresh `AVSpeechSynthesizer` instance per request.
///   `AVSpeechSynthesizer.write(_:toBufferCallback:)` is asynchronous: it returns
///   immediately and delivers audio buffers on a background thread. The zero-length
///   buffer callback signals completion and resumes the async continuation.
final class AVSpeechTTSService: TTSService, Sendable {
    let sampleRate: Int
    let defaultVoice: String
    let availableVoices: [String]

    // Maps lowercase voice name or full identifier -> canonical identifier.
    private let voiceLookup: [String: String]
    private let logger: Logger

    init(settings: AVSpeechSettings = AVSpeechSettings()) {
        self.sampleRate = settings.sampleRate

        let voices = AVSpeechSynthesisVoice.speechVoices()

        // Build lookup: lowercase short name -> identifier, and lowercase identifier -> identifier.
        var lookup: [String: String] = [:]
        for voice in voices {
            lookup[voice.name.lowercased()] = voice.identifier
            lookup[voice.identifier.lowercased()] = voice.identifier
        }
        self.voiceLookup = lookup

        // Deduplicated, sorted voice names for the availableVoices list.
        let nameSet = Set(voices.map { $0.name })
        self.availableVoices = nameSet.sorted()

        // Resolve the default voice: config > system locale default > first available.
        if let configVoice = settings.defaultVoice {
            self.defaultVoice = configVoice
        }
        else {
            let localeId = Locale.current.identifier
            let systemVoice =
                AVSpeechSynthesisVoice(language: localeId)
                ?? AVSpeechSynthesisVoice(language: "en-US")
            if let sv = systemVoice,
                let matching = voices.first(where: { $0.identifier == sv.identifier })
            {
                self.defaultVoice = matching.name
            }
            else {
                self.defaultVoice = nameSet.sorted().first ?? "Samantha"
            }
        }

        var l = Logger(label: "AVSpeechTTSService")
        l.logLevel = .notice
        self.logger = l
    }

    // MARK: - TTSService

    /// Synthesises all sentences, accumulates Float32 samples, applies peak normalisation,
    /// and returns a complete WAV file.
    func synthesize(text: String, voice: String) async throws -> Data {
        guard let identifier = voiceLookup[voice.lowercased()] else {
            throw AVSpeechTTSError.voiceNotFound(voice)
        }

        var allSamples: [Float] = []
        for sentence in detectSentences(text) {
            let samples = try await synthesizeFloatSamples(
                text: sentence, voiceIdentifier: identifier)
            allSamples.append(contentsOf: samples)
        }

        if allSamples.isEmpty {
            throw AVSpeechTTSError.noAudioProduced
        }

        logger.notice("AVSpeech synthesize: \(allSamples.count) samples → WAV")
        return makeWAV(pcmData: float32ToPCM16(allSamples), sampleRate: sampleRate)
    }

    /// Streams Int16 LE PCM (no WAV header), one chunk per sentence.
    ///
    /// All Float32 samples for a sentence are accumulated first, then converted
    /// with a single peak-normalisation pass. Per-buffer normalisation is avoided
    /// because AVSpeech often delivers a quiet tail buffer whose near-zero peak
    /// would be amplified to full scale, producing audible low-frequency artefacts.
    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        guard let identifier = voiceLookup[voice.lowercased()] else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AVSpeechTTSError.voiceNotFound(voice))
            }
        }

        let sentences = detectSentences(text)
        logger.notice("AVSpeech synthesizeStream: \(sentences.count) sentence(s)")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for sentence in sentences {
                        let samples = try await self.synthesizeFloatSamples(
                            text: sentence, voiceIdentifier: identifier)
                        if !samples.isEmpty {
                            continuation.yield(float32ToPCM16(samples))
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

    // MARK: - Private synthesis helpers

    /// Synthesises one utterance and returns the concatenated Float32 samples.
    ///
    /// `write(_:toBufferCallback:)` is asynchronous: it returns immediately and delivers
    /// audio buffers on a background thread. The continuation is resumed from the
    /// zero-length buffer callback, which fires when synthesis is complete.
    private func synthesizeFloatSamples(
        text: String, voiceIdentifier: String
    ) async throws
        -> [Float]
    {
        // Bridge accumulates samples and coordinates completion across threads.
        // @unchecked Sendable: callbacks fire serially from a single background thread,
        // so there is no concurrent mutation. `resumed` guards against double-resume
        // because AVSpeechSynthesizer may deliver more than one zero-length buffer.
        final class Bridge: @unchecked Sendable {
            var samples: [Float] = []
            var resumed = false
        }
        let bridge = Bridge()

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[Float], Error>) in
            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)

            // write() returns immediately; callbacks fire asynchronously.
            // The closure captures `synthesizer` to keep it alive until synthesis completes.
            synthesizer.write(utterance) { [synthesizer] buffer in
                _ = synthesizer  // retain until this callback fires
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
                if pcmBuffer.frameLength == 0 {
                    // Zero-length buffer signals end of utterance.
                    // Guard against double-resume in case multiple zero-length buffers arrive.
                    if !bridge.resumed {
                        bridge.resumed = true
                        continuation.resume(returning: bridge.samples)
                    }
                    return
                }
                if let channelData = pcmBuffer.floatChannelData {
                    let count = Int(pcmBuffer.frameLength)
                    bridge.samples.append(
                        contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
                }
            }
        }
    }
}

// MARK: - Errors

enum AVSpeechTTSError: Error, CustomStringConvertible {
    case voiceNotFound(String)
    case noAudioProduced

    var description: String {
        switch self {
        case .voiceNotFound(let voice):
            return "Voice '\(voice)' is not available. Use a system voice name (e.g. 'Samantha') or full identifier."
        case .noAudioProduced:
            return "AVSpeechSynthesizer produced no audio for the given input."
        }
    }
}
