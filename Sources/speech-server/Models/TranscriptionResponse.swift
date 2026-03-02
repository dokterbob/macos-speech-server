import Vapor

struct TranscriptionResponseJSON: Content {
    let text: String
}

struct TranscriptionSegment: Content {
    let id: Int
    let seek: Int
    let start: Double
    let end: Double
    let text: String
    let temperature: Double
    let avgLogprob: Double
    let compressionRatio: Double
    let noSpeechProb: Double

    enum CodingKeys: String, CodingKey {
        case id, seek, start, end, text, temperature
        case avgLogprob = "avg_logprob"
        case compressionRatio = "compression_ratio"
        case noSpeechProb = "no_speech_prob"
    }
}

struct TranscriptionWord: Content {
    let word: String
    let start: Double
    let end: Double
}

struct TranscriptionResponseVerbose: Content {
    let task: String
    let language: String
    let duration: Double
    let text: String
    let words: [TranscriptionWord]?
    let segments: [TranscriptionSegment]?
}
