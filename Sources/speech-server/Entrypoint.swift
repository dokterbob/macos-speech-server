import SpeechServerManagement
import Vapor

@main
enum Entrypoint {
    static func main() async {
        do { try await run() }
        catch {
            if CommandLine.arguments.contains("--json"),
                ["service", "config"].contains(CommandLine.arguments.dropFirst().first ?? "")
            {
                let response = ManagementResponse(error: error.localizedDescription)
                if let data = try? JSONEncoder().encode(response) {
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                }
            }
            else {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            }
            exit(1)
        }
    }

    private static func run() async throws {
        if try ManagementCLI.run(arguments: Array(CommandLine.arguments.dropFirst())) { return }
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        do {
            try await configure(app)
            try await app.startup()
            if app.running != nil {
                StartupEvent.report(.ready, "Ready to serve speech.", voices: app.ttsService.availableVoices)
            }
            try await app.running?.onStop.get()
        }
        catch {
            StartupEvent.report(.failed, error.localizedDescription)
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
