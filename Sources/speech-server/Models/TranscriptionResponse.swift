import Vapor

struct TranscriptionResponseJSON: Content {
    let text: String
}

struct TranscriptionResponseVerbose: Content {
    let task: String
    let language: String
    let duration: Double
    let text: String
}
