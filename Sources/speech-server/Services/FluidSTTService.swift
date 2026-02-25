import Foundation
import FluidAudio
import Logging

final class FluidSTTService: STTService, @unchecked Sendable {
    private var asrManager: AsrManager?
    private var logger: Logger = {
        var l = Logger(label: "FluidSTTService")
        l.logLevel = .notice
        return l
    }()

    func initialize() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard let asrManager else {
            throw FluidSTTError.notInitialized
        }

        logger.notice("Transcribing: \(audioURL.lastPathComponent)")

        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(audioURL)
        } catch {
            throw FluidSTTError.audioConversionFailed(error)
        }

        guard samples.count > 160 else {
            throw FluidSTTError.audioTooShort
        }

        let result = try await asrManager.transcribe(samples, source: .system)

        logger.notice("Transcription done: duration=\(result.duration)s")
        logger.debug("Transcription text: '\(result.text)'")

        let words = mergeTokensIntoWords(result.tokenTimings ?? [])

        return TranscriptionResult(text: result.text, duration: result.duration, words: words)
    }
}

// Replicates WordTimingMerger.mergeTokensIntoWords from FluidAudioCLI (not exported by the core library).
// Tokens use leading spaces as word boundaries (SentencePiece-style, normalised by AsrManager).
private func mergeTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [WordTiming] {
    guard !tokenTimings.isEmpty else { return [] }
    var result: [WordTiming] = []
    var currentWord = ""
    var currentStart: TimeInterval?
    var currentEnd: TimeInterval = 0

    for timing in tokenTimings {
        if timing.token.hasPrefix(" ") || timing.token.hasPrefix("\n") || timing.token.hasPrefix("\t") {
            if !currentWord.isEmpty, let start = currentStart {
                result.append(WordTiming(word: currentWord, start: start.rounded3, end: currentEnd.rounded3))
            }
            currentWord = timing.token.trimmingCharacters(in: .whitespacesAndNewlines)
            currentStart = timing.startTime
            currentEnd = timing.endTime
        } else {
            if currentStart == nil { currentStart = timing.startTime }
            currentWord += timing.token
            currentEnd = timing.endTime
        }
    }
    if !currentWord.isEmpty, let start = currentStart {
        result.append(WordTiming(word: currentWord, start: start.rounded3, end: currentEnd.rounded3))
    }
    return result
}

private extension Double {
    var rounded3: Double { (self * 1000).rounded() / 1000 }
}

enum FluidSTTError: Error, CustomStringConvertible {
    case notInitialized
    case audioConversionFailed(Error)
    case audioTooShort

    var description: String {
        switch self {
        case .notInitialized:
            return "ASR service has not been initialized."
        case .audioConversionFailed(let underlying):
            return "Audio conversion failed: \(underlying)"
        case .audioTooShort:
            return "Audio file is too short to transcribe."
        }
    }
}
