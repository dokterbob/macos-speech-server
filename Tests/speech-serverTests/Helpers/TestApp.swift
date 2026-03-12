import Foundation
import XCTVapor
import XCTest

@testable import speech_server

// ---------------------------------------------------------------------------
// Shared singleton — creates and configures the test app once per process.
// Subsequent calls return the same instance (model loading is slow on first
// run; once cached on disk, initialization is fast but still non-trivial).
// ---------------------------------------------------------------------------

// Strong reference to the shutdown observer — XCTestObservationCenter holds observers weakly,
// so without this the observer would be released immediately after registration.
nonisolated(unsafe) private var _shutdownObserver: AppShutdownObserver?

private let _appTask: Task<Application, Error> = Task {
    // Suppress the CWD speech-server.yaml so tests always use built-in defaults.
    // Write a minimal valid YAML file ({} = empty mapping → all fields use defaults)
    // and point SPEECH_SERVER_CONFIG at it. Cannot use /dev/null — not readable in sandbox.
    let tempConfig = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "speech-server-test-\(ProcessInfo.processInfo.processIdentifier).yaml")
    try "{}\n".write(to: tempConfig, atomically: true, encoding: .utf8)
    setenv("SPEECH_SERVER_CONFIG", tempConfig.path, 1)
    let app = try await Application.make(.testing)
    do {
        try await configure(app)
    }
    catch {
        // If configure() throws, the app will be released without shutdown, triggering
        // ServeCommand's deinit assertion. Explicitly shut it down first.
        try? await app.asyncShutdown()
        throw error
    }
    // Register shutdown observer so ServeCommand's deinit assertion is satisfied
    // when the shared app is released at process exit. Must retain it ourselves because
    // XCTestObservationCenter only holds a weak reference. Registration must happen
    // on the main thread (XCTestObservationCenter requirement).
    let observer = AppShutdownObserver()
    _shutdownObserver = observer
    await MainActor.run {
        XCTestObservationCenter.shared.addTestObserver(observer)
    }
    return app
}

/// Returns the shared, fully-configured test `Application`.
/// The app is initialized once; concurrent callers wait on the same Task.
func sharedTestApp() async throws -> Application {
    try await _appTask.value
}

// ---------------------------------------------------------------------------
// Lifecycle — call asyncShutdown() when the XCTest bundle finishes.
// Application.make() registers a ServeCommand with a deinit assertion that
// fires (SIGTRAP) if asyncShutdown() was not called before deinit.
// ---------------------------------------------------------------------------

private final class AppShutdownObserver: NSObject, XCTestObservation {
    func testBundleDidFinish(_ testBundle: Bundle) {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            if let app = try? await _appTask.value {
                try? await app.asyncShutdown()
            }
            sema.signal()
        }
        sema.wait()
    }
}

// ---------------------------------------------------------------------------
// Multipart body helpers
// ---------------------------------------------------------------------------

/// Builds a multipart/form-data body from plain text fields and one file part.
func makeMultipartBody(
    boundary: String,
    file: Data,
    filename: String,
    contentType: String = "audio/wav",
    fields: [(name: String, value: String)] = []
) -> Data {
    let crlf = "\r\n"
    var body = Data()

    for field in fields {
        body += "--\(boundary)\(crlf)".utf8Data
        body += "Content-Disposition: form-data; name=\"\(field.name)\"\(crlf)\(crlf)".utf8Data
        body += "\(field.value)\(crlf)".utf8Data
    }

    body += "--\(boundary)\(crlf)".utf8Data
    body += "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)".utf8Data
    body += "Content-Type: \(contentType)\(crlf)\(crlf)".utf8Data
    body += file
    body += crlf.utf8Data
    body += "--\(boundary)--\(crlf)".utf8Data
    return body
}

extension String {
    fileprivate var utf8Data: Data { Data(utf8) }
}

// ---------------------------------------------------------------------------
// Word-overlap similarity (for round-trip tests)
// ---------------------------------------------------------------------------

/// Jaccard similarity on word sets (lowercase, whitespace-split).
/// Returns a value in [0, 1]; 1.0 = identical word sets.
func wordOverlapRatio(original: String, transcribed: String) -> Double {
    func words(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty })
    }
    let a = words(original)
    let b = words(transcribed)
    let union = a.union(b)
    guard !union.isEmpty else { return 1.0 }
    return Double(a.intersection(b).count) / Double(union.count)
}
