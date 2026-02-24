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
        let result = try await asrManager.transcribe(audioURL, source: .system)
        logger.notice("Transcription done: duration=\(result.duration)s")
        logger.debug("Transcription text: '\(result.text)'")
        return TranscriptionResult(text: result.text, duration: result.duration)
    }
}

enum FluidSTTError: Error, CustomStringConvertible {
    case notInitialized

    var description: String {
        switch self {
        case .notInitialized:
            return "ASR service has not been initialized."
        }
    }
}
