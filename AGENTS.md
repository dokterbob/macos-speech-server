# Agent Guide

Essential knowledge for AI agents working on this codebase.

## Project overview

A macOS-native HTTP server that exposes OpenAI-compatible speech API endpoints, running entirely on-device. Built with Vapor (Swift web framework) and FluidAudio (on-device ASR via Apple's Neural Engine).

- **STT** is fully implemented using FluidAudio's `AsrManager`.
- **TTS** is fully implemented using FluidAudio's `PocketTtsManager`. Only the `alba` voice is available; requesting any other voice returns a 400.

## Tech stack

| Component | Library | Version constraint |
|-----------|---------|-------------------|
| Web framework | [Vapor](https://github.com/vapor/vapor) | 4.76.0+ |
| Speech-to-text | [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.7.9+ |
| Multipart parsing | [multipart-kit](https://github.com/vapor/multipart-kit) | 4.0.0+ |

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

### Transcription upload pipeline

`TranscriptionController` streams the request body directly to a temp file before any
multipart parsing, keeping peak RAM at O(chunk_size) during upload:

1. Body chunks are written via `OutputStream` to `<req.id>.multipart` in the temp directory.
   An in-flight byte counter rejects uploads exceeding **500 MB** with `413 Payload Too Large`.
2. The temp file is mmap-read (`Data(contentsOf:options:.mappedIfSafe)`) and decoded with
   `FormDataDecoder` from MultipartKit.
3. `audioFileExtension(filename:header:)` (see `AudioFormatDetection.swift`) determines the
   correct extension from the filename or the first 12 magic bytes of the parsed `ByteBuffer`.
4. The audio bytes are written to a second temp file (`<req.id><ext>`) with the correct
   extension, then passed as a URL to the STT service. The controller owns both temp files
   and cleans them up via `defer`.

### FluidAudio integration

`FluidSTTService` is a thin wrapper around FluidAudio's `AsrManager`:

1. On init: downloads ASR models v3 (slow on first run, cached after).
2. On transcribe: calls `asrManager.transcribe(audioURL, source: .system)` directly -- no
   temp file writing or format detection (that all happens in the controller).
3. Returns `TranscriptionResult` (text + duration) -- not a bare `String`.
4. Must call `initialize()` before first use -- will throw `FluidSTTError.notInitialized` otherwise.

`AsrManager.transcribe` resamples audio to 16 kHz mono Float32 internally; no pre-processing is needed. Use `source: .system` for file/API transcription, `source: .microphone` for live capture.

### FluidTTSService

`FluidTTSService` wraps FluidAudio's `PocketTtsManager`:

1. On init: downloads PocketTTS models (slow on first run, cached after).
2. On synthesize: calls `pocketTtsManager.synthesize(text:voice:)` -- returns WAV `Data`.
3. Must call `initialize()` before first use -- will throw `FluidTTSError.notInitialized` otherwise.
4. Catches `PocketTtsConstantsLoader.LoadError.fileNotFound` for `*_audio_prompt` files and
   re-throws as `FluidTTSError.voiceNotFound(voice)`. `SpeechController` converts this to a
   400 `Abort` with the message "Voice '\(voice)' is not available. Supported voices: alba."

The only built-in voice is `"alba"`. `SpeechRequest.resolvedVoice` defaults to `"alba"`.

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
- **Request body decoding**: The transcription endpoint uses `body: .stream` and manually streams to disk, then decodes with `FormDataDecoder` from MultipartKit. Other controllers use `req.content.decode()` for JSON.
- **Upload limit**: enforced mid-stream in `TranscriptionController` at **500 MB** via a running byte counter; throws `413 Payload Too Large` before the full body is buffered. Not set via `app.routes.defaultMaxBodySize`.
- **Logging**: use `request.logger` in request context, `app.logger` during setup. Log level is set to `.notice` in `configure.swift` to suppress Vapor's internal debug noise. All operational log calls (request details, transcription progress) use `.notice`; use `.warning` or above for anomalies. Services that need their own logger (e.g. `FluidSTTService`) create a `Logger(label:)` instance with `logLevel` set explicitly.
- **STTService protocol**: `transcribe(audioURL: URL)` returns `TranscriptionResult` (with `text` and `duration`), not a plain `String`. The URL points to a temp file with the correct audio extension, created and cleaned up by the controller. The `verbose_json` response includes a `segments` array matching the OpenAI API shape.
- **Audio format detection**: lives in `AudioFormatDetection.swift` as a package-internal free function `audioFileExtension(filename:header:)`. `header` is the first 12 bytes of the audio data (`Data`). Called from `TranscriptionController`, not from `FluidSTTService`. `File.contentType` in Vapor is derived from the filename extension and may be `nil` -- always use `audioFileExtension` instead.
- **TTS voice validation**: `FluidTTSService` catches `PocketTtsConstantsLoader.LoadError.fileNotFound` for missing `*_audio_prompt` assets and throws `FluidTTSError.voiceNotFound(voice)`. `SpeechController` catches this and throws `Abort(.badRequest)`. Do not let unknown voice errors reach `OpenAIErrorMiddleware` as unhandled 500s.
