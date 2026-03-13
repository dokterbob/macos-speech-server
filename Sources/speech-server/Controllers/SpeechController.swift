import NIOCore
import Vapor

struct SpeechController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("audio", "speech", use: handleSpeech)
    }

    @Sendable
    func handleSpeech(req: Request) async throws -> Response {
        let speechReq = try req.content.decode(SpeechRequest.self)

        guard !speechReq.input.isEmpty else {
            throw Abort(.badRequest, reason: "'input' must be non-empty.")
        }
        guard speechReq.input.count <= 4096 else {
            throw Abort(.badRequest, reason: "'input' must be 4096 characters or fewer.")
        }

        let speed = speechReq.resolvedSpeed
        guard speed >= 0.25 && speed <= 4.0 else {
            throw Abort(.badRequest, reason: "'speed' must be between 0.25 and 4.0.")
        }

        let format = speechReq.resolvedFormat
        guard ["wav", "pcm"].contains(format) else {
            throw Abort(.badRequest, reason: "'response_format' must be 'wav' or 'pcm'.")
        }

        let ttsService = req.ttsService
        let voice = speechReq.voice ?? ttsService.defaultVoice
        // Validate before streaming: once response headers are sent we cannot
        // return a 4xx, so catch invalid voices here rather than inside the stream.
        let voices = ttsService.availableVoices
        guard voices.contains(voice) else {
            let preview = voices.prefix(5).joined(separator: ", ")
            let suffix = voices.count > 5 ? ", ..." : ""
            throw Abort(.badRequest, reason: "Voice '\(voice)' is not available. Supported: \(preview)\(suffix).")
        }

        let input = speechReq.input
        let allocator = req.byteBufferAllocator
        let sampleRate = ttsService.sampleRate

        let response = Response(status: .ok)

        if format == "wav" {
            response.headers.contentType = HTTPMediaType(type: "audio", subType: "wav")
            let header = Self.streamingWAVHeader(sampleRate: sampleRate)
            response.body = .init(
                asyncStream: { writer in
                    do {
                        var hBuf = allocator.buffer(capacity: header.count)
                        hBuf.writeBytes(header)
                        try await writer.writeBuffer(hBuf)

                        for try await chunk in ttsService.synthesizeStream(
                            text: input, voice: voice)
                        {
                            var buf = allocator.buffer(capacity: chunk.count)
                            buf.writeBytes(chunk)
                            try await writer.writeBuffer(buf)
                        }
                        try await writer.write(.end)
                    }
                    catch {
                        try? await writer.write(.error(error))
                    }
                }, count: -1, byteBufferAllocator: allocator)
        }
        else {
            response.headers.contentType = HTTPMediaType(type: "audio", subType: "pcm")
            response.body = .init(
                asyncStream: { writer in
                    do {
                        for try await chunk in ttsService.synthesizeStream(
                            text: input, voice: voice)
                        {
                            var buf = allocator.buffer(capacity: chunk.count)
                            buf.writeBytes(chunk)
                            try await writer.writeBuffer(buf)
                        }
                        try await writer.write(.end)
                    }
                    catch {
                        try? await writer.write(.error(error))
                    }
                }, count: -1, byteBufferAllocator: allocator)
        }

        return response
    }

    // WAV header for HTTP streaming: size fields use 0x7FFFFFFF (max signed
    // int32) as an "unknown length" sentinel.  Most audio clients (AVPlayer,
    // ffplay, browsers via MediaSource API) treat this as "stream until the
    // connection closes" rather than trying to seek to the end.
    private static func streamingWAVHeader(sampleRate: Int = 24_000) -> Data {
        var wav = Data()
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: "RIFF".utf8)
        u32(0x7FFF_FFFF)  // unknown file size
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        u32(16)  // PCM fmt chunk
        u16(1)  // PCM format
        u16(1)  // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))  // byte rate (16-bit mono)
        u16(2)  // block align
        u16(16)  // bits per sample
        wav.append(contentsOf: "data".utf8)
        u32(0x7FFF_FFFF)  // unknown data size
        return wav
    }
}
