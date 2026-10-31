import AVFoundation
import AppKit
import Foundation
import SpeechServerManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var status = ServiceStatus()
    @Published var config = ServerConfig()
    @Published var yaml = ""
    @Published var revision = ""
    @Published var logs = ""
    @Published var error: String?
    @Published var busy = false
    @Published var connected = false
    @Published var onboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")
    @Published var startAtLogin = true
    @Published var shareOnNetwork = false
    @Published var testText = "Hello! Your speech server is ready."
    @Published var transcript = ""
    @Published var savedMessage = ""
    var player: AVAudioPlayer?
    private var polling: Task<Void, Never>?
    private func registration() throws -> LaunchAgentController {
        try AppInstallation.controller(for: Bundle.main.bundleURL)
    }

    init() {
        polling = Task { [weak self] in
            do { try await self?.registration().reconcile() }
            catch { self?.error = error.localizedDescription }
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    nonisolated static func send(_ request: ManagementRequest) async throws -> ManagementResponse {
        try await Task.detached { try LocalSocket.request(request) }.value
    }

    func refresh() async {
        do {
            let response = try await Self.send(ManagementRequest(action: .status))
            if let current = response.status { status = current }
            connected = true
            if revision.isEmpty, !onboarding { try await load() }
        }
        catch { connected = false }
    }

    func load() async throws {
        if let document = try await Self.send(ManagementRequest(action: .configuration)).configuration {
            config = document.config
            yaml = document.yaml
            revision = document.revision
            savedMessage = ""
            if let issue = document.validationError {
                error = "Settings are invalid. Repair the YAML or restore the previous version: \(issue)"
            }
        }
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await operation()
                await refresh()
            }
            catch { self.error = error.localizedDescription }
        }
    }

    func register() async throws {
        try await registration().enable()
        for _ in 0..<30 {
            if (try? await Self.send(ManagementRequest(action: .status))) != nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ManagementError(
            "The background service has not started. Check its approval in System Settings, then try again.")
    }

    func setup() {
        perform {
            try await self.register()
            let initial = try await Self.send(ManagementRequest(action: .configuration))
            guard let revision = initial.configuration?.revision else { throw ManagementError("Cannot read settings.") }
            if self.shareOnNetwork {
                self.config.servers.http.host = "0.0.0.0"
                self.config.servers.wyoming.host = "0.0.0.0"
            }
            let yaml = try ConfigurationDocument.encode(self.config)
            _ = try await Self.send(ManagementRequest(action: .save, yaml: yaml, revision: revision))
            _ = try await Self.send(ManagementRequest(action: .startup, enabled: self.startAtLogin))
            _ = try await Self.send(ManagementRequest(action: .start))
            UserDefaults.standard.set(true, forKey: "onboardingComplete")
            self.onboarding = false
            try await self.load()
        }
    }

    func command(_ action: ManagementAction) {
        perform { _ = try await Self.send(ManagementRequest(action: action)) }
    }

    func save(raw: Bool = false, restart: Bool = false) {
        perform {
            let text = raw ? self.yaml : try ConfigurationDocument.encode(self.config)
            let response = try await Self.send(ManagementRequest(action: .save, yaml: text, revision: self.revision))
            if let document = response.configuration {
                self.revision = document.revision
                self.yaml = document.yaml
                self.config = document.config
            }
            self.savedMessage = "Settings saved. Restart the service to apply changes."
            if restart {
                _ = try await Self.send(ManagementRequest(action: .restart))
                self.savedMessage = "Settings saved. Restarting…"
            }
        }
    }

    func restore() {
        perform {
            _ = try await Self.send(ManagementRequest(action: .restore, revision: self.revision))
            try await self.load()
            self.savedMessage = "Previous settings restored. Start or restart to apply them."
        }
    }

    func disableBackgroundService() {
        perform {
            try await self.registration().disable()
            self.connected = false
        }
    }

    func approvalSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    var localEndpoint: URL? {
        guard let active = status.activeConfig else { return nil }
        let host = active.servers.http.host
        let local = ["0.0.0.0", "::"].contains(host) ? "localhost" : host
        var components = URLComponents()
        components.scheme = "http"
        components.host = local
        components.port = active.servers.http.port
        return components.url
    }

    var networkName: String { Host.current().localizedName ?? "your-mac" }

    func playSpeech() {
        perform {
            guard let endpoint = self.localEndpoint else { throw ManagementError("Start the service first.") }
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/audio/speech"))
            request.httpMethod = "POST"
            request.timeoutInterval = 180
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "tts-1", "input": self.testText, "response_format": "wav",
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data: data)
            self.player = try AVAudioPlayer(data: data)
            self.player?.play()
        }
    }

    func transcribeFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            guard let endpoint = self.localEndpoint else { throw ManagementError("Start the service first.") }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 50 * 1024 * 1024 else {
                throw ManagementError("Choose a test audio file smaller than 50 MB.")
            }
            let boundary = UUID().uuidString
            var body = Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"test.\(url.pathExtension.filter { $0.isLetter || $0.isNumber })\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                    .utf8)
            body.append(try Data(contentsOf: url))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/audio/transcriptions"))
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data: data)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            self.transcript = object?["text"] as? String ?? String(decoding: data, as: UTF8.self)
        }
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ManagementError(String(decoding: data.prefix(4096), as: UTF8.self))
        }
    }
}
