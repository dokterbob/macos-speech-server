# macos-speech-server

Local, private speech-to-text (STT) and text-to-speech (TTS) server for macOS with OpenAI-compatible and Home Assistant (Wyoming) support.

Runs entirely on-device using Apple's Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio) -- no cloud services, no API keys, no data leaves your machine. Models are loaded once at startup and served to any device on your network, so a single Mac with Apple Silicon can handle transcription and speech for your entire household.

Two interfaces, one server:

- **OpenAI-compatible HTTP API** -- drop-in replacement for OpenAI audio endpoints (`/v1/audio/transcriptions`, `/v1/audio/speech`)
- **[Wyoming protocol](https://github.com/rhasspy/wyoming)** (TCP, default port 10300) -- native [Home Assistant](https://www.home-assistant.io/) voice pipeline integration

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

The server listens on `http://localhost:8080` by default. The Wyoming protocol server listens on TCP port `10300` by default.

## Configuration

All server settings can be customised via a YAML config file. Create `speech-server.yaml` in the working directory (a fully-commented example is included in the repo):

```yaml
log_level: notice     # trace | debug | info | notice | warning | error | critical

servers:
  http:
    host: 127.0.0.1       # use your LAN or Tailscale IP to accept connections from other devices
    port: 8080
    upload_limit_mb: 500
  wyoming:
    host: 127.0.0.1       # can differ from http.host; set independently
    port: 10300           # TCP port for Wyoming protocol (Home Assistant). 0 = disabled.

stt:
  engine: parakeet      # Currently only: parakeet (NVIDIA Parakeet TDT via FluidAudio)
  parakeet:
    model_version: v3   # v3 = multilingual (25 langs, default), v2 = English-only

tts:
  engine: pocket_tts    # pocket_tts (default) | avspeech

  # AVSpeech settings (only used when engine: avspeech)
  # avspeech:
  #   default_voice: Samantha   # Short name or full identifier; nil = system locale default
  #   sample_rate: 22050        # Native AVSpeech output rate (Hz)
```

All fields are optional — omitted fields use the defaults shown above.

### TTS engines

Two TTS engines are available:

| Engine | `engine:` value | Voices | Downloads | Notes |
|--------|----------------|--------|-----------|-------|
| FluidAudio PocketTTS | `pocket_tts` | `alba` only | ~200 MB on first start | Default |
| macOS AVSpeech | `avspeech` | 150+ system voices | None (ships with macOS) | Instant startup |

#### `pocket_tts` (default)

Uses [FluidAudio](https://github.com/FluidInference/FluidAudio)'s PocketTTS model. Only the `alba` voice is available. Models are downloaded on first start and cached at `~/Library/Application Support/FluidAudio`.

#### `avspeech` — macOS built-in voices

Uses macOS's `AVSpeechSynthesizer` — no model downloads, instant startup, 150+ voices across dozens of languages. Audio is synthesised at 22050 Hz mono (16-bit PCM).

```yaml
tts:
  engine: avspeech
  avspeech:
    default_voice: Samantha   # Optional — nil uses the system locale default
```

List all available voices with:

```bash
say --voice '?'
```

The short name (e.g. `Samantha`, `Daniel`, `Karen`) is used in API requests. Voice names are case-insensitive; full identifiers (e.g. `com.apple.voice.enhanced.en-US.Samantha`) also work.

> **Note:** Siri voices are not accessible via public AVFoundation APIs and will not appear in the voice list.
> Personal Voice support (macOS 14+) is planned — see issue #13.

### Config discovery order

1. `SPEECH_SERVER_CONFIG` environment variable (path to a YAML file)
2. `./speech-server.yaml` in the current working directory
3. Built-in defaults (no file needed)

```bash
# Use an explicit config file via env var
SPEECH_SERVER_CONFIG=/etc/speech-server.yaml swift run speech-server
```

### Environment variable overrides

Individual settings can also be overridden with environment variables:

| Variable | Overrides | Example |
|----------|-----------|---------|
| `HTTP_HOST` | `servers.http.host` | `HTTP_HOST=192.168.1.50` |
| `HTTP_PORT` | `servers.http.port` | `HTTP_PORT=9090` |
| `WYOMING_HOST` | `servers.wyoming.host` | `WYOMING_HOST=192.168.1.50` |
| `WYOMING_PORT` | `servers.wyoming.port` | `WYOMING_PORT=0` (disables Wyoming) |

Vapor's `--hostname` and `--port` CLI flags also work and take highest priority for the HTTP server.

## Deployment

This project supports two launchd deployment models:

| Model | Scope | Privileges | Persistence | Install script |
|---|---|---|---|---|
| LaunchDaemon | System-wide | `sudo` required | Starts at boot, survives logout | `deploy/install-daemon.sh` |
| LaunchAgent | Per-user | No `sudo` | Starts at user login | `deploy/install-agent.sh` |

### Option A: LaunchDaemon (persistent system service)

Recommended when you want the server always available on the machine.

1. Build and install:

```bash
sudo deploy/install-daemon.sh
```

2. Verify status:

```bash
sudo launchctl print system/com.local.speech-server
```

3. Watch logs:

```bash
sudo tail -f /var/log/speech-server/output.log /var/log/speech-server/error.log
```

What the installer does:
- Creates dedicated service account `_speech-server`.
- Installs binary to `/usr/local/bin/speech-server`.
- Installs config to `/etc/speech-server/speech-server.yaml` (without overwriting existing config).
- Installs LaunchDaemon plist to `/Library/LaunchDaemons/com.local.speech-server.plist`.
- Optionally pre-populates FluidAudio cache from invoking user into the service account home.

Useful daemon commands:

```bash
# Restart daemon after config changes
sudo launchctl kickstart -k system/com.local.speech-server

# Stop daemon
sudo launchctl bootout system/com.local.speech-server

# Start daemon again
sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.speech-server.plist
sudo launchctl enable system/com.local.speech-server
sudo launchctl kickstart -k system/com.local.speech-server
```

Uninstall daemon:

```bash
# Keep config/logs/service user
sudo deploy/uninstall-daemon.sh

# Remove everything including config/logs/model cache/service user
sudo deploy/uninstall-daemon.sh --purge
```

### Option B: LaunchAgent (per-user service)

Recommended when you want user-session startup with no system-wide changes.

1. Build and install:

```bash
deploy/install-agent.sh
```

2. Verify status:

```bash
launchctl print gui/$(id -u)/com.local.speech-server
```

3. Watch logs:

```bash
tail -f "$HOME/Library/Logs/speech-server/output.log" "$HOME/Library/Logs/speech-server/error.log"
```

Useful agent commands:

```bash
# Restart agent after config changes
launchctl kickstart -k gui/$(id -u)/com.local.speech-server

# Stop agent
launchctl bootout gui/$(id -u)/com.local.speech-server

# Start agent again
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.local.speech-server.plist"
launchctl enable gui/$(id -u)/com.local.speech-server
launchctl kickstart -k gui/$(id -u)/com.local.speech-server
```

Uninstall agent:

```bash
# Keep config/logs
deploy/uninstall-agent.sh

# Remove user config/logs too
deploy/uninstall-agent.sh --purge
```

### Deployment files

The `deploy/` directory contains ready-to-use templates and scripts:

- `deploy/com.local.speech-server.plist` -- LaunchDaemon template
- `deploy/com.local.speech-server.agent.plist` -- LaunchAgent template (`__HOME__` placeholders are replaced by installer)
- `deploy/install-daemon.sh` and `deploy/uninstall-daemon.sh`
- `deploy/install-agent.sh` and `deploy/uninstall-agent.sh`

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
| `voice`           | String | No       | Voice name (default: engine default). See [TTS engines](#tts-engines). |
| `response_format` | String | No       | `wav` (default) or `pcm`                           |
| `speed`           | Double | No       | Playback speed, 0.25-4.0 (default: 1.0)           |

The response is **streamed**: audio begins arriving before synthesis is complete, sentence by sentence. WAV responses include a standard 44-byte header (with unknown-size placeholders) followed by 16-bit PCM; PCM responses are raw 16-bit bytes. The sample rate depends on the active TTS engine (24 kHz for `pocket_tts`, 22050 Hz for `avspeech`).

Example:

```bash
curl -X POST http://localhost:8080/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"tts-1","input":"Hello, world!"}' \
  --output speech.wav

# AVSpeech engine with a specific voice
curl -X POST http://localhost:8080/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"tts-1","input":"Hello, world!","voice":"Samantha"}' \
  --output speech.wav
```

## Compatible apps

The HTTP API is compatible with any app or library that supports a configurable OpenAI base URL. No real API key is needed -- the server ignores `Authorization` headers, so enter any non-empty string.

### MacWhisper

[MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper) has built-in support for custom transcription providers:

1. Open MacWhisper **Preferences**
2. Go to the **Provider** tab and choose **Custom**
3. Set the **API URL** to `http://<host>:<port>/v1/audio/transcriptions` (default `localhost:8080`)
4. Enter any string as the **API Key** (e.g. `local`)

Audio is sent directly to the endpoint; transcription happens entirely on-device with no round-trip to the cloud.

### Other apps

Any tool that supports a configurable OpenAI base URL should work out of the box: set the base URL to `http://<host>:<port>` (default `localhost:8080`) and use any string as the API key. This includes the official OpenAI Python and JavaScript SDKs, and similar tools.

## Accessing from other machines

By default the server binds to `127.0.0.1` and is only reachable locally. To serve requests from other devices -- another Mac, a phone, a Home Assistant instance -- bind to a reachable address and make sure the ports are accessible.

### Tailscale (recommended)

[Tailscale](https://tailscale.com/) gives every device a stable private IP with no port-forwarding or firewall rules, and works across different networks (home, office, mobile). Both the HTTP API port and the Wyoming port are plain TCP; Tailscale handles encryption transparently.

**Recipe:**

1. Install Tailscale on the Mac running the server and on any device that needs access.
2. Note the Mac's Tailscale IP (e.g. `100.x.y.z`) from the menu-bar icon.
3. Bind the server to that IP in `speech-server.yaml`:

```yaml
servers:
  http:
    host: 100.x.y.z   # your Mac's Tailscale IP
  wyoming:
    host: 100.x.y.z   # your Mac's Tailscale IP
    port: 10300
```

4. Point your client at `http://100.x.y.z:8080` (HTTP API) or `100.x.y.z:10300` (Wyoming).

### Local network

Find your Mac's LAN IP in **System Settings > Network**, select your active connection (Wi-Fi or Ethernet), and note the IP address (e.g. `192.168.1.50`). Bind the server to that address:

```yaml
servers:
  http:
    host: 192.168.1.50   # your Mac's LAN IP
  wyoming:
    host: 192.168.1.50   # your Mac's LAN IP
    port: 10300
```

Use that same IP in your client configuration. Note that LAN IPs can change when devices reconnect; consider assigning a DHCP reservation in your router, or use Tailscale for a stable address.

## Home Assistant

macos-speech-server speaks the [Wyoming protocol](https://github.com/rhasspy/wyoming), enabling fully on-device STT and TTS for [Home Assistant](https://www.home-assistant.io/) voice pipelines via the [Wyoming integration](https://www.home-assistant.io/integrations/wyoming/).

A single TCP port (default `10300`) handles both STT and TTS -- Home Assistant discovers both capabilities automatically.

### Network setup

Home Assistant typically runs on a separate machine, so the Wyoming port must be reachable from it. See [Accessing from other machines](#accessing-from-other-machines) above for Tailscale and LAN options -- in either case, set `servers.http.host` and `servers.wyoming.host` to your Mac's IP (or use the `HTTP_HOST` and `WYOMING_HOST` environment variables) so both ports are reachable from HA.

### Adding the Wyoming integration in Home Assistant

The integration must be added manually (zeroconf/auto-discovery is not supported):

1. Go to **Settings > Devices & Services**
2. Click **Add Integration**
3. Search for **Wyoming Protocol**
4. Enter the host (IP address of the Mac running macos-speech-server) and port (default `10300`)
5. Home Assistant discovers both STT and TTS capabilities on that single port

### Using in a voice pipeline

1. Go to **Settings > Voice Assistants**
2. Create a new pipeline or edit an existing one
3. Select **macos-speech-server** for the Speech-to-text and/or Text-to-speech step

Streaming TTS (lower latency, audio starts playing before synthesis is complete) is supported in Home Assistant 2025.07 and later.

## Project structure

```
speech-server.yaml.example         # Example config (all defaults); copy to speech-server.yaml to customise
                                   # speech-server.yaml is gitignored (may contain private IPs)
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
    AVSpeechTTSService.swift       # macOS AVSpeechSynthesizer implementation (avspeech engine)
    PCMConversion.swift            # Shared Float32→Int16 PCM conversion and WAV builder
    SentenceDetection.swift        # Shared sentence splitting for TTS
  Middleware/
    RequestLoggingMiddleware.swift  # Logs method, path, status code
    OpenAIErrorMiddleware.swift    # OpenAI-format error responses
  Models/
    TranscriptionResponse.swift
    SpeechRequest.swift
    OpenAIError.swift
  Wyoming/
    WyomingEvent.swift             # Protocol event model
    WyomingFrameDecoder.swift      # Wire format parser
    WyomingNIOHandler.swift        # NIO channel handler
    WyomingServer.swift            # TCP server bootstrap
    WyomingSession.swift           # Session state machine (STT + TTS)
    WyomingWAVWriter.swift         # PCM-to-WAV for STT handoff
```

## Contributing

Contributions are welcome. All changes go through a pull request — see [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow, code style, and PR guidelines.

Swift code is formatted with `swift format` (ships with Swift 6.2). A pre-commit hook is provided; install it with `scripts/install-hooks.sh`.

## License

AGPL-3.0 -- see [LICENSE](LICENSE).
