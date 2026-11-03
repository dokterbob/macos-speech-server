import NaturalLanguage
import Vapor

/// Validates the `language` form field of a transcription request.
///
/// Omitted or `auto` means automatic detection (`nil`). Any other value must be one of the STT engine's supported
/// ISO 639-1 codes (case-insensitive); anything else is rejected with 400 rather than silently ignored.
func transcriptionLanguageHint(_ requested: String?, supported: [String]) throws -> String? {
    guard let requested, requested != "auto" else { return nil }
    let code = requested.lowercased()
    guard supported.contains(code) else {
        throw Abort(
            .badRequest,
            reason:
                "Unsupported language '\(requested)'. Supported: \((["auto"] + supported.sorted()).joined(separator: ", "))."
        )
    }
    return code
}

/// The language reported in `verbose_json`: the request's hint when given, otherwise the dominant language of the
/// transcript (Apple Natural Language), or `und` when it cannot be determined.
func reportedLanguage(hint: String?, transcript: String) -> String {
    hint ?? NLLanguageRecognizer.dominantLanguage(for: transcript)?.rawValue ?? "und"
}
