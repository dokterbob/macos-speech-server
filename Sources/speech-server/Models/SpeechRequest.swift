import Vapor

struct SpeechRequest: Content {
    let model: String
    let input: String
    let voice: String?
    let responseFormat: String?
    let speed: Double?

    var resolvedVoice: String { voice ?? "alba" }
    var resolvedFormat: String { responseFormat ?? "wav" }
    var resolvedSpeed: Double { speed ?? 1.0 }

    enum CodingKeys: String, CodingKey {
        case model, input, voice, speed
        case responseFormat = "response_format"
    }
}
