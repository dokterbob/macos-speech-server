import Vapor

func configure(_ app: Application) throws {
    app.middleware = Middlewares()
    app.middleware.use(OpenAIErrorMiddleware())

    // Wire stub services (defaults, overridden in Phase 3 with real implementations)
    app.ttsService = StubTTSService()
    app.sttService = StubSTTService()

    try routes(app)
}
