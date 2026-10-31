import Foundation
import Testing

@testable import SpeechServerManagement

struct ManagementTests {
    @Test func testPartialConfigAndValidation() throws {
        let config = try ConfigurationDocument.decode("stt:\n  engine: parakeet\n")
        #expect(config.servers.http.port == 8080)
        #expect(config.tts.engine == .pocketTts)
        var invalid = config
        invalid.servers.http.port = 70_000
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = config
        invalid.stt.parakeet = ParakeetSettings()
        invalid.stt.parakeet?.modelVersion = "invalid"
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test func testAtomicSaveConflictAndRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root)
        let first = try store.read()
        let changed = "# User comment\nservers:\n  http:\n    port: 9090\n"
        let saved = try store.save(yaml: changed, expectedRevision: first.revision)
        #expect(saved.config.servers.http.port == 9090)
        #expect(saved.yaml == changed)
        #expect(throws: (any Error).self) { try store.save(yaml: "{}", expectedRevision: first.revision) }
        let restored = try store.restore(expectedRevision: saved.revision)
        #expect(restored.config.servers.http.port == 8080)
        #expect(throws: (any Error).self) {
            try store.save(yaml: "servers:\n  http:\n    port: -1", expectedRevision: restored.revision)
        }
        #expect(try store.read().revision == restored.revision)
    }

    @Test func testExternalEditsAreDetected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root)
        let initial = try store.read()
        try Data("log_level: debug\n".utf8).write(to: store.fileURL, options: .atomic)
        #expect(throws: (any Error).self) { try store.save(yaml: "{}", expectedRevision: initial.revision) }
    }

    @Test func testProtocolRejectsUnknownVersionAndMalformedRequests() throws {
        let data = try JSONEncoder().encode(ManagementRequest(action: .status))
        let decoded = try JSONDecoder().decode(ManagementRequest.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.action == .status)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ManagementRequest.self, from: Data("{}".utf8)) }
    }

    @Test func testRetryPolicyIsBoundedAndStartupFailureDoesNotRetry() {
        var policy = RestartPolicy()
        let decisions = [
            policy.shouldRetry(wasReady: false),
            policy.shouldRetry(wasReady: true),
            policy.shouldRetry(wasReady: true),
            policy.shouldRetry(wasReady: true),
            policy.shouldRetry(wasReady: true),
        ]
        #expect(decisions == [false, true, true, true, false])
    }
}

extension ManagementTests {
    @Test func invalidExternalYAMLCanBeRepaired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root)
        _ = try store.read()
        try Data("stt: [broken".utf8).write(to: store.fileURL, options: .atomic)
        let invalid = try store.read()
        #expect(invalid.validationError != nil)
        let repaired = try store.save(yaml: "{}", expectedRevision: invalid.revision)
        #expect(repaired.validationError == nil)
    }

    @Test func supervisorStartsStopsAndPreservesIntent() async throws {
        let root = URL(fileURLWithPath: "/tmp/speech-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs"),
            runtime: root.appendingPathComponent("run"))
        try paths.prepare()
        let executable = root.appendingPathComponent("fake-server")
        let script = """
            #!/bin/sh
            printf '%s' '{"state":"ready","message":"Test ready","voices":["test"]}' > "$SPEECH_SERVER_STATUS_FILE"
            exec /bin/sleep 60
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let supervisor = try Supervisor(executable: executable, paths: paths)
        try await supervisor.boot()
        let initial = await supervisor.handle(ManagementRequest(action: .status))
        #expect(initial.status?.state == .stopped)
        // Use a high free port for preflight; the fake server does not bind a network listener.
        var config = ServerConfig()
        config.servers.http.port = 59463
        config.servers.wyoming.port = 0
        let store = ConfigurationStore(directory: paths.support)
        let document = try store.read()
        _ = try store.save(yaml: ConfigurationDocument.encode(config), expectedRevision: document.revision)
        let started = await supervisor.handle(ManagementRequest(action: .start))
        #expect(started.error == nil)
        for _ in 0..<30 {
            if await supervisor.handle(ManagementRequest(action: .status)).status?.state == .ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let ready = await supervisor.handle(ManagementRequest(action: .status))
        #expect(ready.status?.state == .ready)
        #expect(ready.status?.voices == ["test"])
        let stopped = await supervisor.handle(ManagementRequest(action: .stop))
        #expect(stopped.error == nil)
        #expect(stopped.status?.state == .stopped)
        #expect(stopped.status?.processID == nil)
        let relaunched = try Supervisor(executable: executable, paths: paths)
        try await relaunched.boot()
        let after = await relaunched.handle(ManagementRequest(action: .status))
        #expect(after.status?.state == .stopped)
        await supervisor.shutdown()
        await relaunched.shutdown()
    }

    @Test func localSocketRoundTripAndVersionRejection() async throws {
        let root = URL(fileURLWithPath: "/tmp/speech-socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("control.sock").path
        let descriptor = try LocalSocket.listen(path: socket)
        defer { close(descriptor) }
        let server = Task.detached {
            for _ in 0..<2 {
                try LocalSocket.serve(descriptor: descriptor) { _ in ManagementResponse(logs: "hello") }
            }
        }
        let response = try await Task.detached {
            try LocalSocket.request(ManagementRequest(action: .logs), path: socket)
        }.value
        #expect(response.logs == "hello")
        var unsupported = ManagementRequest(action: .status)
        unsupported.version = 2
        let request = unsupported
        await #expect(throws: (any Error).self) {
            try await Task.detached { try LocalSocket.request(request, path: socket) }.value
        }
        try await server.value
    }
}

extension ManagementTests {
    @Test func updatePreparationPreservesStoppedState() async throws {
        let root = URL(fileURLWithPath: "/tmp/speech-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs"),
            runtime: root.appendingPathComponent("run"))
        let supervisor = try Supervisor(executable: root.appendingPathComponent("missing-server"), paths: paths)
        try await supervisor.boot()
        let prepared = await supervisor.handle(ManagementRequest(action: .prepareUpdate))
        #expect(prepared.error == nil)
        let cancelled = await supervisor.handle(ManagementRequest(action: .cancelUpdate))
        #expect(cancelled.status?.state == .stopped)
        #expect(cancelled.error == nil)
        let restartedAgent = try Supervisor(executable: root.appendingPathComponent("missing-server"), paths: paths)
        try await restartedAgent.boot()
        #expect(await restartedAgent.handle(ManagementRequest(action: .status)).status?.state == .stopped)
    }

    @Test func occupiedPortHasActionableError() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(descriptor, 1) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        do {
            try PortCheck.check(host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)))
            Issue.record("An occupied port must fail preflight")
        }
        catch { #expect(error.localizedDescription.contains("Another service")) }
    }

    @Test func startupFailureIsReportedWithoutRetry() async throws {
        let root = URL(fileURLWithPath: "/tmp/speech-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs"),
            runtime: root.appendingPathComponent("run"))
        try paths.prepare()
        let executable = root.appendingPathComponent("fake-server")
        try "#!/bin/sh\nexit 42\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let supervisor = try Supervisor(executable: executable, paths: paths)
        let response = await supervisor.handle(ManagementRequest(action: .start))
        #expect(response.error == nil)
        for _ in 0..<30 {
            if await supervisor.handle(ManagementRequest(action: .status)).status?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let failed = await supervisor.handle(ManagementRequest(action: .status))
        #expect(failed.status?.state == .failed)
        #expect(failed.status?.message.contains("42") == true)
        #expect(failed.status?.processID == nil)
        await supervisor.shutdown()
    }
}
