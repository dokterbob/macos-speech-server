# macos-speech-server

Local, private speech-to-text (STT) and text-to-speech (TTS) server for macOS with an OpenAI-compatible API.

Runs entirely on-device using Apple's Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio) -- no cloud services, no API keys, no data leaves your machine.

## Requirements

- macOS 14+
- Swift 6.2+
- Apple Silicon recommended (Neural Engine acceleration)

## Quick start

```bash
swift build
swift run speech-server
```

On first launch, ASR and TTS models are downloaded automatically. This takes several minutes but only happens once; subsequent starts are fast.

The server listens on `http://localhost:8080` by default.

## Configuration

All server settings can be customised via a YAML config file. Create `speech-server.yaml` in the working directory (a fully-commented example is included in the repo):

```yaml
server:
  host: 127.0.0.1       # use 0.0.0.0 to listen on all interfaces
  port: 8080
  log_level: notice     # trace | debug | info | notice | warning | error | critical
  upload_limit_mb: 500

stt:
  engine: parakeet      # Currently only: parakeet (NVIDIA Parakeet TDT via FluidAudio)
  parakeet:
    model_version: v3   # v3 = multilingual (25 langs, default), v2 = English-only

tts:
  engine: pocket_tts
```

All fields are optional — omitted fields use the defaults shown above.

### Config discovery order

1. `SPEECH_SERVER_CONFIG` environment variable (path to a YAML file)
2. `./speech-server.yaml` in the current working directory
3. Built-in defaults (no file needed)

```bash
# Use an explicit config file via env var
SPEECH_SERVER_CONFIG=/etc/speech-server.yaml swift run speech-server

# Vapor's built-in --hostname and --port still override config-file values
swift run speech-server serve --hostname 0.0.0.0 --port 9090
```

## API

All endpoints are available at both `/audio/*` and `/v1/audio/*` (OpenAI compatibility).

### Speech-to-Text

```
POST /v1/audio/transcriptions
Content-Type: multipart/form-data
```

| Field             | Type   | Required | Description                                       |
|-------------------|--------|----------|---------------------------------------------------|
| `file`            | File   | Yes      | Audio file (max 500 MB)                            |
| `model`           | String | No       | Model name (e.g. `whisper-1`)                      |
| `language`        | String | No       | ISO-639-1 language code                            |
| `prompt`          | String | No       | Context hint for transcription                     |
| `response_format` | String | No       | `json` (default), `text`, or `verbose_json`; `srt`/`vtt` return 400 |
| `temperature`     | Double | No       | Sampling temperature, 0.0-1.0                      |

Supported audio formats: WAV, MP3, M4A, FLAC, AIFF, OGG. Files without a recognised extension are identified automatically via magic bytes.

No API key is required. If your client sends an `Authorization` header it is silently ignored.

The `verbose_json` response includes a `segments` array and real `duration` from the ASR engine, matching the OpenAI API shape:

```json
{
  "task": "transcribe",
  "language": "en",
  "duration": 1.54,
  "text": "Hello world.",
  "segments": [{ "id": 0, "seek": 0, "start": 0.0, "end": 1.54, "text": "Hello world.", ... }]
}
```

Example:

```bash
curl -X POST http://localhost:8080/v1/audio/transcriptions \
  -F file=@recording.wav -F model=whisper-1

curl -X POST http://localhost:8080/v1/audio/transcriptions \
  -F file=@recording.wav -F model=whisper-1 -F response_format=verbose_json
```

### Text-to-Speech

```
POST /v1/audio/speech
Content-Type: application/json
```

| Field             | Type   | Required | Description                                       |
|-------------------|--------|----------|---------------------------------------------------|
| `model`           | String | Yes      | Model name (e.g. `tts-1`)                          |
| `input`           | String | Yes      | Text to synthesize (max 4096 chars)                |
| `voice`           | String | No       | Voice name (default: `alba`). Only `alba` is currently supported. |
| `response_format` | String | No       | `wav` (default) or `pcm`                           |
| `speed`           | Double | No       | Playback speed, 0.25-4.0 (default: 1.0)           |

The response is **streamed**: audio begins arriving before synthesis is complete, sentence by sentence. WAV responses include a standard 44-byte header (with unknown-size placeholders) followed by 16-bit PCM at 24 kHz mono; PCM responses are raw 16-bit bytes.

Example:

```bash
curl -X POST http://localhost:8080/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"tts-1","input":"Hello, world!"}' \
  --output speech.wav

# Explicit voice and PCM output
curl -X POST http://localhost:8080/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"tts-1","input":"Hello, world!","voice":"alba","response_format":"pcm"}' \
  --output speech.pcm
```

## Project structure

```
speech-server.yaml                 # Example config (all defaults)
Sources/speech-server/
  Entrypoint.swift                 # Application entry point
  configure.swift                  # Middleware and service setup
  routes.swift                     # Route registration
  ServerConfig.swift               # YAML config loading + Vapor DI
  Controllers/
    TranscriptionController.swift  # STT endpoint
    SpeechController.swift         # TTS endpoint
  Services/
    STTService.swift               # STT protocol + DI
    FluidSTTService.swift          # FluidAudio ASR implementation (parakeet engine)
    AudioFormatDetection.swift     # Magic-byte audio format detection
    TTSService.swift               # TTS protocol + DI
    FluidTTSService.swift          # FluidAudio PocketTTS implementation (pocket_tts engine)
  Middleware/
    RequestLoggingMiddleware.swift  # Logs method, path, status code
    OpenAIErrorMiddleware.swift    # OpenAI-format error responses
  Models/
    TranscriptionResponse.swift
    SpeechRequest.swift
    OpenAIError.swift
```

## License

AGPL-3.0 -- see [LICENSE](LICENSE).
