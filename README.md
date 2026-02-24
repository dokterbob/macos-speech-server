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

On first launch, ASR models (~v3) are downloaded automatically. This takes several minutes but only happens once; subsequent starts are fast.

The server listens on `http://localhost:8080` by default.

## API

All endpoints are available at both `/audio/*` and `/v1/audio/*` (OpenAI compatibility).

### Speech-to-Text

```
POST /v1/audio/transcriptions
Content-Type: multipart/form-data
```

| Field             | Type   | Required | Description                                       |
|-------------------|--------|----------|---------------------------------------------------|
| `file`            | File   | Yes      | Audio file (max 25MB)                              |
| `model`           | String | No       | Model name (e.g. `whisper-1`)                      |
| `language`        | String | No       | ISO-639-1 language code                            |
| `prompt`          | String | No       | Context hint for transcription                     |
| `response_format` | String | No       | `json` (default), `text`, or `verbose_json`        |
| `temperature`     | Double | No       | Sampling temperature, 0.0-1.0                      |

Example:

```bash
curl -X POST http://localhost:8080/v1/audio/transcriptions \
  -F file=@recording.wav -F model=whisper-1
```

### Text-to-Speech (stub)

```
POST /v1/audio/speech
Content-Type: application/json
```

| Field             | Type   | Required | Description                                       |
|-------------------|--------|----------|---------------------------------------------------|
| `model`           | String | Yes      | Model name (e.g. `tts-1`)                          |
| `input`           | String | Yes      | Text to synthesize (max 4096 chars)                |
| `voice`           | String | No       | Voice name (default: `alloy`)                      |
| `response_format` | String | No       | `wav` (default) or `pcm`                           |
| `speed`           | Double | No       | Playback speed, 0.25-4.0 (default: 1.0)           |

> TTS currently returns silent audio. Real implementation is planned.

## Project structure

```
Sources/speech-server/
  Entrypoint.swift              # Application entry point
  configure.swift               # Middleware and service setup
  routes.swift                  # Route registration
  Controllers/
    TranscriptionController.swift  # STT endpoint
    SpeechController.swift         # TTS endpoint
  Services/
    STTService.swift            # STT protocol + DI
    FluidSTTService.swift       # FluidAudio ASR implementation
    TTSService.swift            # TTS protocol + DI (stub)
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
