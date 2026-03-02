import FluidAudio
import Vapor

func configure(_ app: Application) async throws {
    let config = try ServerConfig.load()
    app.serverConfig = config

    // Apply log level from config
    if let level = Logger.Level(string: config.logLevel) {
        app.logger.logLevel = level
    }
    else {
        app.logger.logLevel = .notice
        app.logger.warning("Unknown log_level '\(config.logLevel)'; defaulting to 'notice'.")
    }

    // Apply host/port (Vapor's --hostname/--port CLI args override these after configure())
    app.http.server.configuration.hostname = config.servers.http.host
    app.http.server.configuration.port = config.servers.http.port

    app.middleware = Middlewares()
    app.middleware.use(RequestLoggingMiddleware())
    app.middleware.use(OpenAIErrorMiddleware())

    // TTS engine selection
    switch config.tts.engine {
    case .pocketTts:
        let ttsService = FluidTTSService()
        app.logger.info("Loading TTS models (first run will download)...")
        try await ttsService.initialize(settings: config.tts.pocketTts ?? PocketTtsSettings())
        app.ttsService = ttsService
        app.logger.info("TTS models loaded.")
    }

    // STT engine selection
    switch config.stt.engine {
    case .parakeet:
        let sttService = FluidSTTService()
        let modelVersionStr = config.stt.parakeet?.modelVersion ?? "v3"
        let modelVersion: AsrModelVersion =
            switch modelVersionStr {
            case "v2": .v2
            case "v3": .v3
            default:
                throw Abort(
                    .internalServerError,
                    reason: "Unknown STT model_version '\(modelVersionStr)'; valid values are 'v2' and 'v3'.")
            }
        app.logger.info("Loading ASR models (Parakeet \(modelVersionStr), first run will download ~minutes)...")
        try await sttService.initialize(modelVersion: modelVersion)
        app.sttService = sttService
        app.logger.info("ASR models loaded. Server ready.")
    }

    // Wyoming TCP server (default port 10300; set wyoming.port: 0 or WYOMING_PORT=0 to disable)
    let wyomingHost: String
    if let envHost = ProcessInfo.processInfo.environment["WYOMING_HOST"] {
        wyomingHost = envHost
    }
    else {
        wyomingHost = config.servers.wyoming.host
    }
    let wyomingPort: Int
    if let envPort = ProcessInfo.processInfo.environment["WYOMING_PORT"], let parsed = Int(envPort) {
        wyomingPort = parsed
    }
    else {
        wyomingPort = config.servers.wyoming.port
    }
    if wyomingPort > 0 {
        let wyomingServer = WyomingServer(
            host: wyomingHost,
            port: wyomingPort,
            ttsService: app.ttsService,
            sttService: app.sttService,
            logger: app.logger
        )
        app.lifecycle.use(wyomingServer)
        app.logger.notice(
            "Wyoming server registered on \(wyomingHost):\(wyomingPort) (starts after service init).")
    }

    try routes(app)
}

// MARK: - Logger.Level from string

extension Logger.Level {
    init?(string: String) {
        switch string.lowercased() {
        case "trace": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "notice": self = .notice
        case "warning": self = .warning
        case "error": self = .error
        case "critical": self = .critical
        default: return nil
        }
    }
}
