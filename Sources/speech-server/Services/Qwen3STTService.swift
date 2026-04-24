import FluidAudio
import Foundation
import Logging

@available(macOS 15, *)
final class Qwen3STTService: STTService, @unchecked Sendable {
    private var manager: Qwen3AsrManager?
    private var vadManager: VadManager?
    private let language: String?
    private var logger: Logger = {
        var l = Logger(label: "Qwen3STTService")
        l.logLevel = .notice
        return l
    }()

    init(language: String?) {
        self.language = language
    }

    func initialize(variant: Qwen3AsrVariant = .int8) async throws {
        let mgr = Qwen3AsrManager()
        let modelDir = try await Qwen3AsrModels.download(variant: variant)
        try await mgr.loadModels(from: modelDir)
        self.manager = mgr
        self.vadManager = try await VadManager()
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard let manager, let vadManager else {
            throw Qwen3STTError.notInitialized
        }

        logger.notice("Transcribing (Qwen3): \(audioURL.lastPathComponent)")

        let diskSource: DiskBackedAudioSampleSource
        do {
            let factory = AudioSourceFactory()
            let (source, _) = try factory.makeDiskBackedSource(
                from: audioURL, targetSampleRate: 16000
            )
            diskSource = source
        }
        catch {
            throw Qwen3STTError.audioConversionFailed(error)
        }
        defer { diskSource.cleanup() }

        let totalSamples = diskSource.sampleCount
        let totalDuration = Double(totalSamples) / 16000.0

        guard totalSamples > 160 else {
            throw Qwen3STTError.audioTooShort
        }

        // Run VAD in streaming chunks to find speech segments.
        // Qwen3 has a 30-second max audio limit, so we must segment.
        let chunkSize = VadManager.chunkSize
        var vadResults: [VadResult] = []
        var chunk = [Float](repeating: 0, count: chunkSize)
        var vadStreamState = VadStreamState.initial()

        for chunkOffset in stride(from: 0, to: totalSamples, by: chunkSize) {
            let count = min(chunkSize, totalSamples - chunkOffset)
            try diskSource.copySamples(into: &chunk, offset: chunkOffset, count: count)
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

        var segmentResults: [SegmentResult] = []

        // Qwen3 max audio is 30 seconds = 480,000 samples at 16 kHz.
        let maxSamples = 30 * 16_000

        for vadSeg in vadSegments {
            let startSample = vadSeg.startSample(sampleRate: 16000)
            let endSample = min(vadSeg.endSample(sampleRate: 16000), totalSamples)
            let segLength = endSample - startSample
            guard segLength >= 160 else { continue }

            // Qwen3 requires >= 16,000 samples (1 second); pad shorter segments.
            let paddedLength = max(min(segLength, maxSamples), 16_000)
            let copyLength = min(segLength, maxSamples)
            var slicedSamples = [Float](repeating: 0, count: paddedLength)
            try diskSource.copySamples(into: &slicedSamples, offset: startSample, count: copyLength)

            let text = try await manager.transcribe(
                audioSamples: slicedSamples,
                language: language
            )

            segmentResults.append(
                SegmentResult(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: vadSeg.startTime.rounded3,
                    end: vadSeg.endTime.rounded3,
                    words: [],
                    confidence: 1.0
                ))
        }

        let fullText = segmentResults.map { $0.text }.joined(separator: " ")

        logger.notice("Transcription done (Qwen3): duration=\(totalDuration)s, segments=\(segmentResults.count)")
        logger.debug("Transcription text: '\(fullText)'")

        return TranscriptionResult(text: fullText, duration: totalDuration, words: [], segments: segmentResults)
    }
}

extension Double {
    fileprivate var rounded3: Double { (self * 1000).rounded() / 1000 }
}

enum Qwen3STTError: Error, CustomStringConvertible {
    case notInitialized
    case audioConversionFailed(Error)
    case audioTooShort
    case unsupportedPlatform

    var description: String {
        switch self {
        case .notInitialized:
            return "Qwen3 ASR service has not been initialized."
        case .audioConversionFailed(let underlying):
            return "Audio conversion failed: \(underlying)"
        case .audioTooShort:
            return "Audio file is too short to transcribe."
        case .unsupportedPlatform:
            return "Qwen3 ASR requires macOS 15 or later."
        }
    }
}
