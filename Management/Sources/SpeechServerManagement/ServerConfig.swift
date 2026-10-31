import Foundation
import Yams

// MARK: - Top-level config

public struct ServerConfig: Codable, Sendable, Equatable {
    public var logLevel: String
    public var servers: ServersConfig
    public var stt: STTConfig
    public var tts: TTSConfig

    public init() {
        logLevel = "notice"
        servers = ServersConfig()
        stt = STTConfig()
        tts = TTSConfig()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? "notice"
        servers = try c.decodeIfPresent(ServersConfig.self, forKey: .servers) ?? ServersConfig()
        stt = try c.decodeIfPresent(STTConfig.self, forKey: .stt) ?? STTConfig()
        tts = try c.decodeIfPresent(TTSConfig.self, forKey: .tts) ?? TTSConfig()
    }

    enum CodingKeys: String, CodingKey {
        case logLevel = "log_level"
        case servers
        case stt
        case tts
    }

    public static var `default`: ServerConfig { ServerConfig() }

    // MARK: - Discovery

    /// Loads config using the priority order: SPEECH_SERVER_CONFIG env var
    /// → ./speech-server.yaml in CWD → built-in defaults.
    public static func load() throws -> ServerConfig {
        if let envPath = ProcessInfo.processInfo.environment["SPEECH_SERVER_CONFIG"] {
            return try loadFromFile(path: envPath)
        }
        let cwdPath = FileManager.default.currentDirectoryPath + "/speech-server.yaml"
        if FileManager.default.fileExists(atPath: cwdPath) {
            return try loadFromFile(path: cwdPath)
        }
        return .default
    }

    public static func loadFromFile(path: String) throws -> ServerConfig {
        let url = URL(fileURLWithPath: path)
        let contents = try String(contentsOf: url, encoding: .utf8)
        // An empty file (e.g. /dev/null) means "use all defaults".
        guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .default
        }
        return try YAMLDecoder().decode(ServerConfig.self, from: contents)
    }
}

// MARK: - Servers wrapper

public struct ServersConfig: Codable, Sendable, Equatable {
    public var http: HTTPConfig
    public var wyoming: WyomingConfig

    public init() {
        http = HTTPConfig()
        wyoming = WyomingConfig()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        http = try c.decodeIfPresent(HTTPConfig.self, forKey: .http) ?? HTTPConfig()
        wyoming = try c.decodeIfPresent(WyomingConfig.self, forKey: .wyoming) ?? WyomingConfig()
    }

    enum CodingKeys: String, CodingKey {
        case http
        case wyoming
    }
}

// MARK: - HTTP server settings

public struct HTTPConfig: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var uploadLimitMB: Int

    public init() {
        host = "127.0.0.1"
        port = 8080
        uploadLimitMB = 500
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        uploadLimitMB = try c.decodeIfPresent(Int.self, forKey: .uploadLimitMB) ?? 500
    }

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case uploadLimitMB = "upload_limit_mb"
    }
}

// MARK: - STT config

public struct STTConfig: Codable, Sendable, Equatable {
    public var engine: STTEngine
    public var parakeet: ParakeetSettings?
    public var qwen3: Qwen3STTSettings?

    public init() {
        engine = .parakeet
        parakeet = nil
        qwen3 = nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(STTEngine.self, forKey: .engine) ?? .parakeet
        parakeet = try c.decodeIfPresent(ParakeetSettings.self, forKey: .parakeet)
        qwen3 = try c.decodeIfPresent(Qwen3STTSettings.self, forKey: .qwen3)
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case parakeet = "parakeet"
        case qwen3 = "qwen3"
    }
}

public enum STTEngine: String, Codable, Sendable, Equatable {
    case parakeet = "parakeet"
    case qwen3 = "qwen3"
}

public struct ParakeetSettings: Codable, Sendable, Equatable {
    /// ASR model variant. "v3" = Parakeet TDT 0.6B v3 (multilingual, 25 langs, default).
    /// "v2" = Parakeet TDT 0.6B v2 (English-only, higher recall for English audio).
    public var modelVersion: String

    public init() { modelVersion = "v3" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelVersion = try c.decodeIfPresent(String.self, forKey: .modelVersion) ?? "v3"
    }

    enum CodingKeys: String, CodingKey {
        case modelVersion = "model_version"
    }
}

public struct Qwen3STTSettings: Codable, Sendable, Equatable {
    /// Model variant. "int8" = quantized (~900 MB, default), "f32" = full precision (~1.75 GB).
    public var variant: String
    /// Language hint for transcription (ISO 639-1 code, e.g. "en", "fr").
    /// Nil = auto-detect language from audio.
    public var language: String?

    public init() {
        variant = "int8"
        language = nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? "int8"
        language = try c.decodeIfPresent(String.self, forKey: .language)
    }

    enum CodingKeys: String, CodingKey {
        case variant
        case language
    }
}

// MARK: - TTS config

public struct TTSConfig: Codable, Sendable, Equatable {
    public var engine: TTSEngine
    public var pocketTts: PocketTtsSettings?
    public var avspeech: AVSpeechSettings?
    public var kokoro: KokoroSettings?

    public init() {
        engine = .pocketTts
        pocketTts = nil
        avspeech = nil
        kokoro = nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(TTSEngine.self, forKey: .engine) ?? .pocketTts
        pocketTts = try c.decodeIfPresent(PocketTtsSettings.self, forKey: .pocketTts)
        avspeech = try c.decodeIfPresent(AVSpeechSettings.self, forKey: .avspeech)
        kokoro = try c.decodeIfPresent(KokoroSettings.self, forKey: .kokoro)
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case pocketTts = "pocket_tts"
        case avspeech = "avspeech"
        case kokoro = "kokoro"
    }
}

public enum TTSEngine: String, Codable, Sendable, Equatable {
    case pocketTts = "pocket_tts"
    case avspeech = "avspeech"
    case kokoro = "kokoro"
}

public struct PocketTtsSettings: Codable, Sendable, Equatable {
    /// Strip emoji and collapse surrounding whitespace before synthesis.
    /// PocketTTS renders emoji as creaky artifacts; default is true.
    public var sanitizeEmoji: Bool

    public init() { sanitizeEmoji = true }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sanitizeEmoji = try c.decodeIfPresent(Bool.self, forKey: .sanitizeEmoji) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case sanitizeEmoji = "sanitize_emoji"
    }
}

public struct AVSpeechSettings: Codable, Sendable, Equatable {
    /// Default voice name for synthesis. Supports short names (e.g. "Samantha") and
    /// full identifiers (e.g. "com.apple.voice.compact.en-US.Samantha").
    /// Nil = system default voice for the current locale.
    public var defaultVoice: String?
    /// Output sample rate in Hz. AVSpeechSynthesizer natively produces 22050 Hz.
    public var sampleRate: Int

    public init() {
        defaultVoice = nil
        sampleRate = 22_050
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultVoice = try c.decodeIfPresent(String.self, forKey: .defaultVoice)
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 22_050
    }

    enum CodingKeys: String, CodingKey {
        case defaultVoice = "default_voice"
        case sampleRate = "sample_rate"
    }
}

public struct KokoroSettings: Codable, Sendable, Equatable {
    /// Default voice identifier for Kokoro synthesis.
    /// Nil = use the FluidAudio recommended voice ("af_heart").
    public var defaultVoice: String?

    public init() {
        defaultVoice = nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultVoice = try c.decodeIfPresent(String.self, forKey: .defaultVoice)
    }

    enum CodingKeys: String, CodingKey {
        case defaultVoice = "default_voice"
    }
}

// MARK: - Wyoming config

public struct WyomingConfig: Codable, Sendable, Equatable {
    /// Bind address for the Wyoming protocol server. Default: "127.0.0.1".
    public var host: String
    /// TCP port for the Wyoming protocol server. Set to 0 to disable. Default: 10300.
    public var port: Int

    public init() {
        host = "127.0.0.1"
        port = 10300
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 10300
    }

    enum CodingKeys: String, CodingKey {
        case host
        case port
    }
}
