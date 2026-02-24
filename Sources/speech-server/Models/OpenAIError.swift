import Vapor

struct OpenAIErrorResponse: Content {
    let error: OpenAIErrorDetail
}

struct OpenAIErrorDetail: Content {
    let message: String
    let type: String
    let param: String?
    let code: String?
}
