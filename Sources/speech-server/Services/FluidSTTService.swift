import Foundation
import FluidAudio
import Logging

final class FluidSTTService: STTService, @unchecked Sendable {
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var logger: Logger = {
        var l = Logger(label: "FluidSTTService")
        l.logLevel = .notice
        return l
    }()

    func initialize(modelVersion: AsrModelVersion = .v3) async throws {
        let models = try await AsrModels.downloadAndLoad(version: modelVersion)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.vadManager = try await VadManager()
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard let asrManager, let vadManager else {
            throw FluidSTTError.notInitialized
        }

        logger.notice("Transcribing: \(audioURL.lastPathComponent)")

        let diskSource: DiskBackedAudioSampleSource
        do {
            let factory = StreamingAudioSourceFactory()
            let (source, _) = try factory.makeDiskBackedSource(
                from: audioURL, targetSampleRate: 16000
            )
            diskSource = source
        } catch {
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
            vadResults.append(VadResult(
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

        var segmentResults: [SegmentResult] = []

        for vadSeg in vadSegments {
            let startSample = vadSeg.startSample(sampleRate: 16000)
            let endSample = min(vadSeg.endSample(sampleRate: 16000), totalSamples)
            let segLength = endSample - startSample
            guard segLength >= 160 else { continue }

            // ASR requires >= 16,000 samples (1 second); pad shorter segments with silence.
            // The model handles silence padding natively, so transcription quality is unaffected.
            let paddedLength = max(segLength, 16_000)
            var slicedSamples = [Float](repeating: 0, count: paddedLength)
            try diskSource.copySamples(into: &slicedSamples, offset: startSample, count: segLength)
            let result = try await asrManager.transcribe(slicedSamples, source: .system)

            let segOffset = vadSeg.startTime
            let rawWords = mergeTokensIntoWords(result.tokenTimings ?? [])
            let offsetWords = rawWords.map {
                WordTiming(word: $0.word, start: ($0.start + segOffset).rounded3, end: ($0.end + segOffset).rounded3)
            }

            segmentResults.append(SegmentResult(
                text: result.text,
                start: vadSeg.startTime.rounded3,
                end: vadSeg.endTime.rounded3,
                words: offsetWords,
                confidence: result.confidence
            ))
        }

        let fullText = segmentResults.map { $0.text }.joined(separator: " ")
        let allWords = segmentResults.flatMap { $0.words }

        logger.notice("Transcription done: duration=\(totalDuration)s, segments=\(segmentResults.count)")
        logger.debug("Transcription text: '\(fullText)'")

        return TranscriptionResult(text: fullText, duration: totalDuration, words: allWords, segments: segmentResults)
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
