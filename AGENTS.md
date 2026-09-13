# Agent Guide

Essential knowledge for AI agents working on this codebase.

## Project overview

A macOS-native HTTP server that exposes OpenAI-compatible speech API endpoints and a Wyoming protocol server for Home Assistant integration, running entirely on-device. Built with Vapor (Swift web framework) and FluidAudio (on-device ASR via Apple's Neural Engine).

- **STT** is fully implemented using FluidAudio's `AsrManager`.
- **TTS** is fully implemented with three engines: `pocket_tts` (FluidAudio PocketTTS, `alba` only), `avspeech` (macOS built-in, 150+ voices), and `kokoro` (FluidAudio Kokoro, 50 voices across 8 languages).

## Tech stack

| Component | Library | Version constraint |
|-----------|---------|-------------------|
| Web framework | [Vapor](https://github.com/vapor/vapor) | 4.76.0+ |
| Speech-to-text / TTS | [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.12.4+ |
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
2. `./speech-server.yaml` in the current working directory (gitignored — copy from `speech-server.yaml.example`)
3. Built-in defaults (all fields have sensible defaults matching original hardcoded values)

**Struct hierarchy**:
```
ServerConfig
  ├─ logLevel: String              (top-level, CodingKey "log_level")
  ├─ servers: ServersConfig
  │   ├─ http: HTTPConfig          (host, port, uploadLimitMB)
  │   └─ wyoming: WyomingConfig    (host, port)
  ├─ stt: STTConfig                (engine, parakeet/qwen3 settings)
  └─ tts: TTSConfig                (engine, pocket_tts/avspeech/kokoro settings)
```

Access: `config.logLevel`, `config.servers.http.host`, `config.servers.wyoming.port`.

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

### Qwen3STTService

`Qwen3STTService` wraps FluidAudio's `Qwen3AsrManager` (encoder-decoder ASR, 30+ languages):

1. On init: takes optional `language` hint (ISO 639-1 code, e.g. `"en"`).
2. On initialize: downloads Qwen3 CoreML models via `Qwen3AsrModels.download(variant:)` (cached at `~/Library/Application Support/FluidAudio/Models/`), creates `Qwen3AsrManager()`, calls `manager.loadModels(from:)`.
3. On transcribe: converts audio to 16 kHz mono via `DiskBackedAudioSampleSource`, runs VAD to find speech segments (same as `FluidSTTService`), calls `manager.transcribe(audioSamples:language:)` on each segment. The 30-second max audio limit is enforced per segment.
4. Returns `TranscriptionResult` with segment-level timing from VAD but **no word-level timestamps** (Qwen3 returns plain text).
5. Must call `initialize()` before first use — will throw `Qwen3STTError.notInitialized` otherwise.
6. `@available(macOS 15, *)` — requires macOS 15+ for CoreML features used by Qwen3.
7. `@unchecked Sendable` because `Qwen3AsrManager` is an actor.

**Language hinting**: Unlike Parakeet (which auto-detects language with no way to override), Qwen3 accepts an explicit `language` parameter. Setting `language: "en"` forces English decoding, which can improve accuracy for non-American English accents (e.g. British English) by preventing the multilingual model from misinterpreting accent features as other languages.

**Model variants**: `Qwen3AsrVariant.int8` (~900 MB, default) and `.f32` (~1.75 GB). Configured via `variant` in YAML.

**Errors**: `Qwen3STTError.notInitialized`, `Qwen3STTError.audioConversionFailed(Error)`, `Qwen3STTError.audioTooShort`, `Qwen3STTError.unsupportedPlatform`.

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
**before** the stream starts (via `ttsService.availableVoices.contains(voice)`) because once
response headers are sent the status code cannot be changed to 4xx.

### AVSpeechTTSService

`AVSpeechTTSService` wraps macOS's `AVSpeechSynthesizer` (no model downloads, 150+ voices):

1. On init: enumerates `AVSpeechSynthesisVoice.speechVoices()`, builds a lowercase lookup map
   (short name and full identifier → canonical identifier), sets `defaultVoice` from settings
   or the system-locale default, reports `sampleRate` from settings (default 22050 Hz).
2. On synthesize (`synthesize`): resolves voice via lookup, creates an `AVSpeechUtterance`,
   calls `AVSpeechSynthesizer().write(utterance) { buffer in ... }`, accumulates all Float32
   samples per utterance, peak-normalises once via `float32ToPCM16()`, wraps in WAV.
3. On streaming (`synthesizeStream`): splits text into sentences with `detectSentences()`, runs
   `synthesizeFloatSamples` per sentence, yields one PCM chunk per sentence (no header).
   Splitting at sentence boundaries avoids the prosodic restart problem.
4. No stored `AVSpeechSynthesizer` — a new instance is created per `write()` call. All stored
   properties are immutable `let`, giving genuine (not `@unchecked`) `Sendable` conformance.

**Voice inventory is per login session**: `speechVoices()` only includes downloaded
Enhanced/Premium and MobileAsset voices when the process belongs to a user with an active GUI
login session -- enumeration goes through per-user agents (e.g. `com.apple.accessibility.axassetsd`)
that live in that user's launchd domain. Under a LaunchDaemon (including a `--sudo-service-user`
daemon, which has no GUI session either) only the ~74 legacy built-in compact voices under
`/System/Library/Speech/Voices` appear. Enhanced/Premium voices enumerate as separate names with
the quality suffix (e.g. `Daniel (Enhanced)`, `Zoe (Premium)`), and the voice identifier can
differ from the display name (e.g. `Jamie (Premium)` = `com.apple.voice.premium.en-GB.Malcolm`).
See "System mode only sees the built-in compact voices" under Distribution (Homebrew) below.

**`AVSpeechSynthesizer.write()` is asynchronous**: the call returns immediately; buffer callbacks
fire on a background thread. The zero-length buffer (`frameLength == 0`) signals completion.
The bridge class uses a `CheckedContinuation` to map this callback API to `async/await`.

**Multiple zero-length callbacks**: `write()` can fire the zero-length termination callback more
than once. The bridge class guards with `var resumed = false` and calls `continuation.resume()`
only on the first zero-length callback.

**Per-buffer normalisation causes ringing**: normalising each buffer independently amplifies
quiet tail buffers, producing low-frequency artefacts at utterance ends. The fix is to
accumulate _all_ Float32 samples for a sentence and normalise once with a single
`float32ToPCM16()` call.

**Voice lookup**: stores `[String: String]` (lowercase name/identifier → canonical identifier),
not `AVSpeechSynthesisVoice` objects (which are not `Sendable`). Siri voices are not
accessible via public AVFoundation APIs and will not appear in the enumeration. Personal Voice
support requires `requestPersonalVoiceAuthorization` and is tracked in issue #13.

**Errors**: `AVSpeechTTSError.voiceNotFound(String)` is thrown when the requested voice name
cannot be resolved via lookup. `AVSpeechTTSError.noAudioProduced` is thrown if the synthesiser
delivers zero samples (e.g. empty utterance after preprocessing).

### KokoroTTSService

`KokoroTTSService` wraps FluidAudio's `KokoroTtsManager` (50 voices, 8 languages, 24 kHz):

1. On init (`initialize(settings:)`): creates `KokoroTtsManager(defaultVoice:)`, calls `manager.initialize()` (downloads Kokoro CoreML models on first run, cached at `~/.cache/fluidaudio/Models/kokoro`), sets `defaultVoice` from settings or `TtsConstants.recommendedVoice` (`"af_heart"`).
2. On synthesize (`synthesize`): validates voice against `availableVoices`, calls `manager.synthesize()` which returns WAV data directly (no manual PCM conversion needed).
3. On streaming (`synthesizeStream`): validates voice first (returns stream that immediately throws on invalid voice), splits text into sentences with `detectSentences()`, calls `manager.synthesizeDetailed()` per sentence, collects all samples from `result.chunks.flatMap { $0.samples }`, converts via `float32ToPCM16()`, yields one PCM chunk per sentence.
4. Must call `initialize()` before first use — will throw `KokoroTTSError.notInitialized` otherwise.
5. `@unchecked Sendable` because `KokoroTtsManager` is not `Sendable`. All stored properties besides the manager are immutable.

**Voice list**: `TtsConstants.availableVoices` (50 voices, sorted alphabetically in `availableVoices` property). American English voices (`af_*`, `am_*`) are production quality; other languages are experimental.

**`manager.synthesize()` returns WAV directly**: unlike PocketTTS which returns raw samples via `synthesizeDetailed().samples`, `KokoroTtsManager.synthesize()` returns a complete WAV `Data`. For streaming, `synthesizeDetailed()` returns a `KokoroSynthesizer.SynthesisResult` with `chunks: [ChunkInfo]`, each with `samples: [Float]`.

**Errors**: `KokoroTTSError.notInitialized` and `KokoroTTSError.voiceNotFound(String)`.

### PCMConversion utilities

`PCMConversion.swift` provides two package-internal free functions shared by all TTS services:

- `float32ToPCM16(_ samples: [Float]) -> Data` — peak-normalises the sample batch (or uses
  1.0 if all samples are silent) and converts to little-endian Int16 PCM bytes.
- `makeWAV(pcmData:sampleRate:channels:bitsPerSample:) -> Data` — prepends a standard 44-byte
  RIFF/WAVE header. Used for non-streaming (complete) WAV responses.

### TTSService protocol

The protocol (`TTSService.swift`) now includes three additional requirements read by controllers:

```swift
var sampleRate: Int { get }        // e.g. 24_000 (FluidTTS/Kokoro) or 22_050 (AVSpeech)
var defaultVoice: String { get }   // e.g. "alba", "Samantha", or "af_heart"
var availableVoices: [String] { get } // sorted list of short names
```

`SpeechController` uses these for dynamic voice validation and WAV header sample rate.
`WyomingSession` uses them for the `describe` → `info` response and audio-start events.

### Wyoming protocol

The Wyoming server runs alongside the HTTP server on a single TCP port (default 10300). A single port serves both TTS and STT — the handler dispatches by incoming event type. Enabled by default; set `wyoming.port: 0` to disable.

**Testing note**: `configure.swift` skips Wyoming registration when `app.environment == .testing`. This mirrors how Vapor skips the HTTP bind in test mode — Vapor's `.testing` environment only suppresses the HTTP server, not lifecycle handlers. Without this guard, integration tests would attempt a real TCP `bind()` and fail with `EADDRINUSE` if a production server is running on the same port.

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

The `info` response advertises both `asr` and `tts` arrays so Home Assistant knows this single port handles both services. The TTS program includes `supports_synthesize_streaming: true` to advertise HA 2025.07+ streaming support. ASR model name and language list are driven by `STTInfo` (passed through `WyomingServer` → `WyomingSession`), with static presets `.parakeet` and `.qwen3`.

**Streaming TTS**: `handle(event:)` returns `AsyncStream<Data>` (non-async). For `synthesize`, the stream yields `audio-start` + each `audio-chunk` + `audio-stop` incrementally as TTS chunks arrive — `audio-start` is withheld until the first chunk so a completely failed synthesis sends nothing. State mutations (e.g. `state = .awaitingAudio`) happen synchronously before the stream is returned, so callers can immediately make the next `handle` call without draining the stream first. All other event types pre-fill the stream synchronously and finish immediately.

**Config** (nested under `servers` in `speech-server.yaml`):
```yaml
servers:
  http:
    host: 127.0.0.1   # default 127.0.0.1; override with HTTP_HOST env var or Vapor's --hostname flag
    port: 8080        # default 8080; override with HTTP_PORT env var or Vapor's --port flag
  wyoming:
    host: 127.0.0.1   # default 127.0.0.1; override with WYOMING_HOST env var (independent of http.host)
    port: 10300       # 0 = disabled; default 10300; override with WYOMING_PORT env var
```

Both `http.host` and `wyoming.host` are independently configurable — they do not need to match.

**Test files** (`Tests/speech-serverTests/`):

| File | What it tests | Models needed? |
|------|---------------|----------------|
| `WyomingConfigTests.swift` | YAML parsing, defaults, port 0 disable | No |
| `WyomingEventTests.swift` | serialize/deserialize, WyomingValue conversions, round-trip | No |
| `WyomingFrameDecoderTests.swift` | Header-only, with data, with payload, partial feeds, multi-event, reset | No |
| `WyomingWAVWriterTests.swift` | Valid WAV header bytes, multi-chunk, cleanup, custom sample rates | No |
| `WyomingSessionTests.swift` | describe→info, synthesize→audio sequence, STT flow, errors, streaming order, streaming synthesis (mock services) | No |
| `SentenceDetectionTests.swift` | `splitCompleteSentences` / `detectSentences` free functions | No |
| `AVSpeechConfigTests.swift` | YAML parsing for `avspeech` engine and `AVSpeechSettings` | No |
| `PCMConversionTests.swift` | `float32ToPCM16` and `makeWAV` utilities | No |
| `AVSpeechTTSServiceTests.swift` | Real `AVSpeechTTSService` (uses macOS system voices) | No |
| `KokoroConfigTests.swift` | YAML parsing for `kokoro` engine and `KokoroSettings` | No |
| `KokoroTTSServiceTests.swift` | Real `KokoroTTSService` (Kokoro CoreML models) | Yes |
| `Qwen3ConfigTests.swift` | YAML parsing for `qwen3` engine and `Qwen3STTSettings` | No |
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

**Important for agents**: after formatting, always run `swift test` to confirm all tests pass before considering a task complete. Unit tests are fast; integration tests require model downloads on first run but are cached after that.

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
| `Helpers/TestApp.swift` | Helper | `sharedTestApp()` singleton, multipart builder, word-overlap helper. Uses a temp `{}` YAML file to suppress local `speech-server.yaml`. Registers `AppShutdownObserver` (via `XCTestObservationCenter`) to call `app.asyncShutdown()` at bundle finish — required because `ServeCommand` has a `deinit` assertion that fires if its async shutdown was never called. |
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
| `AVSpeechConfigTests.swift` | Unit | YAML parsing for `avspeech` engine and `AVSpeechSettings` — no models needed |
| `PCMConversionTests.swift` | Unit | `float32ToPCM16` and `makeWAV` — no models needed |
| `AVSpeechTTSServiceTests.swift` | Unit | Real `AVSpeechTTSService` using macOS system voices — no models needed |
| `KokoroConfigTests.swift` | Unit | YAML parsing for `kokoro` engine and `KokoroSettings` — no models needed |
| `KokoroTTSServiceTests.swift` | Integration | Real `KokoroTTSService` with Kokoro CoreML models |
| `Qwen3ConfigTests.swift` | Unit | YAML parsing for `qwen3` engine and `Qwen3STTSettings` — no models needed |
| `Helpers/MockServices.swift` | Helper | MockTTSService + MockSTTService |

**First run**: integration tests load real FluidAudio models (STT + TTS). Model download takes several minutes; subsequent runs use the on-disk cache and start in seconds. The shared app singleton (`_appTask` in `TestApp.swift`) ensures models are initialized once per `swift test` invocation.

**Fixtures**: `Tests/speech-serverTests/Fixtures/test.wav` is a copy of the repo-root `test.wav`, accessed via `Bundle.module` in integration tests.

## CI

`.github/workflows/tests.yml` runs on every push and PR to `main`.

- **Runner**: `macos-15` with Swift 6.2 installed via `swift-actions/setup-swift@v2`.
- **Cache**: `.build`, `~/Library/Application Support/FluidAudio` (PocketTTS/ASR models), and `~/.cache/fluidaudio` (Kokoro models) are cached by `actions/cache@v4` keyed on `Package.resolved`. A `restore-keys` fallback allows partial hits (models survive SPM-only changes).
- **Steps**: checkout → setup Swift → restore cache → `swift build --build-tests` → `swift test` (30 min timeout).
- **Concurrency**: redundant runs on rapid pushes are cancelled via `concurrency.cancel-in-progress: true`.
- **Cold-cache run**: model download + SPM compilation takes ~10-20 min. Warm-cache run: ~1-2 min.

`.github/workflows/release.yml` runs on pushes of tags matching `v*`. It creates a GitHub
Release for the tag with generated release notes; it is idempotent (skips if a release for the
tag already exists) and ships no binaries -- bottles are built and published separately by the
Homebrew tap (see [Distribution (Homebrew)](#distribution-homebrew) and
[Release process](#release-process) below).

## Distribution (Homebrew)

Homebrew is the only supported installation method. The tap is
[`dokterbob/homebrew-macos-speech-server`](https://github.com/dokterbob/homebrew-macos-speech-server)
(GitHub repo `dokterbob/homebrew-macos-speech-server`), formula `macos-speech-server`. The
binary installed by the formula is still named `speech-server`. There is no `deploy/`
directory in this repo anymore — launchd plists and install/uninstall scripts were removed
in favor of the formula's `service do` block, which generates and manages the plist for you.

**File locations** (`$(brew --prefix)` is typically `/opt/homebrew` on Apple Silicon):

| | Per-user (`brew services start`) | System (`--sudo-service-user _speech-server`) |
|---|---|---|
| Binary | `$(brew --prefix)/bin/speech-server` | same |
| Config | `$(brew --prefix)/etc/speech-server/speech-server.yaml` | same |
| Logs | `$(brew --prefix)/var/speech-server/speech-server.log` | same path, owned by `_speech-server` |
| Working dir | `$(brew --prefix)/var/speech-server` | same, owned by `_speech-server` |
| Model caches | `~/Library/Application Support/FluidAudio`, `~/.cache/fluidaudio` (invoking user) | `$(brew --prefix)/var/speech-server/Library/Application Support/FluidAudio`, `$(brew --prefix)/var/speech-server/.cache/fluidaudio` |
| launchd plist | `~/Library/LaunchAgents/sh.brew.macos-speech-server.plist` | `/Library/LaunchDaemons/sh.brew.macos-speech-server.plist` |
| Runs as | invoking user | `_speech-server` role account |

**Service block semantics**: the formula's `service do` block runs `speech-server serve` with
`SPEECH_SERVER_CONFIG` set to the config path above, and sets `working_dir`/`log_path` to the
locations in the table. The log deliberately lives *inside* `working_dir` rather than under
`var/log` — see the launchd gotcha below. `brew services start|stop|restart macos-speech-server` manages the
per-user LaunchAgent; adding `sudo` plus `--sudo-service-user _speech-server` switches Homebrew
to installing a system LaunchDaemon that runs as that role account instead of root. Don't run
both modes at once — they bind the same ports. The README's system-startup sequence therefore
stops the per-user service (`brew services stop macos-speech-server`) before
`sudo brew services start … --sudo-service-user`. `brew upgrade macos-speech-server` is always run
as the normal user; only the post-upgrade restart differs by mode —
`brew services restart macos-speech-server` for per-user, or
`sudo brew services restart macos-speech-server --sudo-service-user _speech-server` for system.

**Role-account creation gotchas**: `sysadminctl -addUser … -roleAccount` requires an explicit
`-UID` in the 450–499 range — it errors without one. It also silently ignores `-home` and
`-shell` for role accounts (home is forced to `/var/empty`, shell to `/usr/bin/false`); since
launchd derives `HOME` from the account record, the home must be repointed after creation with
`sudo dscl . -create /Users/_speech-server NFSHomeDirectory "$(brew --prefix)/var/speech-server"`,
or model downloads go to `/var/empty` and fail. The formula itself does not create
`$(brew --prefix)/var/speech-server` at install time — it has no `post_install` (removed per
Homebrew's style rules); the directory is created by `brew services start` the first time the
per-user LaunchAgent starts. In system mode nothing starts the per-user LaunchAgent first, so the
directory must be created manually (`sudo mkdir -p`) before `chown`. See `docs/install.md` →
Run at system startup (optional) for the full three-step sequence.

**launchd `EX_CONFIG` (exit 78) gotcha / why the log lives in `working_dir`**: with
`--sudo-service-user`, launchd opens `StandardOutPath`/`StandardErrorPath` *as the service user*,
after dropping privileges. `brew services start` creates the parent directories of `working_dir`
and `log_path` (`service.path_dirs.each(&:mkpath)` in Homebrew's `services/cli.rb`) but never
chowns them to the `--sudo-service-user` account. A log under `var/log` therefore cannot be
created by `_speech-server` (the directory is owned by the Homebrew user, and the role account is
not in `admin`), launchd fails before spawning the binary, and `launchctl print` shows
`state = spawn scheduled`, `last exit code = 78: EX_CONFIG` with an empty/absent log. The formula
avoids this by putting the log at `var/speech-server/speech-server.log`, inside the directory the
role account already owns after the documented `chown -R`. Don't move it back to `var/log`
without also adding a `sudo touch` + `sudo chown` step to the README and formula caveats.

**Migration from `deploy/`**: pre-Homebrew versions installed a launchd job labelled
`com.local.speech-server` via `deploy/install-agent.sh` / `deploy/install-daemon.sh`, at
`~/Library/LaunchAgents/com.local.speech-server.plist` (or the daemon equivalent under
`/Library/LaunchDaemons`) with binary/config paths like `~/bin/speech-server` /
`~/.config/speech-server/speech-server.yaml` (or `/usr/local/bin/speech-server` /
`/etc/speech-server/speech-server.yaml`). It must be `launchctl bootout`'d and its binary removed
**before `brew install`**, not just before the service starts -- on Intel Macs Homebrew's prefix
is `/usr/local`, so the stale `/usr/local/bin/speech-server` collides with the formula's own
symlink and `brew install` fails to link. Old config can be copied over the freshly installed
example afterward. The user-facing steps live in `docs/upgrading-pre-0_1.md` (linked from
`docs/install.md` → Migrating from the old deploy/ scripts); keep migration detail there, not in
the README.

**Why no `depends_on xcode:`**: the formula does not declare an Xcode dependency. Building with
Swift 6.2 only requires the Command Line Tools (`swift build` works without a full Xcode
install); declaring `depends_on xcode:` would incorrectly reject CLT-only machines that can
build the formula fine.

**Why the config lives in Homebrew `etc`**: Homebrew's `etc` directory is the conventional
location for installed config, and its `InstallRenamed` resource behavior means an existing,
user-edited `speech-server.yaml` is preserved across upgrades — the new version's example is
written alongside it as `speech-server.yaml.default` instead of overwriting the live config.

**Ownership when switching modes**: in system mode `$(brew --prefix)/var/speech-server` (working
dir, log, and the role account's model caches) is owned by `_speech-server`, so the per-user
service cannot write there afterwards. Switching back requires
`sudo chown -R "$(id -un)" "$(brew --prefix)/var/speech-server"` (see `docs/install.md` →
Switching between the per-user and the system service). Note: the log is *not* root-owned under
`--sudo-service-user` — launchd opens it as the service user. A root-owned log only happens if `sudo brew services start` was run
*without* `--sudo-service-user`, which runs the daemon as root and makes Homebrew take
`root:admin` ownership of the formula paths; avoid that mode.

**System mode only sees the built-in compact voices**: running the server as the system
LaunchDaemon (`sudo brew services start … --sudo-service-user _speech-server`) makes
`AVSpeechSynthesisVoice.speechVoices()` return only the ~74 legacy built-in compact voices under
`/System/Library/Speech/Voices`. Every downloaded Enhanced/Premium voice (`Zoe (Premium)`,
`Daniel (Enhanced)`) and every MobileAsset voice (multi-locale Eddy/Flo/Grandma/Grandpa/Reed/
Rocko/Sandy/Shelley, Aman, Aru, Susan, Tara) is missing -- a logged-in GUI user sees 180+ instead.
Mechanism: the voice files themselves are world-readable under
`/System/Library/AssetsV2/com_apple_MobileAsset_TTSAXResourceModelAssets`, but enumeration goes
through per-user agents (`com.apple.accessibility.axassetsd`, audio-unit speech providers) that
only exist in a logged-in user's launchd domain; a LaunchDaemon lives in the system domain (a
`--sudo-service-user` daemon too) and has no such session. Verified: voices downloaded by one user
are visible to a *different* logged-in user, even over SSH, so the limiting factor is the GUI
login session, not who downloaded the voice. Web research turned up no workaround -- not
`launchctl asuser`, `user/<uid>` launchd domains, copying prefs/assets across users, or running a
private per-user helper daemon. The per-user service (`brew services start macos-speech-server`,
with automatic login configured for boot-time start) is the fix, not a workaround for the system
service. This was mistaken for a regression from PR #23 during investigation -- that PR only
changed the per-voice `languages` field in the Wyoming `describe`/`info` event, not voice
enumeration. Don't re-diagnose this as a `describe`/Wyoming bug: compare `say -v '?'` run as the
logged-in GUI user against the server's `describe` (Wyoming) or voices output while running under
each mode. The warning lives in the README's Installation → Advanced installation subsection and
at the top of `docs/install.md` → Run at system startup (optional); the tap formula's caveats
carry the same warning for `brew info` / `brew services` output.

## Release process

1. A maintainer tags `vX.Y.Z` on merged `main`.
2. `.github/workflows/release.yml` creates a GitHub Release with generated release notes.
3. The tap's autobump workflow (runs daily) opens a formula-bump PR in
   `dokterbob/homebrew-macos-speech-server`, or a maintainer triggers one manually:
   ```bash
   brew bump-formula-pr --version=X.Y.Z dokterbob/macos-speech-server/macos-speech-server
   ```
4. The tap's `brew test-bot` CI builds bottles for that PR.
5. A maintainer publishes the bottles by running the tap's `publish.yml` workflow:
   ```bash
   gh workflow run publish.yml -R dokterbob/homebrew-macos-speech-server -f pull_request=<N>
   ```
   which uploads bottles to the tap's GitHub Releases and commits the bottle block.

**GITHUB_TOKEN caveat**: PRs opened by the autobump workflow using the default `GITHUB_TOKEN` do
not trigger tap CI (GitHub's cross-workflow-trigger restriction). Either configure a PAT secret
`HOMEBREW_BUMP_TOKEN` in the tap, or close and reopen the autobump PR to trigger CI manually.

**Workflow-push limitation**: this bot/agent's GitHub token cannot push `.github/workflows/*`
files — a human maintainer must commit and push any new or changed workflow file (including
`release.yml` itself, the first time).

**Formula/test coupling**: the formula's `test do` block relies on `ServerConfig.load()` failing
fast on an unknown engine *before* any model loading happens in `configure()`. Changing that
ordering, or changing the decoding error text the test matches against, requires a matching
update to the formula in the tap.

**Follow-ups** (out of scope for this change, tracked for later):
- Replace the top-level rethrow in `Entrypoint.swift` with a clean `exit(1)` on startup failure.
- Add a `--version` flag — it must be intercepted before `configure(app)` runs, since Vapor only
  parses commands inside `app.execute()`.
- Wyoming's hardcoded `"1.0.0"` version strings in
  `Sources/speech-server/Wyoming/WyomingSession.swift` should track the package version instead.

## Pull request workflow

All changes must go through a pull request. Never push directly to `main`.

1. Create a feature branch: `git checkout -b feature/short-description` or `fix/issue-description`.
2. Make changes (write tests first — see TDD convention below).
3. Format Swift files: `swift format --in-place --recursive Sources/ Tests/`
4. Verify tests pass: `swift test`
5. Open a PR targeting `main`. The PR description should explain *why* the change is needed, not just what changed.
6. CI must be green (formatting lint + tests) before merging.

## Conventions

- **Async middleware**: use `AsyncMiddleware` protocol (not the `EventLoopFuture`-based `Middleware`).
- **Request body decoding**: The transcription endpoint uses `body: .stream` and manually streams to disk, then decodes with `FormDataDecoder` from MultipartKit. Other controllers use `req.content.decode()` for JSON.
- **Upload limit**: enforced mid-stream in `TranscriptionController` using `req.application.serverConfig.servers.http.uploadLimitMB` (default 500 MB); throws `413 Payload Too Large` before the full body is buffered. Not set via `app.routes.defaultMaxBodySize`.
- **Config**: `ServerConfig` is loaded in `configure()` from `SPEECH_SERVER_CONFIG` env var → `./speech-server.yaml` → built-in defaults. All engine-selection switches live in `configure.swift`; adding a new engine means adding a `case` there. Engine enum raw values match YAML keys (e.g. `parakeet`, `pocket_tts`).
- **Logging**: use `request.logger` in request context, `app.logger` during setup. Log level is set to `.notice` in `configure.swift` to suppress Vapor's internal debug noise. All operational log calls (request details, transcription progress) use `.notice`; use `.warning` or above for anomalies. Services that need their own logger (e.g. `FluidSTTService`) create a `Logger(label:)` instance with `logLevel` set explicitly.
- **STTService protocol**: `transcribe(audioURL: URL)` returns `TranscriptionResult` (with `text` and `duration`), not a plain `String`. The URL points to a temp file with the correct audio extension, created and cleaned up by the controller. The `verbose_json` response includes a `segments` array matching the OpenAI API shape.
- **Audio format detection**: lives in `AudioFormatDetection.swift` as a package-internal free function `audioFileExtension(filename:header:)`. `header` is the first 12 bytes of the audio data (`Data`). Called from `TranscriptionController`, not from `FluidSTTService`. `File.contentType` in Vapor is derived from the filename extension and may be `nil` -- always use `audioFileExtension` instead.
- **TTS voice validation**: `SpeechController` validates the voice with `ttsService.availableVoices.contains(voice)` before starting the stream (response headers already sent → can't return 4xx after). The unrecognised-voice error lists up to 5 available voices in its message. `FluidTTSService` still catches `PocketTtsConstantsLoader.LoadError.fileNotFound` and re-throws as `FluidTTSError.voiceNotFound` as a safety net, but this should only be reached if the guard is missing.
- **Keeping docs in sync**: When making any user-visible change (new endpoint, changed behaviour, new field, new error), update `README.md`. When making any architectural change (new service, new constraint, new convention, new gotcha), update `AGENTS.md`. Both files should be updated in the same commit as the code change. Advanced installation instructions (system-service setup, switching between per-user and system modes, upgrading the system service, migrating from the old `deploy/` scripts) live in `docs/install.md`, not the README. The README's Installation section must stay short (2-3 lines of CLI, per-user `brew services start`) and link to `docs/install.md` via its "Advanced installation" subsection for anything beyond that.
- **TDD convention**: Unit tests are written BEFORE the implementation they cover. When implementing a feature, write the test file first (it will fail to compile until the implementation is added), then write the implementation. This ensures tests actually define the contract, not just document it.
