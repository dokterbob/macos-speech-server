import Vapor

struct TranscriptionResult {
    let text: String
    let duration: Double
}

protocol STTService: Sendable {
    func transcribe(audioData: Data, filename: String) async throws -> TranscriptionResult
}

struct StubSTTService: STTService {
    func transcribe(audioData: Data, filename: String) async throws -> TranscriptionResult {
        TranscriptionResult(
            text: "[stub] Transcription of \(filename) (\(audioData.count) bytes)",
            duration: 0.0
        )
    }
}

// MARK: - Vapor DI

struct STTServiceKey: StorageKey {
    typealias Value = any STTService
}

extension Application {
    var sttService: any STTService {
        get { storage[STTServiceKey.self] ?? StubSTTService() }
        set { storage[STTServiceKey.self] = newValue }
    }
}

extension Request {
    var sttService: any STTService {
        application.sttService
    }
}
