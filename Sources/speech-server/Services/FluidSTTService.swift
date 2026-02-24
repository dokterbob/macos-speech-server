import Foundation
import FluidAudio

final class FluidSTTService: STTService, @unchecked Sendable {
    private var asrManager: AsrManager?

    func initialize() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
    }

    func transcribe(audioData: Data, filename: String) async throws -> String {
        guard let asrManager else {
            throw FluidSTTError.notInitialized
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("\(UUID().uuidString)_\(filename)")

        try audioData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try await asrManager.transcribe(tempURL, source: .system)
        return result.text
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
