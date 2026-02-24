import Vapor

struct SpeechRequest: Content {
    let model: String
    let input: String
    let voice: String?
    let response_format: String?
    let speed: Double?

    var resolvedVoice: String { voice ?? "alloy" }
    var resolvedFormat: String { response_format ?? "wav" }
    var resolvedSpeed: Double { speed ?? 1.0 }
}
