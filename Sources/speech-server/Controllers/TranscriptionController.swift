import Vapor
import MultipartKit

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
        routes.on(.POST, "audio", "transcriptions", body: .stream, use: handleTranscription)
    }

    @Sendable
    func handleTranscription(req: Request) async throws -> Response {
        // 5a. Extract multipart boundary
        guard let boundary = req.headers.contentType?.parameters["boundary"] else {
            throw Abort(.badRequest, reason: "Missing multipart boundary in Content-Type")
        }

        // 5b. Stream body to a temp file
        let bodyTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(req.id).multipart")
        defer { try? FileManager.default.removeItem(at: bodyTempURL) }

        guard let outputStream = OutputStream(url: bodyTempURL, append: false) else {
            throw Abort(.internalServerError, reason: "Could not open temp file for writing")
        }
        let maxBodyBytes = 500 * 1024 * 1024  // 500 MB
        var totalBytesWritten = 0
        outputStream.open()
        for try await chunk in req.body {
            totalBytesWritten += chunk.readableBytes
            if totalBytesWritten > maxBodyBytes {
                outputStream.close()
                throw Abort(.payloadTooLarge, reason: "Upload exceeds the 500 MB limit.")
            }
            chunk.withUnsafeReadableBytes { ptr in
                guard let base = ptr.baseAddress, ptr.count > 0 else { return }
                _ = outputStream.write(base.assumingMemoryBound(to: UInt8.self), maxLength: ptr.count)
            }
        }
        outputStream.close()

        // 5c. mmap-backed read and multipart parse
        let bodyData = try Data(contentsOf: bodyTempURL, options: .mappedIfSafe)
        var bodyBuffer = ByteBuffer()
        bodyBuffer.writeBytes(bodyData)
        let form = try FormDataDecoder().decode(TranscriptionRequest.self,
                                                from: bodyBuffer, boundary: boundary)

        // 5d. Determine correct extension from the parsed ByteBuffer
        let header = Data(form.file.data.getBytes(at: form.file.data.readerIndex,
                                                   length: min(12, form.file.data.readableBytes)) ?? [])
        let ext = audioFileExtension(filename: form.file.filename, header: header)

        // 5e. Write audio to a temp file with the correct extension
        let audioTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(req.id)\(ext)")
        defer { try? FileManager.default.removeItem(at: audioTempURL) }
        try Data(buffer: form.file.data).write(to: audioTempURL)

        // 5f. Validate, log, transcribe
        guard form.file.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "'file' must not be empty.")
        }

        if let temperature = form.temperature {
            guard temperature >= 0 && temperature <= 1 else {
                throw Abort(.badRequest, reason: "'temperature' must be between 0 and 1.")
            }
        }

        let responseFormat = form.response_format ?? "json"

        req.logger.notice("Transcription upload: filename=\(form.file.filename), contentType=\(form.file.contentType?.serialize() ?? "nil"), size=\(form.file.data.readableBytes) bytes, response_format=\(responseFormat)")

        let result = try await req.sttService.transcribe(audioURL: audioTempURL)

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
