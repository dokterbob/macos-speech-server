import Vapor

protocol STTService: Sendable {
    func transcribe(audioData: Data, filename: String) async throws -> String
}

struct StubSTTService: STTService {
    func transcribe(audioData: Data, filename: String) async throws -> String {
        "[stub] Transcription of \(filename) (\(audioData.count) bytes)"
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
