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

        var audioData: Data
        do {
            audioData = try await req.ttsService.synthesize(
                text: speechReq.input,
                voice: speechReq.resolvedVoice
            )
        } catch FluidTTSError.voiceNotFound(let voice) {
            throw Abort(.badRequest, reason: "Voice '\(voice)' is not available. Supported voices: alba.")
        }

        let contentType: HTTPMediaType
        if format == "pcm" {
            // Strip 44-byte WAV header to get raw PCM
            if audioData.count > 44 {
                audioData = audioData.dropFirst(44)
            }
            contentType = HTTPMediaType(type: "audio", subType: "pcm")
        } else {
            contentType = HTTPMediaType(type: "audio", subType: "wav")
        }

        let response = Response(status: .ok, body: .init(data: audioData))
        response.headers.contentType = contentType
        return response
    }
}
