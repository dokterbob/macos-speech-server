import MultipartKit
import NIOCore
import Vapor

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
            }
            else {
                var mutable = bodyChunk
                if var existing = state.fieldBuffers[fieldName] {
                    existing.writeBuffer(&mutable)
                    state.fieldBuffers[fieldName] = existing
                }
                else {
                    state.fieldBuffers[fieldName] = ByteBuffer(buffer: mutable)
                }
            }
        }

        parser.onPartComplete = {
            if state.currentFieldName == "file" {
                state.fileOutputStream?.close()
                state.fileOutputStream = nil
            }
            else if let fieldName = state.currentFieldName,
                var buf = state.fieldBuffers[fieldName],
                let value = buf.readString(length: buf.readableBytes)
            {
                state.fieldValues[fieldName, default: []].append(value)
                state.fieldBuffers.removeValue(forKey: fieldName)
            }
            state.currentFieldName = nil
            state.currentFileName = nil
        }

        let uploadLimitMB = req.application.serverConfig.servers.http.uploadLimitMB
        let maxBodyBytes = uploadLimitMB * 1024 * 1024
        var totalBytes = 0
        do {
            for try await chunk in req.body {
                totalBytes += chunk.readableBytes
                if totalBytes > maxBodyBytes {
                    state.cleanup()
                    throw Abort(.payloadTooLarge, reason: "Upload exceeds the \(uploadLimitMB) MB limit.")
                }
                try parser.execute(chunk)
            }
        }
        catch {
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

        // Parse timestamp_granularities[] — only meaningful for verbose_json
        let rawGranularities = state.arrayField("timestamp_granularities[]")
        let granularities: Set<String>
        if rawGranularities.isEmpty {
            granularities = ["segment"]
        }
        else {
            for value in rawGranularities {
                guard value == "word" || value == "segment" else {
                    throw Abort(
                        .badRequest,
                        reason: "Invalid timestamp_granularities value '\(value)'. Supported: word, segment.")
                }
            }
            granularities = Set(rawGranularities)
        }

        req.logger.notice(
            "Transcription upload: filename=\(filename), size=\(state.fileSize) bytes, response_format=\(responseFormat)"
        )

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
            let segments: [TranscriptionSegment]? =
                granularities.contains("segment")
                ? result.segments.enumerated().map { index, seg in
                    TranscriptionSegment(
                        id: index,
                        seek: Int(seg.start * 100),
                        start: seg.start,
                        end: seg.end,
                        text: seg.text,
                        temperature: 0.0,
                        avgLogprob: log(Double(max(seg.confidence, 1e-6))),
                        compressionRatio: 1.0,
                        noSpeechProb: 0.0
                    )
                }
                : nil
            let words: [TranscriptionWord]? =
                granularities.contains("word")
                ? result.words.map { TranscriptionWord(word: $0.word, start: $0.start, end: $0.end) }
                : nil
            let verbose = TranscriptionResponseVerbose(
                task: "transcribe",
                language: language ?? "en",
                duration: result.duration,
                text: result.text,
                words: words,
                segments: segments
            )
            let response = Response(status: .ok)
            try response.content.encode(verbose, as: .json)
            return response
        case "srt", "vtt":
            throw Abort(.badRequest, reason: "response_format '\(responseFormat)' is not yet supported.")
        default:
            throw Abort(
                .badRequest, reason: "Unknown response_format '\(responseFormat)'. Supported: json, text, verbose_json."
            )
        }
    }
}

// MARK: - Streaming multipart helpers

private final class MultipartParseState {
    var currentFieldName: String?
    var currentFileName: String?
    var fieldBuffers: [String: ByteBuffer] = [:]
    var fieldValues: [String: [String]] = [:]
    var fileOutputStream: OutputStream?
    var fileTempURL: URL?
    var uploadedFileName: String?
    var fileHeaderBytes = Data()
    var fileSize = 0

    func stringField(_ name: String) -> String? {
        fieldValues[name]?.last
    }

    func arrayField(_ name: String) -> [String] {
        fieldValues[name] ?? []
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
