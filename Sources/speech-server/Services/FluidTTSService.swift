import FluidAudio
import Foundation
import Logging

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
        }
        catch let loadError as PocketTtsConstantsLoader.LoadError {
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
                    let sentences = detectSentences(input)
                    self.logger.notice("Streaming \(sentences.count) sentence(s)")
                    for sentence in sentences {
                        do {
                            let result = try await manager.synthesizeDetailed(
                                text: sentence, voice: voice)
                            continuation.yield(Self.samplesToPCM(result.samples))
                        }
                        catch let loadError as PocketTtsConstantsLoader.LoadError {
                            switch loadError {
                            case .fileNotFound(let name) where name.hasSuffix("_audio_prompt"):
                                throw FluidTTSError.voiceNotFound(voice)
                            default:
                                throw loadError
                            }
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

    // MARK: - Private

    // Detect sentence boundaries with NLTokenizer (via the shared free function)
    // and ensure each sentence ends with terminal punctuation.  Re-joining produces
    // text that PocketTTS will chunk at "." / "!" / "?" instead of at arbitrary
    // word boundaries.
    private func ensureSentencePunctuation(_ text: String) -> String {
        detectSentences(text).joined(separator: " ")
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

// Sanitizes `text` for PocketTTS synthesis.  Package-internal so it can be
// tested directly without a live TTS service.
//
// Applied in order:
//
// 1. Text emoticons — ASCII face patterns (`:)` `:-D` `XD` `<3` `^_^` …) that
//    TTS vocalises as symbol noise.  Matched with word-boundary guards so that
//    colons in URLs or parentheses in prose are left untouched.
//
// 2. Space-before-punctuation — LLM tokenisers commonly emit punctuation as a
//    separate token with a leading space, producing "Hello ." instead of
//    "Hello.".  The regex collapses any run of whitespace immediately before
//    `.  ,  !  ?  ;  :` into nothing, so PocketTTS receives clean sentences.
//
// 3. Unicode emoji — all pictographic emoji and related invisible characters:
//    • isEmoji && value >= 0x231A — emoji-presentation and text-default-
//      presentation variants (⚡ U+26A1, 🌩 U+1F329 …).  U+231A (⌚ WATCH) is
//      the first codepoint with Emoji_Presentation=Yes; the lower-bound keeps
//      ASCII emoji-capable characters (#, *, 0–9, ™ U+2122 …) intact.
//      Skin-tone modifiers (U+1F3FB–U+1F3FF) satisfy the condition, so no
//      separate isEmojiModifier check is needed.
//    • U+FE00–U+FE0F — variation selectors
//    • U+E0000–U+E007F — tag characters used in regional-flag sequences
//    • U+200D — zero-width joiner that stitches compound emoji
//
// 4. Whitespace — collapses every run of spaces/newlines to a single space and
//    strips leading/trailing whitespace.
func sanitizeTextForPocketTTS(_ text: String) -> String {
    // 1. Remove text emoticons (replace with space to avoid merging adjacent words)
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    var step1 = _emoticonRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")

    // 2. Fix space-before-punctuation produced by LLM tokenisation
    step1 = _spacedPunctRegex.stringByReplacingMatches(
        in: step1, range: NSRange(location: 0, length: (step1 as NSString).length),
        withTemplate: "$1"
    )

    // 3. Strip Unicode emoji and related invisible characters
    let filtered = step1.unicodeScalars.filter { scalar in
        !(scalar.properties.isEmoji && scalar.value >= 0x231A)
            && !(scalar.value >= 0xFE00 && scalar.value <= 0xFE0F)
            && !(scalar.value >= 0xE0000 && scalar.value <= 0xE007F)
            && scalar.value != 0x200D
    }

    // 4. Collapse whitespace runs (including any gaps left by the above steps)
    return String(String.UnicodeScalarView(filtered))
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

// Text emoticons: common Western face patterns anchored at word boundaries so
// colons in URLs ("http:") and parentheses in prose ("(approx)") are ignored.
//   Eyes:  [:;=]
//   Nose:  optional ['o-]
//   Mouth: [)(DdPp3oO]
// Also: [xX][Dd] (XD), <3 (heart), ^[-_]?^ (caret faces)
private let _emoticonRegex: NSRegularExpression = {
    let pattern = #"(?<!\w)(?:[:;=]['o-]?[)(DdPp3oO]|[xX][Dd]|<3|\^[-_]?\^)(?!\w)"#
    return try! NSRegularExpression(pattern: pattern)
}()

// One or more whitespace characters immediately before sentence punctuation.
// Replacement template "$1" keeps the punctuation and discards the whitespace.
private let _spacedPunctRegex: NSRegularExpression = {
    try! NSRegularExpression(pattern: #"\s+([.,!?;:])"#)
}()

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
