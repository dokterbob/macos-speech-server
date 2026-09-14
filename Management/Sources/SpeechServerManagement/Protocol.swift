import Darwin
import Foundation

public enum ServiceState: String, Codable, Sendable {
    case stopped, starting, loadingModels, ready, stopping, failed
}

public struct StartupEvent: Codable, Sendable {
    public var state: ServiceState
    public var message: String
    public var voices: [String]
    public init(state: ServiceState, message: String, voices: [String] = []) {
        self.state = state
        self.message = message
        self.voices = voices
    }

    /// Only enabled by the supervisor. Never write management data for standalone invocations.
    public static func report(_ state: ServiceState, _ message: String, voices: [String] = []) {
        guard let path = ProcessInfo.processInfo.environment["SPEECH_SERVER_STATUS_FILE"] else { return }
        let event = StartupEvent(state: state, message: message, voices: voices)
        do { try JSONEncoder().encode(event).write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { FileHandle.standardError.write(Data("Unable to report startup status: \(error)\n".utf8)) }
    }
}

public enum ManagementAction: String, Codable, Sendable {
    case status, start, stop, restart, logs, configuration, validate, save, restore, startup, prepareUpdate,
        cancelUpdate
}

public struct ManagementRequest: Codable, Sendable {
    public var version = 1
    public var action: ManagementAction
    public var yaml: String?
    public var revision: String?
    public var enabled: Bool?
    public init(action: ManagementAction, yaml: String? = nil, revision: String? = nil, enabled: Bool? = nil) {
        self.action = action
        self.yaml = yaml
        self.revision = revision
        self.enabled = enabled
    }
}

public struct ServiceStatus: Codable, Sendable {
    public var state: ServiceState = .stopped
    public var message = "Service stopped."
    public var processID: Int32?
    public var activeConfig: ServerConfig?
    public var pendingChanges = false
    public var startAtLogin = true
    public var voices: [String] = []
    public init() {}
}

public struct ManagementResponse: Codable, Sendable {
    public var version = 1
    public var error: String?
    public var status: ServiceStatus?
    public var configuration: ConfigurationDocument?
    public var logs: String?
    public init(
        error: String? = nil, status: ServiceStatus? = nil, configuration: ConfigurationDocument? = nil,
        logs: String? = nil
    ) {
        self.error = error
        self.status = status
        self.configuration = configuration
        self.logs = logs
    }
    public func checked() throws -> Self {
        guard version == 1 else { throw ManagementError("Unsupported management protocol version.") }
        if let error { throw ManagementError(error) }
        return self
    }
}

public struct RestartPolicy: Sendable {
    private var retries = 0
    public init() {}
    public mutating func shouldRetry(wasReady: Bool) -> Bool {
        guard wasReady, retries < 3 else { return false }
        retries += 1
        return true
    }
}

public struct AppPaths: Sendable {
    public let support: URL
    public let logs: URL
    public let runtime: URL
    public var socket: String { runtime.appendingPathComponent("control.sock").path }
    public var status: URL { runtime.appendingPathComponent("startup.json") }
    public var settings: URL { support.appendingPathComponent("management.json") }
    public init(support: URL, logs: URL, runtime: URL) {
        self.support = support
        self.logs = logs
        self.runtime = runtime
    }
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        support = home.appendingPathComponent("Library/Application Support/Speech Server")
        logs = home.appendingPathComponent("Library/Logs/Speech Server")
        // Short enough for sockaddr_un even when the user's home path is long.
        runtime = URL(fileURLWithPath: "/tmp/org.dokterbob.speech-server-\(getuid())", isDirectory: true)
    }

    public func prepare() throws {
        for directory in [support, logs, runtime] {
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
                info.st_mode & S_IFMT == S_IFDIR
            else {
                throw ManagementError("Unsafe or inaccessible management directory: \(directory.path)")
            }
            guard chmod(directory.path, 0o700) == 0 else { throw ManagementError("Cannot protect \(directory.path)") }
        }
    }
}
