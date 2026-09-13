# Upgrading from a pre-0.1 install (the `deploy/` scripts)

Versions before 0.1 shipped `deploy/install-agent.sh` and `deploy/install-daemon.sh`, which
installed a launchd job labelled `com.local.speech-server`. That job is not related to the
Homebrew service and keeps holding ports 8080/10300 if left running, so remove it in two steps
around `brew install`.

## 1. Before `brew install` -- stop and remove the old job and binary

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

## 2. Install

Follow [Installation](../README.md#installation) in the README:

```bash
brew install dokterbob/macos-speech-server/macos-speech-server
```

Don't start the service yet if you want to carry over your old config (next step).

## 3. After `brew install`, before `brew services start` -- optional: keep your old settings

Copy the old config over the freshly installed example:

```bash
# Per-user config
cp ~/.config/speech-server/speech-server.yaml "$(brew --prefix)/etc/speech-server/speech-server.yaml"

# System config
sudo cp /etc/speech-server/speech-server.yaml "$(brew --prefix)/etc/speech-server/speech-server.yaml"
```

Then start the service: `brew services start macos-speech-server` for a per-user service, or
continue below for a system service.

## 4. System service: reusing the old `_speech-server` account

The old daemon installer created a `_speech-server` account with home `/Users/_speech-server`.
If you want the new [system service](install.md#run-at-system-startup-optional), either reuse
that account or start from scratch.

**Reuse it**: skip step 1 of the system-startup section (`sysadminctl -addUser`) and run only
step 2 (the `dscl`/`mkdir`/`chown` lines, which repoint its home at
`$(brew --prefix)/var/speech-server` and create that directory) and step 3
(`sudo brew services start`). Optionally move the old model cache first so it doesn't
re-download:

```bash
sudo ditto "/Users/_speech-server/Library/Application Support/FluidAudio" \
  "$(brew --prefix)/var/speech-server/Library/Application Support/FluidAudio"
sudo ditto "/Users/_speech-server/.cache/fluidaudio" \
  "$(brew --prefix)/var/speech-server/.cache/fluidaudio"
```

Run the `ditto` commands before the `chown -R` line in step 2, so the copied files end up owned
by `_speech-server` too.

**Start from scratch**: remove the old account first with
`sudo sysadminctl -deleteUser _speech-server && sudo rm -rf /Users/_speech-server` and follow the
system-startup section as written.

## 5. Clean up

Old logs in `~/Library/Logs/speech-server/` or `/var/log/speech-server/` can be deleted. The
Homebrew service writes its log to `$(brew --prefix)/var/speech-server/speech-server.log`.
