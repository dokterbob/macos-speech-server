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

        req.logger.notice("Transcription upload: filename=\(form.file.filename), contentType=\(form.file.contentType?.serialize() ?? "nil"), size=\(fileData.count) bytes, response_format=\(responseFormat)")
        let filename = form.file.filename

        let result = try await req.sttService.transcribe(
            audioData: fileData,
            filename: filename
        )

        switch responseFormat {
        case "json":
            let json = TranscriptionResponseJSON(text: result.text)
            let response = Response(status: .ok)
            try response.content.encode(json, as: .json)
            return response
        case "text":
            let response = Response(status: .ok, body: .init(string: result.text))
            response.headers.contentType = .plainText
            return response
        case "verbose_json":
            let segment = TranscriptionSegment(
                id: 0,
                seek: 0,
                start: 0.0,
                end: result.duration,
                text: result.text,
                temperature: 0.0,
                avg_logprob: 0.0,
                compression_ratio: 1.0,
                no_speech_prob: 0.0
            )
            let verbose = TranscriptionResponseVerbose(
                task: "transcribe",
                language: form.language ?? "en",
                duration: result.duration,
                text: result.text,
                segments: [segment]
            )
            let response = Response(status: .ok)
            try response.content.encode(verbose, as: .json)
            return response
        case "srt", "vtt":
            throw Abort(.badRequest, reason: "response_format '\(responseFormat)' is not yet supported.")
        default:
            throw Abort(.badRequest, reason: "Unknown response_format '\(responseFormat)'. Supported: json, text, verbose_json.")
        }
    }
}
