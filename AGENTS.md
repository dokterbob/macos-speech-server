# Agent Guide

Essential knowledge for AI agents working on this codebase.

## Project overview

A macOS-native HTTP server that exposes OpenAI-compatible speech API endpoints and a Wyoming protocol server for Home Assistant integration, running entirely on-device. Built with Vapor (Swift web framework) and FluidAudio (on-device ASR via Apple's Neural Engine).

- **STT** is fully implemented using FluidAudio's `AsrManager`.
- **TTS** is fully implemented using FluidAudio's `PocketTtsManager`. Only the `alba` voice is available; requesting any other voice returns a 400.

## Tech stack

| Component | Library | Version constraint |
|-----------|---------|-------------------|
| Web framework | [Vapor](https://github.com/vapor/vapor) | 4.76.0+ |
| Speech-to-text | [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.7.9+ |
| Multipart parsing | [multipart-kit](https://github.com/vapor/multipart-kit) | 4.0.0+ |
| YAML parsing | [Yams](https://github.com/jpsim/Yams) | 6.0.1+ |
| TCP networking | [swift-nio](https://github.com/apple/swift-nio) | 2.65.0+ |

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

### ServerConfig

`ServerConfig` (`ServerConfig.swift`) loads and stores all runtime settings. It is available on `Application` and `Request` via Vapor DI (`app.serverConfig` / `req.serverConfig`).

**Config discovery order** (first match wins):
1. `SPEECH_SERVER_CONFIG` env var — path to a YAML file
2. `./speech-server.yaml` in the current working directory
3. Built-in defaults (all fields have sensible defaults matching original hardcoded values)

**Engine enums** are exhaustive by design. Adding a new engine requires:
1. Add a `case` to `STTEngine` or `TTSEngine` (the raw value becomes the YAML key, e.g. `"parakeet"`)
2. Add a `XxxSettings` struct with `decodeIfPresent` defaults if the engine has settings
3. Add a `case` in `configure.swift`'s switch to construct and initialize the service
4. Implement the `STTService`/`TTSService` protocol

**`model_version` in `ParakeetSettings`**: mapped to `AsrModelVersion` in `configure.swift` and passed to `FluidSTTService.initialize(modelVersion:)`. Valid values: `"v3"` (Parakeet TDT 0.6B v3, multilingual, 25 languages, default) and `"v2"` (Parakeet TDT 0.6B v2, English-only, higher recall). Invalid values cause a startup error.

**Partial configs work**: all fields use `decodeIfPresent` with defaults, so a minimal `speech-server.yaml` with only `stt:\n  engine: parakeet` is valid.

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

`FluidSTTService` wraps FluidAudio's `AsrManager` and `VadManager`:

1. On init: downloads ASR models v3 and loads VAD model (slow on first run, cached after).
2. On transcribe: converts audio to 16 kHz mono Float32 via `DiskBackedAudioSampleSource`
   (streaming, O(chunk) RAM), runs VAD in 4096-sample chunks to find speech segments, then
   calls `asrManager.transcribe([Float], source: .system)` on each segment.
3. Returns `TranscriptionResult` (text + duration + words + segments) -- not a bare `String`.
4. Must call `initialize()` before first use -- will throw `FluidSTTError.notInitialized` otherwise.

**VAD streaming constraints:**
- The last chunk passed to `vadManager.processStreamingChunk` must be the *actual* sample
  count (not zero-padded to `chunkSize`). FluidAudio applies repeat-last-sample padding
  internally; passing zeros creates an artificial silence cliff that causes premature
  speech-end detection and shorter segments.
- `asrManager.transcribe` requires **>= 16,000 samples** (1 second). VAD segments shorter
  than this must be zero-padded to 16,000 before the call or it throws `ASRError.invalidAudioData`.
  Zero-padding the tail is safe -- the model handles trailing silence natively.

Use `source: .system` for file/API transcription, `source: .microphone` for live capture.

### FluidTTSService

`FluidTTSService` wraps FluidAudio's `PocketTtsManager`:

1. On init: downloads PocketTTS models (slow on first run, cached after).
2. On synthesize (`synthesize`): pre-processes text via the shared `detectSentences()` free function
   (see `SentenceDetection.swift`) to ensure every sentence ends with `.!?`, then passes the result
   to a **single** `manager.synthesize()` call. The library chunks at sentence boundaries (preferred
   over word boundaries), and Mimi state stays continuous across all chunks for seamless audio.
3. On streaming (`synthesizeStream`): splits text into sentences with `detectSentences()`, calls
   `manager.synthesizeDetailed()` once per sentence, yields raw 16-bit PCM chunks (no WAV
   header). Mimi state resets between sentences, which is imperceptible at natural breaks.
4. Must call `initialize()` before first use -- will throw `FluidTTSError.notInitialized` otherwise.
5. Catches `PocketTtsConstantsLoader.LoadError.fileNotFound` for `*_audio_prompt` files and
   re-throws as `FluidTTSError.voiceNotFound(voice)`.

The only built-in voice is `"alba"`. `SpeechRequest.resolvedVoice` defaults to `"alba"`.

**PocketTTS chunking gotcha**: when text exceeds 50 tokens PocketTTS splits it into chunks,
applying `normalizeText()` to each chunk (capitalises first letter, appends period). If a chunk
starts mid-sentence this produces prosodic restarts ("reads parts of words separately"). The fix
is to ensure the text arriving at `manager.synthesize()` already has terminal punctuation at
every sentence boundary so the library always prefers `.!?` splits over word-boundary splits.

**Speech response streaming**: `SpeechController` uses Vapor's `asyncStream` body with
`count: -1` (chunked transfer encoding). WAV responses include a 44-byte streaming header with
`0x7FFFFFFF` size placeholders; PCM responses stream raw int16 bytes. Voice validation is done
**before** the stream starts (via `guard voice == "alba"`) because once response headers are
sent the status code cannot be changed to 4xx.

### Wyoming protocol

The Wyoming server runs alongside the HTTP server on a single TCP port (default 10300). A single port serves both TTS and STT — the handler dispatches by incoming event type. Enabled by default; set `wyoming.port: 0` to disable.

**Wire format** — each event has up to 3 parts:
1. Header line: JSON + `\n`. Contains `type`, `version`, optionally `data_length` and `payload_length`.
2. Data section (optional): exactly `data_length` bytes of UTF-8 JSON with the event's data dict.
3. Payload section (optional): exactly `payload_length` raw bytes (binary, e.g. PCM audio).

Example: `{"type":"audio-chunk","version":"1.0.0","data_length":36,"payload_length":2048}\n{"rate":16000,"width":2,"channels":1}<2048 bytes>`

**Source files** (`Sources/speech-server/Wyoming/`):

| File | Purpose |
|------|---------|
| `WyomingEvent.swift` | `WyomingEvent` struct + `WyomingValue` enum (supports string/int/double/bool/null/array/object). `serialize()` produces wire bytes. |
| `WyomingFrameDecoder.swift` | Pure Swift state machine. `mutating func process(_ bytes: Data) -> [WyomingEvent]`. No NIO imports. |
| `WyomingWAVWriter.swift` | Accumulates PCM chunks; `makeWAV()` / `writeToTempFile()` for STT handoff. |
| `WyomingSession.swift` | `actor` combining TTS and STT. `handle(event:) -> AsyncStream<Data>` — state mutations are synchronous; TTS/STT I/O runs in Tasks that yield to the stream. |
| `WyomingNIOHandler.swift` | `ChannelInboundHandler` (thin NIO glue). Feeds bytes to `WyomingFrameDecoder`, iterates `AsyncStream` from session, writes each event to the channel immediately. |
| `WyomingServer.swift` | `ServerBootstrap` + `LifecycleHandler`. Binds single TCP port, creates session per connection. |

**Session state machine**:
```
idle ──synthesize──→ [call TTSService.synthesizeStream, send audio-start/chunk/stop] ──→ idle
idle ──synthesize-start──→ streamingSynthesize(voice, "")
streamingSynthesize ──synthesize-chunk──→ [splitCompleteSentences, send audio per sentence] ──→ streamingSynthesize(voice, remainder)
streamingSynthesize ──synthesize──→ [ignored, backward compat] (state unchanged)
streamingSynthesize ──synthesize-stop──→ [synthesize remaining buffer, send audio + synthesize-stopped] ──→ idle
idle ──transcribe──→ awaitingAudio
awaitingAudio ──audio-start──→ recording(WAVWriter)
recording ──audio-chunk──→ recording (append PCM)
recording ──audio-stop──→ [call STTService.transcribe, send transcript] ──→ idle
any state ──describe──→ [send info with both asr + tts capabilities] (state unchanged)
```

The `info` response advertises both `asr` and `tts` arrays so Home Assistant knows this single port handles both services. The TTS program includes `supports_synthesize_streaming: true` to advertise HA 2025.07+ streaming support.

**Streaming TTS**: `handle(event:)` returns `AsyncStream<Data>` (non-async). For `synthesize`, the stream yields `audio-start` + each `audio-chunk` + `audio-stop` incrementally as TTS chunks arrive — `audio-start` is withheld until the first chunk so a completely failed synthesis sends nothing. State mutations (e.g. `state = .awaitingAudio`) happen synchronously before the stream is returned, so callers can immediately make the next `handle` call without draining the stream first. All other event types pre-fill the stream synchronously and finish immediately.

**Config** (`wyoming` section in `speech-server.yaml`):
```yaml
wyoming:
  port: 10300   # 0 = disabled; default 10300
```

**Test files** (`Tests/speech-serverTests/`):

| File | What it tests | Models needed? |
|------|---------------|----------------|
| `WyomingConfigTests.swift` | YAML parsing, defaults, port 0 disable | No |
| `WyomingEventTests.swift` | serialize/deserialize, WyomingValue conversions, round-trip | No |
| `WyomingFrameDecoderTests.swift` | Header-only, with data, with payload, partial feeds, multi-event, reset | No |
| `WyomingWAVWriterTests.swift` | Valid WAV header bytes, multi-chunk, cleanup, custom sample rates | No |
| `WyomingSessionTests.swift` | describe→info, synthesize→audio sequence, STT flow, errors, streaming order, streaming synthesis (mock services) | No |
| `SentenceDetectionTests.swift` | `splitCompleteSentences` / `detectSentences` free functions | No |
| `Helpers/MockServices.swift` | `MockTTSService` + `MockSTTService` for session tests | No |

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

## Code formatting

All Swift code is formatted with `swift format` (bundled with Swift 6.2). Config is in `.swift-format` at the repo root (120-char line length, 4-space indent).

```bash
# Format everything in-place
swift format --in-place --recursive Sources/ Tests/

# Lint check (used by CI and the pre-commit hook)
swift format lint --strict --recursive Sources/ Tests/
```

**Pre-commit hook**: `scripts/pre-commit` rejects commits with unformatted staged `.swift` files.
Install with: `scripts/install-hooks.sh`

**CI**: `.github/workflows/swift-format.yml` runs the lint check on every push and PR to `main`.

**Important for agents**: always run `swift format --in-place --recursive Sources/ Tests/` before finishing any task that modifies Swift files. The CI check is strict and will fail the build if any file is not formatted.

**Snake_case CodingKeys**: `SpeechRequest` and `TranscriptionSegment` use explicit `CodingKeys` to map camelCase Swift properties to snake_case JSON fields (e.g. `responseFormat` → `"response_format"`). Do not revert to bare snake_case property names — the `AlwaysUseLowerCamelCase` lint rule will reject them.

## Build and run

```bash
swift build
swift run speech-server

# Load a specific config file
SPEECH_SERVER_CONFIG=speech-server.yaml swift run speech-server

# Config file in CWD is picked up automatically
swift run speech-server
```

## Testing

```bash
swift test                        # run all tests
swift build --build-tests         # compile only, useful to check for errors
swift test --filter ServerConfig  # run a specific test class
```

**Test structure** (`Tests/speech-serverTests/`):

| File | Type | Notes |
|------|------|-------|
| `Helpers/TestApp.swift` | Helper | `sharedTestApp()` singleton, multipart builder, word-overlap helper |
| `ServerConfigTests.swift` | Unit | YAML parsing, defaults — no models needed |
| `AudioFormatDetectionTests.swift` | Unit | `audioFileExtension()` — no models needed |
| `SpeechRequestTests.swift` | Unit | `SpeechRequest` resolved defaults — no models needed |
| `TranscriptionIntegrationTests.swift` | Integration | Real STT pipeline via Vapor test client |
| `SpeechIntegrationTests.swift` | Integration | Real TTS pipeline via Vapor test client |
| `RoundTripIntegrationTests.swift` | Integration | TTS→STT round-trip similarity check |
| `WyomingConfigTests.swift` | Unit | Wyoming YAML config — no models needed |
| `WyomingEventTests.swift` | Unit | Wyoming event serialize/parse — no models needed |
| `WyomingFrameDecoderTests.swift` | Unit | Wyoming frame decoder — no models needed |
| `WyomingWAVWriterTests.swift` | Unit | Wyoming WAV writer — no models needed |
| `WyomingSessionTests.swift` | Unit | Wyoming session with mock services — no models needed |
| `SentenceDetectionTests.swift` | Unit | `splitCompleteSentences` / `detectSentences` — no models needed |
| `Helpers/MockServices.swift` | Helper | MockTTSService + MockSTTService |

**First run**: integration tests load real FluidAudio models (STT + TTS). Model download takes several minutes; subsequent runs use the on-disk cache and start in seconds. The shared app singleton (`_appTask` in `TestApp.swift`) ensures models are initialized once per `swift test` invocation.

**Fixtures**: `Tests/speech-serverTests/Fixtures/test.wav` is a copy of the repo-root `test.wav`, accessed via `Bundle.module` in integration tests.

## CI

`.github/workflows/tests.yml` runs on every push and PR to `main`.

- **Runner**: `macos-15` with Swift 6.2 installed via `swift-actions/setup-swift@v2`.
- **Cache**: `.build` and `~/Library/Application Support/FluidAudio` (all model subdirectories) are cached by `actions/cache@v4` keyed on `Package.resolved`. A `restore-keys` fallback allows partial hits (models survive SPM-only changes).
- **Steps**: checkout → setup Swift → restore cache → `swift build --build-tests` → `swift test` (30 min timeout).
- **Concurrency**: redundant runs on rapid pushes are cancelled via `concurrency.cancel-in-progress: true`.
- **Cold-cache run**: model download + SPM compilation takes ~10-20 min. Warm-cache run: ~1-2 min.

## Conventions

- **Async middleware**: use `AsyncMiddleware` protocol (not the `EventLoopFuture`-based `Middleware`).
- **Request body decoding**: The transcription endpoint uses `body: .stream` and manually streams to disk, then decodes with `FormDataDecoder` from MultipartKit. Other controllers use `req.content.decode()` for JSON.
- **Upload limit**: enforced mid-stream in `TranscriptionController` using `req.application.serverConfig.server.uploadLimitMB` (default 500 MB); throws `413 Payload Too Large` before the full body is buffered. Not set via `app.routes.defaultMaxBodySize`.
- **Config**: `ServerConfig` is loaded in `configure()` from `SPEECH_SERVER_CONFIG` env var → `./speech-server.yaml` → built-in defaults. All engine-selection switches live in `configure.swift`; adding a new engine means adding a `case` there. Engine enum raw values match YAML keys (e.g. `parakeet`, `pocket_tts`).
- **Logging**: use `request.logger` in request context, `app.logger` during setup. Log level is set to `.notice` in `configure.swift` to suppress Vapor's internal debug noise. All operational log calls (request details, transcription progress) use `.notice`; use `.warning` or above for anomalies. Services that need their own logger (e.g. `FluidSTTService`) create a `Logger(label:)` instance with `logLevel` set explicitly.
- **STTService protocol**: `transcribe(audioURL: URL)` returns `TranscriptionResult` (with `text` and `duration`), not a plain `String`. The URL points to a temp file with the correct audio extension, created and cleaned up by the controller. The `verbose_json` response includes a `segments` array matching the OpenAI API shape.
- **Audio format detection**: lives in `AudioFormatDetection.swift` as a package-internal free function `audioFileExtension(filename:header:)`. `header` is the first 12 bytes of the audio data (`Data`). Called from `TranscriptionController`, not from `FluidSTTService`. `File.contentType` in Vapor is derived from the filename extension and may be `nil` -- always use `audioFileExtension` instead.
- **TTS voice validation**: `SpeechController` validates the voice with `guard voice == "alba"` before starting the stream (response headers already sent → can't return 4xx after). `FluidTTSService` still catches `PocketTtsConstantsLoader.LoadError.fileNotFound` and re-throws as `FluidTTSError.voiceNotFound` as a safety net for unknown errors, but this should only be reached if the guard is missing.
- **Keeping docs in sync**: When making any user-visible change (new endpoint, changed behaviour, new field, new error), update `README.md`. When making any architectural change (new service, new constraint, new convention, new gotcha), update `AGENTS.md`. Both files should be updated in the same commit as the code change.
- **TDD convention**: Unit tests are written BEFORE the implementation they cover. When implementing a feature, write the test file first (it will fail to compile until the implementation is added), then write the implementation. This ensures tests actually define the contract, not just document it.
