# Agent Guide

Essential knowledge for AI agents working on this codebase.

## Project overview

A macOS-native HTTP server that exposes OpenAI-compatible speech API endpoints, running entirely on-device. Built with Vapor (Swift web framework) and FluidAudio (on-device ASR via Apple's Neural Engine).

- **STT** is fully implemented using FluidAudio's `AsrManager`.
- **TTS** is stubbed -- `StubTTSService` returns silent WAV data. Real implementation is pending.

## Tech stack

| Component | Library | Version constraint |
|-----------|---------|-------------------|
| Web framework | [Vapor](https://github.com/vapor/vapor) | 4.76.0+ |
| Speech-to-text | [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.7.9+ |

**Platform:** macOS 14+, Swift 6.2

## Documentation resources

When working on this project, use these MCP tools for up-to-date documentation:

### Context7 (preferred for Vapor)

Use the Context7 MCP to query library docs. Resolve library IDs first, then query.

| Library | Context7 ID |
|---------|-------------|
| Vapor | `/websites/vapor_codes` |
| FluidAudio | `/fluidinference/fluidaudio` |

Example workflow:
1. Call `mcp__context7__query-docs` with `libraryId: "/websites/vapor_codes"` and your question.
2. For FluidAudio: `libraryId: "/fluidinference/fluidaudio"`.

### DeepWiki (recommended for FluidAudio)

FluidAudio is a newer library with less community documentation. Use the DeepWiki MCP to explore its internals:

- `mcp__deepwiki__read_wiki_structure` with `repoName: "FluidInference/FluidAudio"` to browse topics.
- `mcp__deepwiki__ask_question` with `repoName: "FluidInference/FluidAudio"` for specific questions.

## Architecture

### Middleware chain (order matters)

1. `RequestLoggingMiddleware` -- logs `METHOD /path STATUS` at NOTICE level
2. `OpenAIErrorMiddleware` -- catches errors, returns OpenAI-format JSON

### Service layer (dependency injection)

Services are registered on `Application.storage` and accessed via computed properties on `Request` and `Application`:

```swift
req.sttService   // -> STTService protocol
req.ttsService   // -> TTSService protocol
app.sttService = FluidSTTService()  // setter on Application
```

Both protocols require `Sendable` conformance.

### Route registration

Routes are registered twice in `routes.swift` -- once at `/audio/*` and once at `/v1/audio/*` for OpenAI API compatibility. Both `SpeechController` and `TranscriptionController` implement `RouteCollection`.

### FluidAudio integration

`FluidSTTService` wraps FluidAudio's `AsrManager`:

1. On init: downloads ASR models v3 (slow on first run, cached after).
2. On transcribe: determines the correct file extension via `audioFileExtension(filename:data:)` -- first from the filename, then from magic byte sniffing (WAV, FLAC, MP3, M4A, AIFF); falls back to `.wav`. Writes audio `Data` to a temp file with that extension (required by `AVAudioFile` inside `AudioConverter`), calls `asrManager.transcribe(url, source: .system)`, cleans up.
3. Returns `TranscriptionResult` (text + duration) -- not a bare `String`.
4. Must call `initialize()` before first use -- will throw `FluidSTTError.notInitialized` otherwise.

`AsrManager.transcribe` resamples audio to 16 kHz mono Float32 internally; no pre-processing is needed. Use `source: .system` for file/API transcription, `source: .microphone` for live capture.

### Error handling

All errors are caught by `OpenAIErrorMiddleware` and returned as:

```json
{
  "error": {
    "message": "...",
    "type": "invalid_request_error | server_error",
    "param": null,
    "code": null
  }
}
```

## Build and run

```bash
swift build
swift run speech-server
```

## Conventions

- **Async middleware**: use `AsyncMiddleware` protocol (not the `EventLoopFuture`-based `Middleware`).
- **Request body decoding**: Controllers use `req.content.decode()` for JSON, multipart is handled via `TranscriptionRequest` with `File` fields.
- **Upload limit**: set to 25MB for the transcription endpoint via `app.routes.defaultMaxBodySize`.
- **Logging**: use `request.logger` in request context, `app.logger` during setup. Log level is set to `.notice` in `configure.swift` to suppress Vapor's internal debug noise. All operational log calls (request details, transcription progress) use `.notice`; use `.warning` or above for anomalies. Services that need their own logger (e.g. `FluidSTTService`) create a `Logger(label:)` instance with `logLevel` set explicitly.
- **STTService protocol**: `transcribe(audioData:filename:)` returns `TranscriptionResult` (with `text` and `duration`), not a plain `String`. The `verbose_json` response includes a `segments` array matching the OpenAI API shape.
- **Audio format detection**: `File.contentType` in Vapor is derived from the filename extension, not the multipart `Content-Type` header -- it will be `nil` for files without an extension. Always use `audioFileExtension(filename:data:)` in `FluidSTTService` to determine the temp file extension.
