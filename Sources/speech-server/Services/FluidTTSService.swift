import FluidAudio
import Foundation
import Logging

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

    func synthesize(text: String, voice: String) async throws -> Data {
        guard let manager = pocketTtsManager else {
            throw FluidTTSError.notInitialized
        }
        logger.notice("Synthesizing: \(text.prefix(80))...")
        let audioData = try await manager.synthesize(text: text, voice: voice)
        logger.notice("Synthesis done: \(audioData.count) bytes")
        return audioData
    }
}

enum FluidTTSError: Error, CustomStringConvertible {
    case notInitialized

    var description: String {
        switch self {
        case .notInitialized:
            return "TTS service has not been initialized."
        }
    }
}
