# macos-speech-server

Local, private speech-to-text (STT) and text-to-speech (TTS) server for macOS with OpenAI-compatible and Home Assistant (Wyoming) support.

Runs entirely on-device using Apple's Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio) -- no cloud services, no API keys, no data leaves your machine. Models are loaded once at startup and served to any device on your network, so a single Mac with Apple Silicon can handle transcription and speech for your entire household.

Two interfaces, one server:

- **OpenAI-compatible HTTP API** -- drop-in replacement for OpenAI audio endpoints (`/v1/audio/transcriptions`, `/v1/audio/speech`)
- **[Wyoming protocol](https://github.com/rhasspy/wyoming)** (TCP, default port 10300) -- native [Home Assistant](https://www.home-assistant.io/) voice pipeline integration

## Requirements

- macOS 14+ (Homebrew bottles need macOS 15+ on Apple Silicon; see [Installation](#installation))
- Apple Silicon recommended (Neural Engine acceleration)
- Swift 6.2+ only when building from source (requires macOS 15+)

## Installation

Install via [Homebrew](https://brew.sh):

```bash
brew install dokterbob/macos-speech-server/macos-speech-server
brew services start macos-speech-server
```

This installs a per-user [LaunchAgent](https://www.launchd.info) that starts the server at login and runs it as your user -- no `sudo` needed.

The example config is installed at `$(brew --prefix)/etc/speech-server/speech-server.yaml`. Edit it, then restart:

```bash
brew services restart macos-speech-server
```

Logs are written to `$(brew --prefix)/var/log/speech-server.log`; the working directory is `$(brew --prefix)/var/speech-server`.

On first start the server downloads ASR/TTS models -- roughly 700 MB with the default engines, up to ~1.75 GB if you switch to the `qwen3` `f32` variant -- into `~/Library/Application Support/FluidAudio` and `~/.cache/fluidaudio`. This takes several minutes and prints nothing at the default `log_level: notice`; set `log_level: info` in the config to watch progress.

Check readiness once the download completes:

```bash
curl -sf -X POST http://127.0.0.1:8080/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"tts-1","input":"Hello"}' -o /tmp/hello.wav
```

By default the server only listens on `127.0.0.1` (HTTP port 8080, Wyoming port 10300; set `wyoming.port: 0` to disable Wyoming). To reach it from other machines, change `servers.http.host` / `servers.wyoming.host` -- see [Accessing from other machines](#accessing-from-other-machines).

### Run at system startup (optional)

The per-user LaunchAgent above only runs while you're logged in. For a server that starts at boot without a login session, running under a dedicated least-privilege account, use Homebrew's built-in system-service support (Apple's role-account pattern -- no custom scripts):

```bash
# 1. Create the role account. Pick an unused UID in 450-499; this lists the ones already taken:
#    dscl . -list /Users UniqueID | awk '$2 >= 450 && $2 <= 499'
sudo sysadminctl -addUser _speech-server -fullName "Speech Server" -UID 450 -roleAccount

# 2. Point its home at the data directory (sysadminctl ignores -home for role accounts)
sudo dscl . -create /Users/_speech-server NFSHomeDirectory "$(brew --prefix)/var/speech-server"
sudo mkdir -p "$(brew --prefix)/var/speech-server"
sudo chown -R _speech-server "$(brew --prefix)/var/speech-server"

# 3. Stop the per-user service if it is running, then start the system service at boot
brew services stop macos-speech-server 2>/dev/null || true
sudo brew services start macos-speech-server --sudo-service-user _speech-server
```

Verify it's running:

```bash
sudo launchctl print system/sh.brew.macos-speech-server
dscl . -read /Users/_speech-server NFSHomeDirectory UniqueID
```

Models are then cached under `$(brew --prefix)/var/speech-server/Library/Application Support/FluidAudio` and `$(brew --prefix)/var/speech-server/.cache/fluidaudio`. After editing the config, restart with:

```bash
sudo brew services restart macos-speech-server --sudo-service-user _speech-server
```

To remove the system service:

```bash
sudo brew services stop macos-speech-server
sudo sysadminctl -deleteUser _speech-server
sudo rm -rf "$(brew --prefix)/var/speech-server"
```

**Don't run the per-user and the system service at the same time** -- they'll fight over the same ports. If you switch from the system service back to the per-user one, the log file is left root-owned; remove it first:

```bash
sudo rm "$(brew --prefix)/var/log/speech-server.log"
```

### Upgrading

```bash
brew upgrade macos-speech-server
brew services restart macos-speech-server
```

If you run the system service instead, restart it with:

```bash
sudo brew services restart macos-speech-server --sudo-service-user _speech-server
```

`brew upgrade` itself is run as your normal user in both cases -- only the restart differs.

Your edited config is preserved; the new example config is written alongside it as `speech-server.yaml.default` so you can diff in any new options.

### Platform notes

Bottles are built for Apple Silicon on macOS 15+. On macOS 14 or Intel, Homebrew builds from source, which requires Swift 6.2 (Xcode 26 or matching Command Line Tools, macOS 15+) -- so macOS 14 currently can't install via Homebrew, and Intel Macs always build from source.

### Migrating from the old deploy/ scripts

Earlier versions of this project shipped `deploy/install-agent.sh` and `deploy/install-daemon.sh`,
which installed a launchd job labelled `com.local.speech-server`. That job is not related to the
Homebrew service and keeps holding ports 8080/10300 if left running, so remove it in two steps
around `brew install`:

**1. Before `brew install` -- stop and remove the old job and binary:**

```bash
# Per-user LaunchAgent
launchctl bootout "gui/$(id -u)/com.local.speech-server" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.speech-server.plist ~/bin/speech-server

# System LaunchDaemon
sudo launchctl bootout system/com.local.speech-server 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.local.speech-server.plist /usr/local/bin/speech-server
```

On Intel Macs Homebrew lives in `/usr/local`, so the old binary must be gone before installing --
otherwise the formula cannot link its own `speech-server` into `/usr/local/bin`.

**2. After `brew install`, before `brew services start` -- optional: keep your old settings by copying them over the freshly installed example:**

```bash
# Per-user config
cp ~/.config/speech-server/speech-server.yaml "$(brew --prefix)/etc/speech-server/speech-server.yaml"

# System config
sudo cp /etc/speech-server/speech-server.yaml "$(brew --prefix)/etc/speech-server/speech-server.yaml"
```

The old daemon installer created a `_speech-server` account with home `/Users/_speech-server`. If
you want the new [system service](#run-at-system-startup-optional), either reuse that account --
skip step 1 (`sysadminctl -addUser`) and run only step 2 (the `dscl`/`mkdir`/`chown` lines,
which repoint its home at `$(brew --prefix)/var/speech-server` and create that directory) and
step 3 (`sudo brew services start`). Optionally move the old model cache first so it doesn't
re-download:

```bash
sudo ditto "/Users/_speech-server/Library/Application Support/FluidAudio" \
  "$(brew --prefix)/var/speech-server/Library/Application Support/FluidAudio"
sudo ditto "/Users/_speech-server/.cache/fluidaudio" \
  "$(brew --prefix)/var/speech-server/.cache/fluidaudio"
```

Or remove the old account first with
`sudo sysadminctl -deleteUser _speech-server && sudo rm -rf /Users/_speech-server` and follow the
system-startup section from scratch. Old logs in `~/Library/Logs/speech-server/` or
`/var/log/speech-server/` can be deleted.

## Quick start (from source)

For contributors, or if Homebrew is not an option. If you installed via Homebrew, skip to [Configuration](#configuration).

```bash
swift build
swift run speech-server
```

On first launch, ASR and TTS models are downloaded automatically. This takes several minutes but only happens once; subsequent starts are fast.

The server listens on `http://localhost:8080` by default. The Wyoming protocol server listens on TCP port `10300` by default.

## Configuration

All server settings can be customised via a YAML config file. Create `speech-server.yaml` in the working directory (a fully-commented example is included in the repo). The Homebrew install ships this same example config at `$(brew --prefix)/etc/speech-server/speech-server.yaml`; the discovery rules below are unchanged, and the LaunchAgent/system service sets `SPEECH_SERVER_CONFIG` to point at it automatically.

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
  engine: parakeet      # parakeet (default) | qwen3
  parakeet:
    model_version: v3   # v3 = multilingual (25 langs, default), v2 = English-only
  # qwen3:              # Qwen3 ASR — encoder-decoder model with language hinting (macOS 15+)
  #   variant: int8     # int8 (default, ~900 MB) | f32 (~1.75 GB)
  #   language: en      # ISO 639-1 code; omit for auto-detect

tts:
  engine: pocket_tts    # pocket_tts (default) | avspeech | kokoro

  # AVSpeech settings (only used when engine: avspeech)
  # avspeech:
  #   default_voice: Samantha   # Short name or full identifier; nil = system locale default
  #   sample_rate: 22050        # Native AVSpeech output rate (Hz)

  # Kokoro TTS settings (only used when engine: kokoro)
  # kokoro:
  #   default_voice: af_heart   # Any Kokoro voice ID (e.g. af_heart, am_adam); default af_heart
```

All fields are optional — omitted fields use the defaults shown above.

### STT engines

Two STT engines are available:

| Engine | `engine:` value | Languages | Downloads | Notes |
|--------|----------------|-----------|-----------|-------|
| Parakeet TDT | `parakeet` | 25 (v3) or English-only (v2) | ~500 MB on first start | Default, CTC/TDT model, word-level timestamps |
| Qwen3 ASR | `qwen3` | 30+ with explicit language hinting | ~900 MB (int8) or ~1.75 GB (f32) | Encoder-decoder, macOS 15+ required |

#### `parakeet` (default)

Uses [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Parakeet TDT model (based on NVIDIA's architecture). Supports word-level timestamps and VAD-based segmentation. Two model versions: `v3` (multilingual, 25 languages) and `v2` (English-only, higher recall).

#### `qwen3` — encoder-decoder ASR with language hinting

Uses FluidAudio's Qwen3 ASR model — an encoder-decoder architecture (Whisper-family) that supports explicit language hinting via the `language` setting. This can improve accuracy for specific accents or languages since the model doesn't need to auto-detect the language. Requires macOS 15+.

```yaml
stt:
  engine: qwen3
  qwen3:
    variant: int8     # int8 (default, ~900 MB) or f32 (~1.75 GB)
    language: en      # ISO 639-1 code — set this for best results with a known language
```

Supported languages: zh, en, yue, ar, de, fr, es, pt, id, it, ko, ru, th, vi, ja, tr, hi, ms, nl, sv, da, fi, pl, cs, fil, fa, el, hu, mk, ro.

**Note:** Qwen3 does not provide word-level timestamps. The `verbose_json` response will include segment-level timing (from VAD) but the `words` array will be empty.

### TTS engines

Three TTS engines are available:

| Engine | `engine:` value | Voices | Sample rate | Downloads | Notes |
|--------|----------------|--------|-------------|-----------|-------|
| FluidAudio PocketTTS | `pocket_tts` | `alba` only | 24 kHz | ~200 MB on first start | Default |
| macOS AVSpeech | `avspeech` | 150+ system voices | 22050 Hz | None (ships with macOS) | Instant startup |
| FluidAudio Kokoro | `kokoro` | 50 voices, 8 languages | 24 kHz | ~300 MB on first start | High quality |

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

#### `kokoro` — FluidAudio Kokoro

Uses [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Kokoro CoreML model. 50 voices across 8 languages (American English, British English, Spanish, French, Hindi, Italian, Japanese, Brazilian Portuguese, Mandarin Chinese), synthesised at 24 kHz. Models are downloaded on first start and cached at `~/.cache/fluidaudio/Models/kokoro`.

```yaml
tts:
  engine: kokoro
  kokoro:
    default_voice: af_heart   # Optional — default is af_heart (American English female)
```

American English voices (production-quality): `af_alloy`, `af_aoede`, `af_bella`, `af_heart`, `af_jessica`, `af_kore`, `af_nicole`, `af_nova`, `af_river`, `af_sarah`, `af_sky`, `am_adam`, `am_echo`, `am_eric`, `am_fenrir`, `am_liam`, `am_michael`, `am_onyx`, `am_puck`, `am_santa`.

Other language voices are experimental (not QA'd). Full voice list: use `/v1/audio/speech` with an invalid voice to see the available options listed in the error message.

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

Deployment is handled entirely by Homebrew -- see [Installation](#installation). Use `brew services start macos-speech-server` for a per-user service, or the [system startup](#run-at-system-startup-optional) section for a boot-time service running under a dedicated role account.

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

The response is **streamed**: audio begins arriving before synthesis is complete, sentence by sentence. WAV responses include a standard 44-byte header (with unknown-size placeholders) followed by 16-bit PCM; PCM responses are raw 16-bit bytes. The sample rate depends on the active TTS engine (24 kHz for `pocket_tts` and `kokoro`, 22050 Hz for `avspeech`).

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
    Qwen3STTService.swift          # FluidAudio Qwen3 ASR implementation (qwen3 engine)
    AudioFormatDetection.swift     # Magic-byte audio format detection
    TTSService.swift               # TTS protocol + DI
    FluidTTSService.swift          # FluidAudio PocketTTS implementation (pocket_tts engine)
    AVSpeechTTSService.swift       # macOS AVSpeechSynthesizer implementation (avspeech engine)
    KokoroTTSService.swift         # FluidAudio Kokoro implementation (kokoro engine)
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
.github/workflows/
  release.yml                      # Tags v* -> creates a GitHub Release (bottles are built in the Homebrew tap)
```

## Contributing

Contributions are welcome. All changes go through a pull request — see [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow, code style, and PR guidelines.

Swift code is formatted with `swift format` (ships with Swift 6.2). A pre-commit hook is provided; install it with `scripts/install-hooks.sh`.

## License

AGPL-3.0 -- see [LICENSE](LICENSE).
