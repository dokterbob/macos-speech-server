import Foundation
import XCTVapor

@testable import speech_server

// ---------------------------------------------------------------------------
// Shared singleton — creates and configures the test app once per process.
// Subsequent calls return the same instance (model loading is slow on first
// run; once cached on disk, initialization is fast but still non-trivial).
// ---------------------------------------------------------------------------

private let _appTask: Task<Application, Error> = Task {
    // Suppress the CWD speech-server.yaml so tests always use built-in defaults.
    // (configure() calls ServerConfig.load() which finds the file in the package root)
    let app = try await Application.make(.testing)
    try await configure(app)
    return app
}

/// Returns the shared, fully-configured test `Application`.
/// The app is initialized once; concurrent callers wait on the same Task.
func sharedTestApp() async throws -> Application {
    try await _appTask.value
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
