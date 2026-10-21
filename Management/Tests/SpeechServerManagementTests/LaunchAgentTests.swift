import Darwin
import Foundation
import Testing

@testable import SpeechServerManagement

private actor LaunchctlStub {
    var loaded = false
    var commands: [[String]] = []
    var actions: [ManagementAction] = []
    var failBootstrap = false
    var failBootout = false

    func run(_ arguments: [String]) -> LaunchctlResult {
        commands.append(arguments)
        switch arguments.first {
        case "print": return LaunchctlResult(status: loaded ? 0 : 113)
        case "bootstrap":
            if failBootstrap { return LaunchctlResult(status: 5, output: "Input/output error") }
            loaded = true
        case "bootout":
            if failBootout { return LaunchctlResult(status: 5, output: "Input/output error") }
            loaded = false
        default: break
        }
        return LaunchctlResult(status: 0)
    }
    func request(_ request: ManagementRequest) -> ManagementResponse {
        actions.append(request.action)
        return ManagementResponse()
    }
    func setLoaded(_ value: Bool) { loaded = value }
    func setFailBootstrap() { failBootstrap = true }
    func setFailBootout() { failBootout = true }
}

struct LaunchAgentTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("Space and 'quotes'/Speech Server.app")
        let binary = bundle.appendingPathComponent("Contents/MacOS/speech-server-agent")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (root, bundle)
    }

    private func controller(
        _ root: URL, _ bundle: URL, _ stub: LaunchctlStub, build: String = "1"
    ) -> LaunchAgentController {
        LaunchAgentController(
            bundleURL: bundle, buildID: build, homeDirectory: root,
            runner: { await stub.run($0) }, client: { await stub.request($0) })
    }

    @Test func installIsIdempotentAndDisableRemovesOnlyOwnAgent() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = LaunchctlStub()
        let service = controller(root, bundle, stub)
        try await service.enable()
        let values = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: service.plistURL), format: nil)
                as? [String: Any])
        #expect(
            values["ProgramArguments"] as? [String] == [
                bundle.appendingPathComponent("Contents/MacOS/speech-server-agent").path
            ])
        #expect(values["BundleProgram"] == nil)
        #expect(values["RunAtLoad"] as? Bool == true)
        try await service.enable()
        let commands = await stub.commands
        #expect(commands.filter { $0.first == "bootstrap" }.count == 1)
        let unrelated = service.plistURL.deletingLastPathComponent().appendingPathComponent("unrelated.plist")
        try Data("untouched".utf8).write(to: unrelated)
        try await service.disable()
        #expect(!service.isInstalled)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(await stub.actions == [.stop])
    }

    @Test func upgradeReconcilesWithoutChangingRunningIntent() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = LaunchctlStub()
        try await controller(root, bundle, stub).enable()
        let upgraded = controller(root, bundle, stub, build: "2")
        try await upgraded.reconcile()
        #expect(await stub.actions == [.prepareUpdate])
        let commands = await stub.commands
        #expect(commands.filter { $0.first == "enable" }.count == 1)
        #expect(commands.filter { $0.first == "bootstrap" }.count == 2)
        #expect(await stub.loaded)
        try await upgraded.reconcile()
        #expect(await stub.actions == [.prepareUpdate])
    }

    @Test func reconcileDoesNotInstallOrReenableDisabledService() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = LaunchctlStub()
        let initial = controller(root, bundle, stub)
        try await initial.reconcile()
        #expect(!initial.isInstalled)
        try await initial.enable()
        await stub.setLoaded(false)
        try await controller(root, bundle, stub, build: "2").reconcile()
        #expect(await stub.actions.isEmpty)
        #expect(await stub.commands.filter { $0.first == "bootstrap" }.count == 1)
    }

    @Test func failedUnloadResumesPreviousAgent() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = LaunchctlStub()
        let initial = controller(root, bundle, stub)
        try await initial.enable()
        let original = try Data(contentsOf: initial.plistURL)
        await stub.setFailBootout()
        await #expect(throws: (any Error).self) {
            try await controller(root, bundle, stub, build: "2").reconcile()
        }
        #expect(await stub.actions == [.prepareUpdate, .cancelUpdate])
        #expect(await stub.loaded)
        #expect(try Data(contentsOf: initial.plistURL) == original)
    }

    @Test func bootstrapErrorsAreVisibleAndCanBeRetried() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = LaunchctlStub()
        await stub.setFailBootstrap()
        let service = controller(root, bundle, stub)
        await #expect(throws: (any Error).self) { try await service.enable() }
        #expect(service.isInstalled)
        #expect(!(await stub.loaded))
    }

    @Test func neverReplacesAnotherAgentsPlistOrSymlink() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = LaunchctlStub()
        let service = controller(root, bundle, stub)
        try FileManager.default.createDirectory(
            at: service.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "someone.else"], format: .xml, options: 0)
        try foreign.write(to: service.plistURL)
        await #expect(throws: (any Error).self) { try await service.enable() }
        #expect(try Data(contentsOf: service.plistURL) == foreign)
        try FileManager.default.removeItem(at: service.plistURL)
        let target = root.appendingPathComponent("foreign.plist")
        try foreign.write(to: target)
        try FileManager.default.createSymbolicLink(at: service.plistURL, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await service.disable() }
        #expect(try Data(contentsOf: target) == foreign)
    }

    @Test func cellarPathUsesStableOptSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keg = root.appendingPathComponent("Cellar/macos-speech-server-app/0.2.0")
        let bundle = keg.appendingPathComponent("libexec/Speech Server.app")
        let opt = root.appendingPathComponent("opt/macos-speech-server-app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: opt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: opt, withDestinationURL: keg)
        #expect(AppInstallation.stableBundle(bundle) == opt.appendingPathComponent("libexec/Speech Server.app"))
    }
}

extension LaunchAgentTests {
    @Test func concurrentEnableOnlyBootstrapsOnce() async throws {
        let (root, bundle) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = LaunchctlStub()
        let service = controller(root, bundle, stub)
        async let first: Void = service.enable()
        async let second: Void = service.enable()
        _ = try await (first, second)
        #expect(await stub.commands.filter { $0.first == "bootstrap" }.count == 1)
    }
}
