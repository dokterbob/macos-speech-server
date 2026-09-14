import CryptoKit
import Foundation
import Yams

public struct ManagementError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension ServerConfig {
    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ManagementError(message) }
        }
        try require((1...65535).contains(servers.http.port), "HTTP port must be between 1 and 65535.")
        try require((0...65535).contains(servers.wyoming.port), "Wyoming port must be between 0 and 65535.")
        try require(servers.http.port != servers.wyoming.port, "HTTP and Wyoming must use different ports.")
        try require(
            !servers.http.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "HTTP host is required.")
        try require(
            !servers.wyoming.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Wyoming host is required.")
        try require(
            servers.http.uploadLimitMB > 0 && servers.http.uploadLimitMB <= Int.max / 1_048_576,
            "Upload limit must be a positive, representable number of MB.")
        try require(
            ["trace", "debug", "info", "notice", "warning", "error", "critical"].contains(logLevel.lowercased()),
            "Choose a valid log level.")
        if stt.engine == .parakeet {
            try require(["v2", "v3"].contains(stt.parakeet?.modelVersion ?? "v3"), "Parakeet model must be v2 or v3.")
        }
        if stt.engine == .qwen3 {
            guard #available(macOS 15, *) else { throw ManagementError("Qwen3 requires macOS 15 or later.") }
            try require(["int8", "f32"].contains(stt.qwen3?.variant ?? "int8"), "Qwen3 variant must be int8 or f32.")
        }
        if tts.engine == .avspeech {
            try require(
                (8000...192000).contains(tts.avspeech?.sampleRate ?? 22050), "Sample rate must be 8000–192000 Hz.")
        }
    }
}

public struct ConfigurationDocument: Codable, Sendable {
    public var yaml: String
    public var revision: String
    public var config: ServerConfig
    public var validationError: String?

    public static func decode(_ yaml: String) throws -> ServerConfig {
        let config = try YAMLDecoder().decode(
            ServerConfig.self, from: yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : yaml)
        try config.validate()
        return config
    }

    public static func encode(_ config: ServerConfig) throws -> String {
        try config.validate()
        return try YAMLEncoder().encode(config)
    }

    public init(yaml: String, allowInvalid: Bool = false) throws {
        self.yaml = yaml
        revision = SHA256.hash(data: Data(yaml.utf8)).map { String(format: "%02x", $0) }.joined()
        do { config = try Self.decode(yaml) }
        catch {
            guard allowInvalid else { throw error }
            config = ServerConfig()
            validationError = error.localizedDescription
        }
    }
}

/// All managed writers serialize through the agent; the revision also detects manual edits.
public struct ConfigurationStore: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("speech-server.yaml") }
    private var backupURL: URL { directory.appendingPathComponent("speech-server.yaml.previous") }
    public init(directory: URL) { self.directory = directory }

    public func read() throws -> ConfigurationDocument {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data("# Speech Server settings\n{}\n".utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        return try ConfigurationDocument(yaml: String(contentsOf: fileURL, encoding: .utf8), allowInvalid: true)
    }

    public func save(yaml: String, expectedRevision: String) throws -> ConfigurationDocument {
        let next = try ConfigurationDocument(yaml: yaml)
        let current = try read()
        guard current.revision == expectedRevision else {
            throw ManagementError("Settings changed outside this window. Reload them before saving.")
        }
        try Data(current.yaml.utf8).write(to: backupURL, options: .atomic)
        try Data(yaml.utf8).write(to: fileURL, options: .atomic)
        for url in [fileURL, backupURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return next
    }

    public func restore(expectedRevision: String) throws -> ConfigurationDocument {
        let yaml = try String(contentsOf: backupURL, encoding: .utf8)
        return try save(yaml: yaml, expectedRevision: expectedRevision)
    }
}
