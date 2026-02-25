import Vapor
import MultipartKit
import NIOCore

struct TranscriptionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.on(.POST, "audio", "transcriptions", body: .stream, use: handleTranscription)
    }

    @Sendable
    func handleTranscription(req: Request) async throws -> Response {
        guard let boundary = req.headers.contentType?.parameters["boundary"] else {
            throw Abort(.badRequest, reason: "Missing multipart boundary in Content-Type")
        }

        let state = MultipartParseState()
        let parser = MultipartParser(boundary: boundary)

        parser.onHeader = { name, value in
            if name.lowercased() == "content-disposition" {
                state.currentFieldName = extractParam(value, name: "name")
                state.currentFileName = extractParam(value, name: "filename")
            }
        }

        parser.onBody = { bodyChunk in
            guard let fieldName = state.currentFieldName else { return }

            if fieldName == "file" {
                if state.fileHeaderBytes.count < 12 {
                    let needed = 12 - state.fileHeaderBytes.count
                    let available = min(needed, bodyChunk.readableBytes)
                    if let bytes = bodyChunk.getBytes(at: bodyChunk.readerIndex, length: available) {
                        state.fileHeaderBytes.append(contentsOf: bytes)
                    }
                }

                if state.fileOutputStream == nil {
                    let filename = state.currentFileName ?? "upload"
                    let ext = audioFileExtension(filename: filename, header: state.fileHeaderBytes)
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString)\(ext)")
                    state.fileTempURL = url
                    state.uploadedFileName = filename
                    let stream = OutputStream(url: url, append: false)
                    stream?.open()
                    state.fileOutputStream = stream
                }

                bodyChunk.withUnsafeReadableBytes { ptr in
                    guard let base = ptr.baseAddress, ptr.count > 0 else { return }
                    _ = state.fileOutputStream?.write(
                        base.assumingMemoryBound(to: UInt8.self), maxLength: ptr.count)
                    state.fileSize += ptr.count
                }
            } else {
                var mutable = bodyChunk
                if var existing = state.fieldBuffers[fieldName] {
                    existing.writeBuffer(&mutable)
                    state.fieldBuffers[fieldName] = existing
                } else {
                    state.fieldBuffers[fieldName] = ByteBuffer(buffer: mutable)
                }
            }
        }

        parser.onPartComplete = {
            if state.currentFieldName == "file" {
                state.fileOutputStream?.close()
                state.fileOutputStream = nil
            }
            state.currentFieldName = nil
            state.currentFileName = nil
        }

        let maxBodyBytes = 500 * 1024 * 1024  // 500 MB
        var totalBytes = 0
        do {
            for try await chunk in req.body {
                totalBytes += chunk.readableBytes
                if totalBytes > maxBodyBytes {
                    state.cleanup()
                    throw Abort(.payloadTooLarge, reason: "Upload exceeds the 500 MB limit.")
                }
                try parser.execute(chunk)
            }
        } catch {
            state.cleanup()
            throw error
        }

        guard let audioTempURL = state.fileTempURL else {
            throw Abort(.badRequest, reason: "'file' field is required.")
        }
        defer { try? FileManager.default.removeItem(at: audioTempURL) }

        guard state.fileSize > 0 else {
            throw Abort(.badRequest, reason: "'file' must not be empty.")
        }

        let filename = state.uploadedFileName ?? "upload"
        let responseFormat = state.stringField("response_format") ?? "json"
        let language = state.stringField("language")

        if let tempStr = state.stringField("temperature"), let temp = Double(tempStr) {
            guard temp >= 0 && temp <= 1 else {
                throw Abort(.badRequest, reason: "'temperature' must be between 0 and 1.")
            }
        }

        req.logger.notice("Transcription upload: filename=\(filename), size=\(state.fileSize) bytes, response_format=\(responseFormat)")

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
            let words = result.words.map { TranscriptionWord(word: $0.word, start: $0.start, end: $0.end) }
            let verbose = TranscriptionResponseVerbose(
                task: "transcribe",
                language: language ?? "en",
                duration: result.duration,
                text: result.text,
                words: words,
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

// MARK: - Streaming multipart helpers

private final class MultipartParseState {
    var currentFieldName: String?
    var currentFileName: String?
    var fieldBuffers: [String: ByteBuffer] = [:]
    var fileOutputStream: OutputStream?
    var fileTempURL: URL?
    var uploadedFileName: String?
    var fileHeaderBytes = Data()
    var fileSize = 0

    func stringField(_ name: String) -> String? {
        guard var buf = fieldBuffers[name] else { return nil }
        return buf.readString(length: buf.readableBytes)
    }

    func cleanup() {
        fileOutputStream?.close()
        fileOutputStream = nil
        if let url = fileTempURL {
            try? FileManager.default.removeItem(at: url)
            fileTempURL = nil
        }
    }
}

private func extractParam(_ header: String, name: String) -> String? {
    guard let range = header.range(of: "\(name)=\"") else { return nil }
    let start = range.upperBound
    guard let end = header[start...].firstIndex(of: "\"") else { return nil }
    return String(header[start..<end])
}
