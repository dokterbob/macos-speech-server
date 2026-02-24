import Vapor

func configure(_ app: Application) async throws {
    app.logger.logLevel = .notice

    app.middleware = Middlewares()
    app.middleware.use(RequestLoggingMiddleware())
    app.middleware.use(OpenAIErrorMiddleware())

    // TTS: stub for now (real implementation deferred)
    app.ttsService = StubTTSService()

    // STT: FluidAudio ASR
    let sttService = FluidSTTService()
    app.logger.info("Loading ASR models (first run will download ~minutes)...")
    try await sttService.initialize()
    app.sttService = sttService
    app.logger.info("ASR models loaded. Server ready.")

    try routes(app)
}
