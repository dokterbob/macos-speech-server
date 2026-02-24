import Vapor

protocol TTSService: Sendable {
    func synthesize(text: String, voice: String) async throws -> Data
}

// MARK: - Vapor DI

struct TTSServiceKey: StorageKey {
    typealias Value = any TTSService
}

extension Application {
    var ttsService: any TTSService {
        get { storage[TTSServiceKey.self]! }
        set { storage[TTSServiceKey.self] = newValue }
    }
}

extension Request {
    var ttsService: any TTSService {
        application.ttsService
    }
}
