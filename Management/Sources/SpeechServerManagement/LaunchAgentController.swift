import Darwin
import Foundation

public struct LaunchctlResult: Sendable {
    public var status: Int32
    public var output: String
    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

/// A conventional per-user LaunchAgent: no privileged helper or Developer ID required.
/// All process arguments are passed directly, never interpolated into a shell command.
public struct LaunchAgentController: Sendable {
    public static let label = "org.dokterbob.speech-server.agent"
    public typealias Runner = @Sendable ([String]) async throws -> LaunchctlResult
    public typealias Client = @Sendable (ManagementRequest) async throws -> ManagementResponse
    public let bundleURL: URL
    public let buildID: String
    public let homeDirectory: URL
    public let userID: UInt32
    private let runner: Runner
    private let client: Client

    public var plistURL: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }
    public var domain: String { "gui/\(userID)" }
    public var target: String { "\(domain)/\(Self.label)" }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    public init(
        bundleURL: URL,
        buildID: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: UInt32 = getuid(),
        runner: @escaping Runner = LaunchAgentController.runLaunchctl,
        client: @escaping Client = { request in
            try await Task.detached { try LocalSocket.request(request) }.value
        }
    ) {
        self.bundleURL = bundleURL
        self.buildID = buildID
        self.homeDirectory = homeDirectory
        self.userID = userID
        self.runner = runner
        self.client = client
    }

    public func plistData() throws -> Data {
        let support = homeDirectory.appendingPathComponent("Library/Application Support/Speech Server")
        let logs = homeDirectory.appendingPathComponent("Library/Logs/Speech Server")
        let values: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [bundleURL.appendingPathComponent("Contents/MacOS/speech-server-agent").path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ExitTimeOut": 15,
            "ProcessType": "Background",
            "WorkingDirectory": support.path,
            "StandardOutPath": logs.appendingPathComponent("agent.log").path,
            "StandardErrorPath": logs.appendingPathComponent("agent.log").path,
            "AssociatedBundleIdentifiers": ["org.dokterbob.speech-server"],
            "EnvironmentVariables": ["SPEECH_SERVER_BUILD_ID": buildID],
        ]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    public func isLoaded() async throws -> Bool {
        try await runner(["print", target]).status == 0
    }

    /// Called only on explicit Enable/Setup. It can re-enable a previously disabled job.
    public func enable() async throws {
        try await withRegistrationLock { try await enableLocked() }
    }

    private func enableLocked() async throws {
        guard userID != 0 else { throw ManagementError("Run the app as your normal login user, not root.") }
        guard
            FileManager.default.isExecutableFile(
                atPath: bundleURL.appendingPathComponent("Contents/MacOS/speech-server-agent").path)
        else {
            throw ManagementError("The installed app's background executable is missing. Reinstall the app formula.")
        }
        try checkOwnership()
        let loaded = try await isLoaded()
        if loaded, try matchesInstalledVersion() { return }
        if loaded { try await unloadPreservingIntent() }
        try writePlist()
        try await requireSuccess(["enable", target])
        try await requireSuccess(["bootstrap", domain, plistURL.path])
    }

    /// On app launch, reconcile an enabled older installation after brew upgrade.
    /// Never install a service or override a user's disabled background item automatically.
    public func reconcile() async throws {
        try await withRegistrationLock { try await reconcileLocked() }
    }

    private func reconcileLocked() async throws {
        guard isInstalled else { return }
        try checkOwnership()
        guard try await isLoaded(), try !matchesInstalledVersion() else { return }
        try await unloadPreservingIntent()
        try writePlist()
        try await requireSuccess(["bootstrap", domain, plistURL.path])
    }

    public func disable() async throws {
        try await withRegistrationLock { try await disableLocked() }
    }

    private func disableLocked() async throws {
        guard userID != 0 else { throw ManagementError("Run this command as your normal login user, not root.") }
        try checkOwnership()
        if try await isLoaded() {
            // A failed management connection must not prevent removing a broken agent.
            _ = try? await client(ManagementRequest(action: .stop))
            try await requireSuccess(["bootout", target])
        }
        if isInstalled { try FileManager.default.removeItem(at: plistURL) }
    }

    private func unloadPreservingIntent() async throws {
        // If the running agent cannot acknowledge shutdown, leave it intact and report the error.
        _ = try await client(ManagementRequest(action: .prepareUpdate)).checked()
        do {
            try await requireSuccess(["bootout", target])
        }
        catch {
            _ = try? await client(ManagementRequest(action: .cancelUpdate))
            throw error
        }
    }

    private func matchesInstalledVersion() throws -> Bool {
        guard isInstalled else { return false }
        let installed =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? NSDictionary
        let desired = try PropertyListSerialization.propertyList(from: plistData(), format: nil) as? NSDictionary
        return installed == desired
    }

    private func checkOwnership() throws {
        guard isInstalled else { return }
        var info = stat()
        guard lstat(plistURL.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            throw ManagementError("Refusing to change an unsafe LaunchAgent file: \(plistURL.path)")
        }
        let existing =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        guard existing?["Label"] as? String == Self.label else {
            throw ManagementError("A different service occupies the app's LaunchAgent path.")
        }
    }

    private func writePlist() throws {
        let manager = FileManager.default
        for path in ["Library/LaunchAgents", "Library/Application Support/Speech Server", "Library/Logs/Speech Server"]
        {
            try manager.createDirectory(
                at: homeDirectory.appendingPathComponent(path), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try plistData().write(to: plistURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    private func withRegistrationLock(_ operation: () async throws -> Void) async throws {
        let directory = homeDirectory.appendingPathComponent("Library/Application Support/Speech Server")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("registration.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManagementError("Cannot lock background-service registration.") }
        defer { close(descriptor) }
        for _ in 0..<200 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                defer { _ = flock(descriptor, LOCK_UN) }
                try await operation()
                return
            }
            guard errno == EWOULDBLOCK else { throw ManagementError("Cannot lock background-service registration.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ManagementError("Another background-service operation is still in progress. Try again shortly.")
    }

    private func requireSuccess(_ arguments: [String]) async throws {
        let result = try await runner(arguments)
        guard result.status == 0 else {
            throw ManagementError(
                "Background service command failed (\(result.status)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines)). Check Login Items & Extensions and the app's agent.log."
            )
        }
    }

    public static func runLaunchctl(_ arguments: [String]) async throws -> LaunchctlResult {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return LaunchctlResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

public enum AppInstallation {
    public static let formula = "dokterbob/macos-speech-server/macos-speech-server-app"

    public static func controller(for bundle: URL) throws -> LaunchAgentController {
        let info =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil)
            as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "org.dokterbob.speech-server" else {
            throw ManagementError("Not a Speech Server app bundle.")
        }
        return LaunchAgentController(
            bundleURL: stableBundle(bundle), buildID: info?["SpeechServerBuildID"] as? String ?? "development")
    }

    /// Resolve an Applications alias or versioned Cellar bundle back to Homebrew's stable opt path.
    /// Deriving the prefix avoids embedding build-machine paths in signed bundle metadata.
    public static func stableBundle(_ bundle: URL) -> URL {
        let resolved = bundle.resolvingSymlinksInPath()
        let components = resolved.pathComponents
        guard components.count >= 5, components[components.count - 5] == "Cellar",
            components[components.count - 4] == "macos-speech-server-app"
        else { return bundle }
        var prefix = resolved
        for _ in 0..<5 { prefix.deleteLastPathComponent() }
        let stable = prefix.appendingPathComponent("opt/macos-speech-server-app/libexec/Speech Server.app")
        return stable.resolvingSymlinksInPath() == resolved ? stable : bundle
    }

    public static func locate() throws -> URL {
        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/opt/macos-speech-server-app/libexec/Speech Server.app"),
            URL(fileURLWithPath: "/usr/local/opt/macos-speech-server-app/libexec/Speech Server.app"),
            URL(fileURLWithPath: "/Applications/Speech Server.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Speech Server.app"),
        ]
        // Supports non-default Homebrew prefixes when called through the bundled CLI.
        if Bundle.main.bundleURL.pathExtension == "app" { candidates.insert(Bundle.main.bundleURL, at: 0) }
        guard
            let bundle = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
            })
        else {
            throw ManagementError("Install the app with: brew install \(formula)")
        }
        return bundle
    }
}
