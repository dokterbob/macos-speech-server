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
    let avg_logprob: Double
    let compression_ratio: Double
    let no_speech_prob: Double
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
    let words: [TranscriptionWord]
    let segments: [TranscriptionSegment]
}
