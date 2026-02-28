import Foundation
import Vapor
import Yams

// MARK: - Top-level config

struct ServerConfig: Codable, Sendable {
    var server: ServerSettings
    var stt: STTConfig
    var tts: TTSConfig

    init() {
        server = ServerSettings()
        stt = STTConfig()
        tts = TTSConfig()
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decodeIfPresent(ServerSettings.self, forKey: .server) ?? ServerSettings()
        stt    = try c.decodeIfPresent(STTConfig.self,      forKey: .stt)    ?? STTConfig()
        tts    = try c.decodeIfPresent(TTSConfig.self,      forKey: .tts)    ?? TTSConfig()
    }

    static var `default`: ServerConfig { ServerConfig() }

    // MARK: - Discovery

    /// Loads config using the priority order: SPEECH_SERVER_CONFIG env var
    /// → ./speech-server.yaml in CWD → built-in defaults.
    static func load() throws -> ServerConfig {
        if let envPath = ProcessInfo.processInfo.environment["SPEECH_SERVER_CONFIG"] {
            return try loadFromFile(path: envPath)
        }
        let cwdPath = FileManager.default.currentDirectoryPath + "/speech-server.yaml"
        if FileManager.default.fileExists(atPath: cwdPath) {
            return try loadFromFile(path: cwdPath)
        }
        return .default
    }

    private static func loadFromFile(path: String) throws -> ServerConfig {
        let url = URL(fileURLWithPath: path)
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(ServerConfig.self, from: contents)
    }
}

// MARK: - Server settings

struct ServerSettings: Codable, Sendable {
    var host: String
    var port: Int
    var logLevel: String
    var uploadLimitMB: Int

    init() {
        host = "127.0.0.1"
        port = 8080
        logLevel = "notice"
        uploadLimitMB = 500
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host          = try c.decodeIfPresent(String.self, forKey: .host)          ?? "127.0.0.1"
        port          = try c.decodeIfPresent(Int.self,    forKey: .port)          ?? 8080
        logLevel      = try c.decodeIfPresent(String.self, forKey: .logLevel)      ?? "notice"
        uploadLimitMB = try c.decodeIfPresent(Int.self,    forKey: .uploadLimitMB) ?? 500
    }

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case logLevel      = "log_level"
        case uploadLimitMB = "upload_limit_mb"
    }
}

// MARK: - STT config

struct STTConfig: Codable, Sendable {
    var engine: STTEngine
    var parakeet: ParakeetSettings?

    init() {
        engine   = .parakeet
        parakeet = nil
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine   = try c.decodeIfPresent(STTEngine.self,        forKey: .engine)   ?? .parakeet
        parakeet = try c.decodeIfPresent(ParakeetSettings.self, forKey: .parakeet)
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case parakeet = "parakeet"
    }
}

enum STTEngine: String, Codable, Sendable {
    case parakeet = "parakeet"
}

struct ParakeetSettings: Codable, Sendable {
    /// ASR model variant. "v3" = Parakeet TDT 0.6B v3 (multilingual, 25 langs, default).
    /// "v2" = Parakeet TDT 0.6B v2 (English-only, higher recall for English audio).
    var modelVersion: String

    init() { modelVersion = "v3" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelVersion = try c.decodeIfPresent(String.self, forKey: .modelVersion) ?? "v3"
    }

    enum CodingKeys: String, CodingKey {
        case modelVersion = "model_version"
    }
}

// MARK: - TTS config

struct TTSConfig: Codable, Sendable {
    var engine: TTSEngine
    var pocketTts: PocketTtsSettings?

    init() {
        engine   = .pocketTts
        pocketTts = nil
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine   = try c.decodeIfPresent(TTSEngine.self,         forKey: .engine)    ?? .pocketTts
        pocketTts = try c.decodeIfPresent(PocketTtsSettings.self, forKey: .pocketTts)
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case pocketTts = "pocket_tts"
    }
}

enum TTSEngine: String, Codable, Sendable {
    case pocketTts = "pocket_tts"
}

struct PocketTtsSettings: Codable, Sendable {
    /// Strip emoji and collapse surrounding whitespace before synthesis.
    /// PocketTTS renders emoji as creaky artifacts; default is true.
    var sanitizeEmoji: Bool

    init() { sanitizeEmoji = true }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sanitizeEmoji = try c.decodeIfPresent(Bool.self, forKey: .sanitizeEmoji) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case sanitizeEmoji = "sanitize_emoji"
    }
}

// MARK: - Vapor DI

struct ServerConfigKey: StorageKey {
    typealias Value = ServerConfig
}

extension Application {
    var serverConfig: ServerConfig {
        get { storage[ServerConfigKey.self] ?? .default }
        set { storage[ServerConfigKey.self] = newValue }
    }
}

extension Request {
    var serverConfig: ServerConfig {
        application.serverConfig
    }
}
