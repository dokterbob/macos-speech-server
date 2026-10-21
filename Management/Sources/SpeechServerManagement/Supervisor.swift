import Darwin
import Foundation

struct AgentSettings: Codable {
    var startAtLogin = true
    var desiredRunning = false
    var session = ""
    var updatePending = false
}

/// The actor is the sole owner of the server process and all managed configuration writes.
public actor Supervisor {
    private let paths: AppPaths
    private let executable: URL
    private let store: ConfigurationStore
    private let logger: RotatingLog
    private var settings: AgentSettings
    private var process: Process?
    private var status = ServiceStatus()
    private var policy = RestartPolicy()
    private var stopping = false
    private var generation = UUID()

    public init(executable: URL, paths: AppPaths = AppPaths()) throws {
        self.paths = paths
        self.executable = executable
        try paths.prepare()
        store = ConfigurationStore(directory: paths.support)
        logger = try RotatingLog(directory: paths.logs)
        settings =
            (try? JSONDecoder().decode(AgentSettings.self, from: Data(contentsOf: paths.settings)))
            ?? AgentSettings(session: Self.loginSession())
    }

    private static func loginSession() -> String {
        var info = auditinfo_addr()
        guard getaudit_addr(&info, Int32(MemoryLayout.size(ofValue: info))) == 0 else { return "unknown" }
        var boot = timeval()
        var size = MemoryLayout.size(ofValue: boot)
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return "\(info.ai_asid)" }
        return "\(boot.tv_sec):\(info.ai_asid)"
    }

    public func boot() throws {
        let session = Self.loginSession()
        if settings.session != session {
            settings.session = session
            settings.desiredRunning = settings.startAtLogin
        }
        // Re-registration after an app update preserves the prior running/stopped intent.
        settings.updatePending = false
        try persist()
        if settings.desiredRunning {
            do { try start() }
            catch {
                status.state = .failed
                status.message = error.localizedDescription
                throw error
            }
        }
    }

    public func handle(_ request: ManagementRequest) async -> ManagementResponse {
        do {
            guard request.version == 1 else { throw ManagementError("Unsupported management protocol version.") }
            switch request.action {
            case .status: break
            case .configuration:
                return ManagementResponse(configuration: try store.read())
            case .validate:
                guard let yaml = request.yaml else { throw ManagementError("YAML is required.") }
                return ManagementResponse(configuration: try ConfigurationDocument(yaml: yaml))
            case .save:
                guard let yaml = request.yaml, let revision = request.revision else {
                    throw ManagementError("YAML and expected revision are required.")
                }
                return ManagementResponse(configuration: try store.save(yaml: yaml, expectedRevision: revision))
            case .restore:
                guard let revision = request.revision else { throw ManagementError("Expected revision is required.") }
                return ManagementResponse(configuration: try store.restore(expectedRevision: revision))
            case .start:
                policy = RestartPolicy()
                try start()
            case .stop:
                settings.desiredRunning = false
                try persist()
                try await stop()
            case .restart:
                try await stop()
                policy = RestartPolicy()
                try start()
            case .startup:
                guard let enabled = request.enabled else { throw ManagementError("An enabled value is required.") }
                settings.startAtLogin = enabled
                try persist()
            case .logs:
                return ManagementResponse(logs: logger.tail())
            case .prepareUpdate:
                settings.updatePending = true
                try persist()
                try await stop()
            case .cancelUpdate:
                settings.updatePending = false
                try persist()
                if settings.desiredRunning { try start() }
            }
            return ManagementResponse(status: snapshot())
        }
        catch {
            if [.start, .restart].contains(request.action), process == nil {
                status.state = .failed
                status.message = error.localizedDescription
            }
            return ManagementResponse(error: error.localizedDescription, status: snapshot())
        }
    }

    public func shutdown() async {
        try? await stop()
    }

    private func persist() throws {
        try JSONEncoder().encode(settings).write(to: paths.settings, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.settings.path)
    }

    private func snapshot() -> ServiceStatus {
        if let process, process.isRunning, !stopping,
            let data = try? Data(contentsOf: paths.status),
            let event = try? JSONDecoder().decode(StartupEvent.self, from: data)
        {
            status.state = event.state
            status.message = event.message
            status.voices = event.voices
        }
        status.startAtLogin = settings.startAtLogin
        if let active = status.activeConfig, let saved = try? store.read() {
            status.pendingChanges = saved.validationError != nil || active != saved.config
        }
        return status
    }

    private func start() throws {
        guard !stopping else { throw ManagementError("Wait for the service to finish stopping.") }
        guard process == nil else { return }
        let document = try store.read()
        if let error = document.validationError { throw ManagementError(error) }
        try document.config.validate()
        try PortCheck.check(host: document.config.servers.http.host, port: document.config.servers.http.port)
        try PortCheck.check(host: document.config.servers.wyoming.host, port: document.config.servers.wyoming.port)
        settings.desiredRunning = true
        try persist()
        try? FileManager.default.removeItem(at: paths.status)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["serve"]
        child.currentDirectoryURL = paths.support
        // Explicit environment: do not inherit HTTP/CLI overrides into the managed instance.
        var environment: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SPEECH_SERVER_CONFIG": store.fileURL.path,
            "SPEECH_SERVER_STATUS_FILE": paths.status.path,
        ]
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] { environment["TMPDIR"] = temporary }
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        let logger = logger
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            else {
                logger.append(data)
            }
        }
        let run = UUID()
        generation = run
        child.terminationHandler = { child in
            Task { await self.exited(run: run, code: child.terminationStatus) }
        }
        status.state = .starting
        status.message = "Starting speech server…"
        status.voices = []
        status.activeConfig = document.config
        do {
            try child.run()
            process = child
            status.processID = child.processIdentifier
        }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            status.state = .failed
            status.message = error.localizedDescription
            throw error
        }
    }

    private func stop() async throws {
        guard !stopping else { throw ManagementError("The service is already stopping.") }
        guard let child = process else {
            generation = UUID()
            status.state = .stopped
            status.message = "Service stopped."
            return
        }
        stopping = true
        defer { stopping = false }
        status.state = .stopping
        status.message = "Stopping speech server…"
        if child.isRunning { child.terminate() }
        for _ in 0..<100 {
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if child.isRunning {
            logger.append(Data("Graceful shutdown timed out; terminating server.\n".utf8))
            kill(child.processIdentifier, SIGKILL)
            for _ in 0..<20 {
                if !child.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard !child.isRunning else { throw ManagementError("Server did not stop. See logs before retrying.") }
        generation = UUID()
        process = nil
        status.processID = nil
        status.state = .stopped
        status.message = "Service stopped."
        status.voices = []
    }

    private func exited(run: UUID, code: Int32) async {
        guard run == generation, !stopping else { return }
        var previous = snapshot()
        if let data = try? Data(contentsOf: paths.status),
            let event = try? JSONDecoder().decode(StartupEvent.self, from: data)
        {
            previous.state = event.state
            previous.message = event.message
        }
        process = nil
        status.processID = nil
        status.state = .failed
        status.message = previous.state == .failed ? previous.message : "Server exited (\(code)). See logs for details."
        status.voices = []
        if settings.desiredRunning, !settings.updatePending, policy.shouldRetry(wasReady: previous.state == .ready) {
            status.message = "Server exited; retrying in two seconds…"
            try? await Task.sleep(for: .seconds(2))
            guard run == generation, settings.desiredRunning, process == nil, !settings.updatePending else { return }
            do { try start() }
            catch { status.message = error.localizedDescription }
        }
    }
}

/// A single lock serializes output callbacks, reads, and bounded file rotation.
final class RotatingLog: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let previous: URL
    private var handle: FileHandle
    private var size: UInt64
    private let limit: UInt64 = 2 * 1024 * 1024
    init(directory: URL) throws {
        url = directory.appendingPathComponent("speech-server.log")
        previous = directory.appendingPathComponent("speech-server.log.1")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try FileHandle(forWritingTo: url)
        size = try handle.seekToEnd()
    }
    deinit { try? handle.close() }
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if size + UInt64(data.count) > limit {
                try handle.close()
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: url, to: previous)
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                handle = try FileHandle(forWritingTo: url)
                size = 0
            }
            let bounded = data.suffix(Int(limit))
            try handle.write(contentsOf: bounded)
            size += UInt64(bounded.count)
        }
        catch { FileHandle.standardError.write(Data("Log write failed: \(error)\n".utf8)) }
    }
    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let reader = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? reader.close() }
        let end = (try? reader.seekToEnd()) ?? 0
        try? reader.seek(toOffset: end > 131072 ? end - 131072 : 0)
        return String(decoding: (try? reader.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
