import Vapor

func configure(_ app: Application) async throws {
    let config = try ServerConfig.load()
    app.serverConfig = config

    // Apply log level from config
    if let level = Logger.Level(string: config.server.logLevel) {
        app.logger.logLevel = level
    } else {
        app.logger.logLevel = .notice
        app.logger.warning("Unknown log_level '\(config.server.logLevel)'; defaulting to 'notice'.")
    }

    // Apply host/port (Vapor's --hostname/--port CLI args override these after configure())
    app.http.server.configuration.hostname = config.server.host
    app.http.server.configuration.port     = config.server.port

    app.middleware = Middlewares()
    app.middleware.use(RequestLoggingMiddleware())
    app.middleware.use(OpenAIErrorMiddleware())

    // TTS engine selection
    switch config.tts.engine {
    case .pocketTts:
        let ttsService = FluidTTSService()
        app.logger.info("Loading TTS models (first run will download)...")
        try await ttsService.initialize()
        app.ttsService = ttsService
        app.logger.info("TTS models loaded.")
    }

    // STT engine selection
    switch config.stt.engine {
    case .fluidAsr:
        let sttService = FluidSTTService()
        app.logger.info("Loading ASR models (first run will download ~minutes)...")
        try await sttService.initialize()
        app.sttService = sttService
        app.logger.info("ASR models loaded. Server ready.")
    }

    try routes(app)
}

// MARK: - Logger.Level from string

extension Logger.Level {
    init?(string: String) {
        switch string.lowercased() {
        case "trace":    self = .trace
        case "debug":    self = .debug
        case "info":     self = .info
        case "notice":   self = .notice
        case "warning":  self = .warning
        case "error":    self = .error
        case "critical": self = .critical
        default:         return nil
        }
    }
}
