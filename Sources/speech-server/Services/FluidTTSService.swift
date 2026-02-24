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
        do {
            let audioData = try await manager.synthesize(text: text, voice: voice)
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
