import SpeechServerManagement
import Vapor

typealias ServerConfig = SpeechServerManagement.ServerConfig
typealias ServersConfig = SpeechServerManagement.ServersConfig
typealias HTTPConfig = SpeechServerManagement.HTTPConfig
typealias STTConfig = SpeechServerManagement.STTConfig
typealias STTEngine = SpeechServerManagement.STTEngine
typealias ParakeetSettings = SpeechServerManagement.ParakeetSettings
typealias Qwen3STTSettings = SpeechServerManagement.Qwen3STTSettings
typealias TTSConfig = SpeechServerManagement.TTSConfig
typealias TTSEngine = SpeechServerManagement.TTSEngine
typealias PocketTtsSettings = SpeechServerManagement.PocketTtsSettings
typealias AVSpeechSettings = SpeechServerManagement.AVSpeechSettings
typealias KokoroSettings = SpeechServerManagement.KokoroSettings
typealias WyomingConfig = SpeechServerManagement.WyomingConfig

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
