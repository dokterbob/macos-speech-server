import Foundation
import Vapor

struct WordTiming {
    let word: String
    let start: Double
    let end: Double
}

struct SegmentResult {
    let text: String
    let start: Double
    let end: Double
    let words: [WordTiming]
    let confidence: Float
}

struct TranscriptionResult {
    let text: String
    let duration: Double
    let words: [WordTiming]
    let segments: [SegmentResult]
}

protocol STTService: Sendable {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

// MARK: - Vapor DI

struct STTServiceKey: StorageKey {
    typealias Value = any STTService
}

extension Application {
    var sttService: any STTService {
        get { storage[STTServiceKey.self]! }
        set { storage[STTServiceKey.self] = newValue }
    }
}

extension Request {
    var sttService: any STTService {
        application.sttService
    }
}
