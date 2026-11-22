import FluidAudio
import Foundation
import Logging

final class FluidSTTService: STTService, @unchecked Sendable {
    private var asrManager: AsrManager?
    private(set) var supportedLanguages: [String] = []
    private var vadManager: VadManager?
    private var logger: Logger = {
        var l = Logger(label: "FluidSTTService")
        l.logLevel = .notice
        return l
    }()

    func initialize(modelVersion: ParakeetModelVersion = .v3) async throws {
        let models = try await AsrModels.downloadAndLoad(version: modelVersion.asrModelVersion)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.vadManager = try await VadManager()
        self.supportedLanguages = Self.languages(for: modelVersion)
    }

    /// ISO 639-1 codes a Parakeet model version recognizes: v2 is English-only; v3 and ultra cover
    /// 25 European languages.
    static func languages(for modelVersion: ParakeetModelVersion) -> [String] {
        switch modelVersion {
        case .v2:
            ["en"]
        case .v3, .ultra:
            [
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
                "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk",
                "sl", "es", "sv", "ru", "uk",
            ]
        }
    }

    func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        guard let asrManager, let vadManager else {
            throw FluidSTTError.notInitialized
        }
        // Parakeet takes the hint as a script filter: output tokens are restricted to the language's script.
        let languageHint = try language.map { code in
            guard supportedLanguages.contains(code), let hint = Language(rawValue: code) else {
                throw FluidSTTError.unsupportedLanguage(code)
            }
            return hint
        }

        logger.notice("Transcribing: \(audioURL.lastPathComponent)")

        let diskSource: DiskBackedAudioSampleSource
        do {
            let factory = AudioSourceFactory()
            let (source, _) = try factory.makeDiskBackedSource(
                from: audioURL, targetSampleRate: 16000
            )
            diskSource = source
        }
        catch {
            throw FluidSTTError.audioConversionFailed(error)
        }
        defer { diskSource.cleanup() }

        let totalSamples = diskSource.sampleCount
        let totalDuration = Double(totalSamples) / 16000.0

        guard totalSamples > 160 else {
            throw FluidSTTError.audioTooShort
        }

        // Run VAD in streaming chunks — never materializes full [Float]
        let chunkSize = VadManager.chunkSize  // 4096
        var vadResults: [VadResult] = []
        var chunk = [Float](repeating: 0, count: chunkSize)
        var vadStreamState = VadStreamState.initial()

        for chunkOffset in stride(from: 0, to: totalSamples, by: chunkSize) {
            let count = min(chunkSize, totalSamples - chunkOffset)
            try diskSource.copySamples(into: &chunk, offset: chunkOffset, count: count)
            // Pass actual-length slice for last chunk so FluidAudio applies
            // repeat-last-sample padding (not our zero-padding)
            let vadChunk = count == chunkSize ? chunk : Array(chunk[..<count])
            let streamResult = try await vadManager.processStreamingChunk(
                vadChunk, state: vadStreamState
            )
            vadStreamState = streamResult.state
            vadResults.append(
                VadResult(
                    probability: streamResult.probability,
                    isVoiceActive: streamResult.state.triggered,
                    processingTime: 0,
                    outputState: streamResult.state.modelState
                ))
        }

        let vadSegments = await vadManager.segmentSpeech(
            from: vadResults, totalSamples: totalSamples
        )

        guard !vadSegments.isEmpty else {
            logger.notice("No speech detected: duration=\(totalDuration)s")
            return TranscriptionResult(text: "", duration: totalDuration, words: [], segments: [])
        }

        // Recognize the whole audio in one pass. Decoding VAD segments in isolation starves Parakeet of context:
        // short segments (~2s) often decode to nothing even when clearly audible. VAD only gates silence and
        // shapes the returned segments.
        let result = try await recognizeWholeAudio(
            audioURL: audioURL, source: diskSource, totalSamples: totalSamples, language: languageHint,
            asrManager: asrManager
        )
        let words = mergeTokensIntoWords(result.tokenTimings ?? []).map {
            WordTiming(word: $0.word, start: $0.start.rounded3, end: $0.end.rounded3, confidence: $0.confidence)
        }
        let regions = vadSegments.map { SpeechRegion(start: $0.startTime.rounded3, end: $0.endTime.rounded3) }
        let segments = segmentWords(words, into: regions)

        logger.notice(
            "Transcription done: duration=\(totalDuration)s, speechRegions=\(regions.count), segments=\(segments.count)"
        )
        logger.debug("Transcription text: '\(result.text)'")

        return TranscriptionResult(text: result.text, duration: totalDuration, words: words, segments: segments)
    }

    /// Runs ASR over the entire audio with token timings relative to its start.
    ///
    /// Audio of at least one second streams from disk through FluidAudio's chunked decoder (overlapping windows for
    /// audio beyond the model's 15s input). Shorter audio is zero-padded in memory to the ASR minimum of 16,000
    /// samples; trailing silence does not affect recognition.
    private func recognizeWholeAudio(
        audioURL: URL, source: DiskBackedAudioSampleSource, totalSamples: Int, language: Language?,
        asrManager: AsrManager
    ) async throws -> ASRResult {
        var decoderState = try TdtDecoderState(decoderLayers: await asrManager.decoderLayerCount)
        let minimumSamples = 16_000
        guard totalSamples < minimumSamples else {
            return try await asrManager.transcribeDiskBacked(audioURL, decoderState: &decoderState, language: language)
        }
        var samples = [Float](repeating: 0, count: minimumSamples)
        try source.copySamples(into: &samples, offset: 0, count: totalSamples)
        return try await asrManager.transcribe(samples, decoderState: &decoderState, language: language)
    }
}

extension Double {
    fileprivate var rounded3: Double { (self * 1000).rounded() / 1000 }
}

enum FluidSTTError: Error, CustomStringConvertible {
    case notInitialized
    case audioConversionFailed(Error)
    case audioTooShort
    case unsupportedLanguage(String)

    var description: String {
        switch self {
        case .notInitialized:
            return "ASR service has not been initialized."
        case .audioConversionFailed(let underlying):
            return "Audio conversion failed: \(underlying)"
        case .audioTooShort:
            return "Audio file is too short to transcribe."
        case .unsupportedLanguage(let code):
            return "Language '\(code)' is not supported by the loaded ASR model."
        }
    }
}

extension ParakeetModelVersion {
    /// The FluidAudio model for this config value. FluidAudio's `AsrModelVersion` has no string raw values and
    /// includes models this server does not offer, so the supported subset is mapped explicitly.
    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v2: .v2
        case .v3: .v3
        case .ultra: .ultra
        }
    }
}
