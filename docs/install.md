# Installation guide

Advanced installation topics for macos-speech-server: running as a system service at boot,
switching between the per-user and system service, upgrading the system service, and migrating
from the old pre-0.1 `deploy/` scripts. For basic installation, see
[Installation](../README.md#installation) in the README.

## Run at system startup (optional)

> **Warning: macOS system voices are limited under the system service.** A LaunchDaemon has no GUI login session, so `AVSpeechSynthesizer` only sees the ~70 built-in compact voices. Enhanced/Premium voices you downloaded (`Zoe (Premium)`, `Daniel (Enhanced)`, …) and the multi-locale voices (Eddy, Flo, Grandma, Grandpa, Reed, Rocko, Sandy, Shelley, …) are not listed and cannot be used. There is no known workaround. To use them with the `avspeech` engine, run the per-user service (`brew services start macos-speech-server`) as a user who stays logged in, and enable automatic login if the Mac must serve after a reboot. Voices downloaded by any user on the Mac are visible to every logged-in user. `pocket_tts` and `kokoro` are unaffected.

The per-user LaunchAgent installed by `brew services start macos-speech-server` (see [Installation](../README.md#installation)) only runs while you're logged in. For a server that starts at boot without a login session, running under a dedicated least-privilege account, use Homebrew's built-in system-service support (Apple's role-account pattern -- no custom scripts):

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

If `launchctl print` shows `state = spawn scheduled` and `last exit code = 78: EX_CONFIG`, launchd could not open the working directory or log file as `_speech-server` -- the process never started, so nothing is logged. Re-run the `chown` line from step 2 and restart.

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

## Switching between the per-user and the system service

**Don't run the per-user and the system service at the same time** -- they'll fight over the same ports. If you switch from the system service back to the per-user one, the working directory (and the log inside it) is still owned by `_speech-server`; hand it back to your user first:

```bash
sudo brew services stop macos-speech-server
sudo chown -R "$(id -un)" "$(brew --prefix)/var/speech-server"
brew services start macos-speech-server
```

## Upgrading the system service

Run `brew upgrade macos-speech-server` as your normal user, then restart the system service with:

```bash
sudo brew services restart macos-speech-server --sudo-service-user _speech-server
```

`brew upgrade` itself is always run as your normal user; only the restart command differs from the per-user service. Your edited config is preserved either way (the new example is written alongside it as `speech-server.yaml.default`).

## Migrating from the old deploy/ scripts

If you installed a pre-0.1 version with `deploy/install-agent.sh` or `deploy/install-daemon.sh`, the old `com.local.speech-server` launchd job must be removed **before** `brew install`. See [upgrading-pre-0_1.md](upgrading-pre-0_1.md) for the steps, including how to keep your old config and model cache.
