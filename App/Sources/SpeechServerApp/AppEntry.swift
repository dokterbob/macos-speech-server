import AppKit
import SpeechServerManagement
import SwiftUI

@main
enum AppEntry {
    @MainActor static func main() async {
        if let action = CommandLine.arguments.dropFirst().first,
            ["--enable-background", "--disable-background"].contains(action)
        {
            do {
                let registration = try AppInstallation.controller(for: Bundle.main.bundleURL)
                if action == "--enable-background" {
                    try await registration.enable()
                }
                else {
                    try await registration.disable()
                }
                print("Background service \(action == "--enable-background" ? "enabled" : "disabled").")
                exit(0)
            }
            catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        SpeechServerApp.main()
    }
}
