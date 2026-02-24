import Vapor

struct TranscriptionRequest: Content {
    var file: File
    var model: String?
    var language: String?
    var prompt: String?
    var response_format: String?
    var temperature: Double?
}

struct TranscriptionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.on(.POST, "audio", "transcriptions", body: .collect(maxSize: "25mb"), use: handleTranscription)
    }

    @Sendable
    func handleTranscription(req: Request) async throws -> Response {
        let form = try req.content.decode(TranscriptionRequest.self)

        let fileData = Data(buffer: form.file.data)
        guard !fileData.isEmpty else {
            throw Abort(.badRequest, reason: "'file' must not be empty.")
        }

        if let temperature = form.temperature {
            guard temperature >= 0 && temperature <= 1 else {
                throw Abort(.badRequest, reason: "'temperature' must be between 0 and 1.")
            }
        }

        let responseFormat = form.response_format ?? "json"
        let filename = form.file.filename

        let text = try await req.sttService.transcribe(
            audioData: fileData,
            filename: filename
        )

        switch responseFormat {
        case "text":
            let response = Response(status: .ok, body: .init(string: text))
            response.headers.contentType = .plainText
            return response
        case "verbose_json":
            let verbose = TranscriptionResponseVerbose(
                task: "transcribe",
                language: form.language ?? "en",
                duration: 0.0,
                text: text
            )
            let response = Response(status: .ok)
            try response.content.encode(verbose, as: .json)
            return response
        default: // "json"
            let json = TranscriptionResponseJSON(text: text)
            let response = Response(status: .ok)
            try response.content.encode(json, as: .json)
            return response
        }
    }
}
