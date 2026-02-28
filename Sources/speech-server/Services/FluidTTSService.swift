import FluidAudio
import Foundation
import Logging
import NaturalLanguage

final class FluidTTSService: TTSService, @unchecked Sendable {
    private var pocketTtsManager: PocketTtsManager?
    private var sanitizeEmoji: Bool = true
    private var logger: Logger = {
        var l = Logger(label: "FluidTTSService")
        l.logLevel = .notice
        return l
    }()

    func initialize(settings: PocketTtsSettings = PocketTtsSettings()) async throws {
        sanitizeEmoji = settings.sanitizeEmoji
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
        let preprocessed = ensureSentencePunctuation(sanitizeEmoji ? sanitizeTextForPocketTTS(text) : text)
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
                    let input = self.sanitizeEmoji ? sanitizeTextForPocketTTS(text) : text
                    let sentences = self.detectSentences(input)
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

// MARK: - PocketTTS text sanitization

// Strips emoji from `text` and collapses any whitespace runs left behind.
// Package-internal so it can be tested directly without a live TTS service.
//
// Filtered scalar categories:
//   • isEmoji && value >= 0x231A — all pictographic emoji, including both
//     emoji-presentation (e.g. 🎉 U+1F389) and text-default-presentation
//     (e.g. ⚡ U+26A1, 🌩 U+1F329) variants.  U+231A (⌚ WATCH) is the
//     first codepoint with Emoji_Presentation=Yes; using it as the lower
//     bound keeps ASCII/Latin-1 emoji-capable characters (#, *, 0–9,
//     ™ U+2122, ℹ U+2139, ↔ U+2194) intact.  Skin-tone modifiers
//     (U+1F3FB–U+1F3FF) satisfy isEmoji && value >= 0x231A so no separate
//     isEmojiModifier check is needed.
//   • U+FE00–U+FE0F — variation selectors (force emoji vs text display)
//   • U+E0000–U+E007F — tag characters used in regional-flag sequences
//   • U+200D — zero-width joiner that stitches compound emoji
func sanitizeTextForPocketTTS(_ text: String) -> String {
    let filtered = text.unicodeScalars.filter { scalar in
        !(scalar.properties.isEmoji && scalar.value >= 0x231A)
        && !(scalar.value >= 0xFE00 && scalar.value <= 0xFE0F)
        && !(scalar.value >= 0xE0000 && scalar.value <= 0xE007F)
        && scalar.value != 0x200D
    }
    return String(String.UnicodeScalarView(filtered))
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
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
