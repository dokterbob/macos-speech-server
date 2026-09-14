import AppKit
import SpeechServerManagement
import SwiftUI

struct SpeechServerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Speech Server", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 760, minHeight: 620)
        }
        MenuBarExtra(
            "Speech Server",
            systemImage: model.connected && model.status.state == .ready ? "waveform.circle.fill" : "waveform.circle"
        ) {
            MenuContent().environmentObject(model)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(model.connected ? model.status.message : "Background service unavailable")
        Button("Open Speech Server") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Start Service") { model.command(.start) }.disabled(!model.connected || model.busy)
        Button("Stop Service") { model.command(.stop) }.disabled(!model.connected || model.busy)
        Divider()
        Button("Quit App (keep service running)") { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = "Overview"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Speech Server").font(.title2.bold())
                    Text(model.connected ? model.status.message : "Local speech, on your Mac")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy || [.starting, .loadingModels, .stopping].contains(model.status.state) {
                    ProgressView().controlSize(.small)
                }
            }.padding()
            Divider()
            if model.onboarding {
                onboarding
            }
            else {
                TabView(selection: $tab) {
                    overview.tabItem { Label("Overview", systemImage: "gauge.medium") }.tag("Overview")
                    settings.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag("Settings")
                    testing.tabItem { Label("Try Speech", systemImage: "play.circle") }.tag("Try Speech")
                    logView.tabItem { Label("Logs", systemImage: "doc.text") }.tag("Logs")
                    advanced.tabItem { Label("YAML", systemImage: "curlybraces") }.tag("YAML")
                }.padding()
            }
            if let error = model.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") {
                        model.error = nil
                    }
                }.padding().background(.orange.opacity(0.08))
            }
        }
    }

    private var onboarding: some View {
        Form {
            Section {
                Text("Set up your local speech service").font(.title.bold())
                Text(
                    "Transcribe audio and generate speech privately. Once models are downloaded, speech runs entirely on this Mac."
                )
                Text(
                    "First setup downloads roughly 700 MB with the default engines. Other engines may require up to 1.75 GB per model. Loading can take several minutes."
                )
                .foregroundStyle(.secondary)
            }
            engineFields
            Section("Background operation") {
                Toggle("Start the service when I log in", isOn: $model.startAtLogin)
                Text("Closing the app leaves the service running. Use Stop Service to stop speech processing.").font(
                    .caption)
            }
            Section("Other devices") {
                Toggle("Share with devices on my local network", isOn: $model.shareOnNetwork)
                if model.shareOnNetwork { sharingNotice }
            }
            Section {
                Button("Set Up & Start") { model.setup() }.buttonStyle(.borderedProminent).disabled(model.busy)
                Button("Open Login Items Settings") { model.approvalSettings() }
                migrationLink
            }
        }.formStyle(.grouped)
    }

    private var overview: some View {
        Form {
            Section("Service") {
                LabeledContent("Status", value: model.connected ? model.status.state.rawValue : "Unavailable")
                if model.status.pendingChanges {
                    Text("Saved settings are waiting for a restart.").foregroundStyle(.orange)
                }
                HStack {
                    Button("Start") { model.command(.start) }
                    Button("Stop") { model.command(.stop) }
                    Button("Restart") { model.command(.restart) }
                }.disabled(!model.connected || model.busy)
                if !model.connected {
                    Button("Enable Background Service") {
                        model.perform {
                            try await model.register()
                            try await model.load()
                        }
                    }
                    Button("Open Login Items Settings") { model.approvalSettings() }
                }
                Toggle(
                    "Start service at login",
                    isOn: Binding(
                        get: { model.status.startAtLogin },
                        set: { value in
                            model.perform {
                                _ = try await AppModel.send(ManagementRequest(action: .startup, enabled: value))
                            }
                        })
                ).disabled(!model.connected || model.busy)
                Button("Disable Background Service", role: .destructive) { model.disableBackgroundService() }.disabled(
                    model.busy)
            }
            Section("Connect") {
                if let active = model.status.activeConfig {
                    Text("HTTP: \(model.localEndpoint?.absoluteString ?? "")/v1").textSelection(.enabled)
                    Text(
                        "Wyoming port: \(active.servers.wyoming.port == 0 ? "disabled" : String(active.servers.wyoming.port))"
                    )
                    if !["127.0.0.1", "localhost", "::1"].contains(active.servers.wyoming.host) {
                        Text(
                            "In Home Assistant: Settings → Devices & services → Add integration → Wyoming Protocol. Enter this Mac’s local network IP address and port \(active.servers.wyoming.port)."
                        )
                    }
                    ForEach(NetworkAddresses.localIPv4, id: \.self) { address in
                        if !["127.0.0.1", "localhost", "::1"].contains(active.servers.http.host) {
                            Text("Network HTTP: http://\(address):\(active.servers.http.port)/v1").textSelection(
                                .enabled)
                        }
                        if active.servers.wyoming.port > 0,
                            !["127.0.0.1", "localhost", "::1"].contains(active.servers.wyoming.host)
                        {
                            Text("Home Assistant host: \(address) · port: \(active.servers.wyoming.port)")
                                .textSelection(.enabled)
                        }
                    }
                    Text(
                        "Find this Mac’s IP address in System Settings → Network → your connection → Details. Use that address on other devices; localhost only works on this Mac."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                migrationLink
            }
            Section("Updates") {
                Text("Installed and updated with Homebrew.")
                Text("brew upgrade \(AppInstallation.formula)").font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(
                    "After upgrading, quit and reopen this app. Its background service will restart with the new version while preserving whether speech was running or stopped."
                ).font(.caption)
                Text("Before uninstalling the app formula, use Disable Background Service above.").font(.caption)
            }
        }.formStyle(.grouped)
    }

    private var settings: some View {
        VStack {
            Form {
                engineFields
                Section("Network") {
                    TextField("HTTP host", text: $model.config.servers.http.host)
                    TextField("HTTP port", value: $model.config.servers.http.port, format: .number.grouping(.never))
                    TextField("Wyoming host", text: $model.config.servers.wyoming.host)
                    TextField(
                        "Wyoming port (0 disables)", value: $model.config.servers.wyoming.port,
                        format: .number.grouping(.never))
                    sharingNotice
                }
                Section("Advanced") {
                    TextField(
                        "Upload limit (MB)", value: $model.config.servers.http.uploadLimitMB,
                        format: .number.grouping(.never))
                    Picker("Log level", selection: $model.config.logLevel) {
                        ForEach(["trace", "debug", "info", "notice", "warning", "error", "critical"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
            }.formStyle(.grouped)
            saveButtons(raw: false)
        }
    }

    @ViewBuilder private var engineFields: some View {
        Section("Transcription") {
            Picker("Engine", selection: $model.config.stt.engine) {
                Text("Parakeet — fast, multilingual").tag(STTEngine.parakeet)
                Text("Qwen3 — language hints").tag(STTEngine.qwen3)
            }
            if model.config.stt.engine == .parakeet {
                Picker(
                    "Model",
                    selection: Binding(
                        get: { model.config.stt.parakeet?.modelVersion ?? "v3" },
                        set: { value in
                            if model.config.stt.parakeet == nil { model.config.stt.parakeet = ParakeetSettings() }
                            model.config.stt.parakeet?.modelVersion = value
                        })
                ) {
                    Text("v3 — multilingual").tag("v3")
                    Text("v2 — English").tag("v2")
                }
            }
            else {
                Picker(
                    "Model size",
                    selection: Binding(
                        get: { model.config.stt.qwen3?.variant ?? "int8" },
                        set: { value in
                            if model.config.stt.qwen3 == nil { model.config.stt.qwen3 = Qwen3STTSettings() }
                            model.config.stt.qwen3?.variant = value
                        })
                ) {
                    Text("Compact (~900 MB)").tag("int8")
                    Text("Full precision (~1.75 GB)").tag("f32")
                }
                TextField(
                    "Language hint (e.g. en; blank for auto)",
                    text: Binding(
                        get: { model.config.stt.qwen3?.language ?? "" },
                        set: { value in
                            if model.config.stt.qwen3 == nil { model.config.stt.qwen3 = Qwen3STTSettings() }
                            model.config.stt.qwen3?.language = value.isEmpty ? nil : value
                        }))
            }
        }
        Section("Speech synthesis") {
            Picker("Engine", selection: $model.config.tts.engine) {
                Text("PocketTTS — Alba").tag(TTSEngine.pocketTts)
                Text("macOS voices — no download").tag(TTSEngine.avspeech)
                Text("Kokoro — 50 voices").tag(TTSEngine.kokoro)
            }
            if model.config.tts.engine == .pocketTts {
                Toggle(
                    "Remove emoji before speaking",
                    isOn: Binding(
                        get: { model.config.tts.pocketTts?.sanitizeEmoji ?? true },
                        set: { value in
                            if model.config.tts.pocketTts == nil { model.config.tts.pocketTts = PocketTtsSettings() }
                            model.config.tts.pocketTts?.sanitizeEmoji = value
                        }))
            }
            else {
                TextField("Default voice (blank for engine default)", text: voiceBinding)
                if model.status.activeConfig?.tts.engine == model.config.tts.engine, !model.status.voices.isEmpty {
                    Picker("Available voices", selection: voiceBinding) {
                        Text("Engine default").tag("")
                        ForEach(model.status.voices, id: \.self) { Text($0).tag($0) }
                    }
                }
                else {
                    Text("Available voices appear after starting this engine.").font(.caption)
                }
                if model.config.tts.engine == .avspeech {
                    TextField(
                        "Sample rate (Hz)",
                        value: Binding(
                            get: { model.config.tts.avspeech?.sampleRate ?? 22050 },
                            set: { value in
                                if model.config.tts.avspeech == nil { model.config.tts.avspeech = AVSpeechSettings() }
                                model.config.tts.avspeech?.sampleRate = value
                            }), format: .number.grouping(.never))
                }
            }
        }
    }

    private var voiceBinding: Binding<String> {
        Binding(
            get: {
                model.config.tts.engine == .kokoro
                    ? (model.config.tts.kokoro?.defaultVoice ?? "") : (model.config.tts.avspeech?.defaultVoice ?? "")
            },
            set: { value in
                if model.config.tts.engine == .kokoro {
                    if model.config.tts.kokoro == nil { model.config.tts.kokoro = KokoroSettings() }
                    model.config.tts.kokoro?.defaultVoice = value.isEmpty ? nil : value
                }
                else {
                    if model.config.tts.avspeech == nil { model.config.tts.avspeech = AVSpeechSettings() }
                    model.config.tts.avspeech?.defaultVoice = value.isEmpty ? nil : value
                }
            })
    }

    private var testing: some View {
        Form {
            Section("Text to speech") {
                TextEditor(text: $model.testText).frame(minHeight: 100)
                Button("Speak") { model.playSpeech() }.disabled(
                    model.status.state != .ready || model.busy || model.testText.isEmpty)
            }
            Section("Speech to text") {
                Button("Choose Audio File…") { model.transcribeFile() }.disabled(
                    model.status.state != .ready || model.busy)
                Text(model.transcript.isEmpty ? "The transcript will appear here." : model.transcript).textSelection(
                    .enabled)
            }
        }.formStyle(.grouped)
    }

    private var logView: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Refresh Logs") {
                    model.perform { model.logs = try await AppModel.send(ManagementRequest(action: .logs)).logs ?? "" }
                }
                Button("Reveal Log Folder") { NSWorkspace.shared.open(AppPaths().logs) }
            }
            ScrollView {
                Text(model.logs.isEmpty ? "No logs loaded." : model.logs).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding()
    }

    private var advanced: some View {
        VStack(alignment: .leading) {
            Text(
                "Edit YAML directly to preserve comments. Saving from the Settings form rewrites the document; the previous version is retained."
            ).font(.caption)
            TextEditor(text: $model.yaml).font(.system(.body, design: .monospaced))
            saveButtons(raw: true)
        }.padding()
    }

    private func saveButtons(raw: Bool) -> some View {
        VStack {
            if !model.savedMessage.isEmpty { Text(model.savedMessage).font(.caption) }
            HStack {
                Button("Reload") { model.perform { try await model.load() } }
                Button("Restore Previous") { model.restore() }
                Spacer()
                Button("Save") { model.save(raw: raw) }
                Button("Save & Restart") { model.save(raw: raw, restart: true) }.buttonStyle(.borderedProminent)
            }.disabled(model.busy || !model.connected || model.revision.isEmpty)
        }.padding()
    }

    private var sharingNotice: some View {
        Text(
            "Network speech endpoints have no authentication. Share only on a trusted local network, and do not forward these ports to the internet. Management remains private to this Mac."
        )
        .font(.caption).foregroundStyle(.secondary)
    }
    private var migrationLink: some View {
        Link(
            "Already using the Homebrew CLI? Installation and migration guide",
            destination: URL(string: "https://github.com/dokterbob/macos-speech-server/blob/main/docs/mac-app.md")!)
    }
}
