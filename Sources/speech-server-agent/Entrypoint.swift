import Darwin
import Foundation
import SpeechServerManagement

@main
enum AgentEntrypoint {
    static func main() async throws {
        let paths = AppPaths()
        try paths.prepare()
        // A lifetime lock prevents duplicate agents and makes stale-socket removal safe.
        let lock = open(paths.runtime.appendingPathComponent("agent.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw ManagementError("Another Speech Server agent is already running.")
        }
        _ = fcntl(lock, F_SETFD, FD_CLOEXEC)
        defer { close(lock) }
        unlink(paths.socket)
        let descriptor = try LocalSocket.listen(path: paths.socket)
        defer {
            close(descriptor)
            unlink(paths.socket)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("speech-server")
        let supervisor = try Supervisor(executable: executable, paths: paths)
        do { try await supervisor.boot() }
        catch { FileHandle.standardError.write(Data("Startup: \(error.localizedDescription)\n".utf8)) }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signals = [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                Task {
                    await supervisor.shutdown()
                    unlink(paths.socket)
                    exit(0)
                }
            }
            source.resume()
            return source
        }
        try await Task.detached {
            while true {
                try LocalSocket.serve(descriptor: descriptor) { request in
                    let result = ResponseBox()
                    Task { result.finish(await supervisor.handle(request)) }
                    return result.wait()
                }
            }
        }.value
        withExtendedLifetime(signals) {}
    }
}

/// The synchronous socket worker waits here; the supervisor remains on Swift's executor.
private final class ResponseBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var response = ManagementResponse()
    func finish(_ response: ManagementResponse) {
        self.response = response
        semaphore.signal()
    }
    func wait() -> ManagementResponse {
        semaphore.wait()
        return response
    }
}
