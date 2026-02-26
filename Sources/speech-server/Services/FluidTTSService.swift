import FluidAudio
import Foundation
import Logging
import NaturalLanguage

final class FluidTTSService: TTSService, @unchecked Sendable {
    private var pocketTtsManager: PocketTtsManager?
    private var logger: Logger = {
        var l = Logger(label: "FluidTTSService")
        l.logLevel = .notice
        return l
    }()

    func initialize() async throws {
        let manager = PocketTtsManager()
        try await manager.initialize()
        self.pocketTtsManager = manager
    }

    // Returns a complete WAV file (globally peak-normalised across all audio).
    // Text is pre-processed so that PocketTTS chunks at sentence boundaries
    // rather than arbitrary word boundaries, which avoids the prosodic
    // restart artefacts that occur when normalizeText() capitalises the
    // first word of each chunk and appends a period.  Mimi state stays
    // continuous across all chunks because this is a single synthesize call.
    func synthesize(text: String, voice: String) async throws -> Data {
        guard let manager = pocketTtsManager else {
            throw FluidTTSError.notInitialized
        }
        let preprocessed = ensureSentencePunctuation(text)
        logger.notice("Synthesizing: \(preprocessed.prefix(80))...")
        do {
            let audioData = try await manager.synthesize(text: preprocessed, voice: voice)
            logger.notice("Synthesis done: \(audioData.count) bytes")
            return audioData
        } catch let loadError as PocketTtsConstantsLoader.LoadError {
            switch loadError {
            case .fileNotFound(let name) where name.hasSuffix("_audio_prompt"):
                throw FluidTTSError.voiceNotFound(voice)
            default:
                throw loadError
            }
        }
    }

    // Yields raw 16-bit little-endian PCM (24 kHz mono, no WAV header) one
    // chunk per sentence so callers can begin streaming before synthesis is
    // complete.  Mimi state resets between sentences, which is imperceptible
    // at natural sentence boundaries.
    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let manager = self.pocketTtsManager else {
                        throw FluidTTSError.notInitialized
                    }
                    let sentences = self.detectSentences(text)
                    self.logger.notice("Streaming \(sentences.count) sentence(s)")
                    for sentence in sentences {
                        do {
                            let result = try await manager.synthesizeDetailed(
                                text: sentence, voice: voice)
                            continuation.yield(Self.samplesToPCM(result.samples))
                        } catch let loadError as PocketTtsConstantsLoader.LoadError {
                            switch loadError {
                            case .fileNotFound(let name) where name.hasSuffix("_audio_prompt"):
                                throw FluidTTSError.voiceNotFound(voice)
                            default:
                                throw loadError
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    // Detect sentence boundaries with NLTokenizer and ensure each sentence
    // ends with terminal punctuation.  Re-joining produces text that PocketTTS
    // will chunk at "." / "!" / "?" instead of at arbitrary word boundaries.
    private func ensureSentencePunctuation(_ text: String) -> String {
        detectSentences(text).joined(separator: " ")
    }

    // Split text into sentences, adding a trailing "." where terminal
    // punctuation is absent so that each piece is a self-contained unit.
    private func detectSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var s = String(text[range]).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return true }
            if let last = s.last, !".!?".contains(last) { s += "." }
            sentences.append(s)
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }

    // Convert float32 samples to 16-bit PCM using per-batch peak normalisation.
    private static func samplesToPCM(_ samples: [Float]) -> Data {
        let maxVal = samples.map({ abs($0) }).max().flatMap({ $0 > 0 ? $0 : nil }) ?? 1.0
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-32767.0, min(32767.0, (s / maxVal) * 32767.0))).littleEndian
            withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
        }
        return data
    }
}

enum FluidTTSError: Error, CustomStringConvertible {
    case notInitialized
    case voiceNotFound(String)

    var description: String {
        switch self {
        case .notInitialized:
            return "TTS service has not been initialized."
        case .voiceNotFound(let voice):
            return "Voice '\(voice)' is not available."
        }
    }
}
