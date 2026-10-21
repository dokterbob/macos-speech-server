import Foundation

public enum ManagementCLI {
    public static let usage = """
        Manage the optional Speech Server app (no speech models are loaded):
          speech-server service --app status|start|stop|restart|logs [--json]
          speech-server service --app enable|disable [--json]
          speech-server service --app startup on|off [--json]
          speech-server config validate FILE [--json]
          speech-server config --app show [--json]
          speech-server config --app save FILE --revision REVISION [--json]
          speech-server config --app restore --revision REVISION [--json]

        App service commands use the current user's private management socket.
        Use 'brew services' to manage the standalone Homebrew formula.
        """

    /// Returns false for existing Vapor commands, preserving their argument handling.
    public static func run(arguments: [String]) throws -> Bool {
        guard let group = arguments.first, ["service", "config"].contains(group) else { return false }
        if arguments.contains("--help") || arguments.count == 1 {
            print(usage)
            return true
        }
        var args = Array(arguments.dropFirst())
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        let app = args.contains("--app")
        args.removeAll { $0 == "--app" }
        guard let command = args.first else { throw ManagementError(usage) }
        args.removeFirst()
        let response: ManagementResponse
        if group == "service", app, ["enable", "disable"].contains(command), args.isEmpty {
            try backgroundRegistration(enable: command == "enable")
            if json {
                print("{\"version\":1,\"success\":true}")
            }
            else {
                print("Background service \(command)d.")
            }
            return true
        }
        if group == "config", command == "validate" {
            guard args.count == 1 else { throw ManagementError(usage) }
            let yaml = try String(contentsOfFile: args[0], encoding: .utf8)
            response = ManagementResponse(configuration: try ConfigurationDocument(yaml: yaml))
        }
        else {
            guard app else { throw ManagementError("Specify --app to target the app-managed service.\n" + usage) }
            let request: ManagementRequest
            if group == "service" {
                if command == "startup" {
                    guard args.count == 1, ["on", "off"].contains(args[0]) else { throw ManagementError(usage) }
                    request = ManagementRequest(action: .startup, enabled: args[0] == "on")
                }
                else {
                    guard args.isEmpty, let action = ManagementAction(rawValue: command),
                        [.status, .start, .stop, .restart, .logs].contains(action)
                    else { throw ManagementError(usage) }
                    request = ManagementRequest(action: action)
                }
            }
            else {
                switch command {
                case "show":
                    guard args.isEmpty else { throw ManagementError(usage) }
                    request = ManagementRequest(action: .configuration)
                case "save":
                    guard args.count == 3, args[1] == "--revision" else { throw ManagementError(usage) }
                    request = ManagementRequest(
                        action: .save, yaml: try String(contentsOfFile: args[0], encoding: .utf8), revision: args[2])
                case "restore":
                    guard args.count == 2, args[0] == "--revision" else { throw ManagementError(usage) }
                    request = ManagementRequest(action: .restore, revision: args[1])
                default: throw ManagementError(usage)
                }
            }
            response = try LocalSocket.request(request)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(response), as: UTF8.self))
        }
        else if let logs = response.logs {
            print(logs, terminator: "")
        }
        else if let document = response.configuration {
            print(document.yaml, terminator: "")
            print("\nRevision: \(document.revision)")
        }
        else if let status = response.status {
            print("\(status.state.rawValue): \(status.message)")
            print("Start at login: \(status.startAtLogin ? "on" : "off")")
            if status.pendingChanges { print("Saved settings will apply after restart.") }
        }
        return true
    }
    private static func backgroundRegistration(enable: Bool) throws {
        let bundle = try AppInstallation.locate()
        let process = Process()
        process.executableURL = bundle.appendingPathComponent("Contents/MacOS/SpeechServerApp")
        process.arguments = [enable ? "--enable-background" : "--disable-background"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ManagementError("Background registration failed. Open the app to check approval.")
        }
    }
}
