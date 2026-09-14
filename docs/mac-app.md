# Native Mac app through Homebrew

The optional app provides onboarding, configuration, service controls, logs and speech tests.
It bundles the same server as the CLI but is installed as a **separate Homebrew formula**, not
a cask. The app targets Apple Silicon on macOS 15+. The standalone CLI formula stays independent.

The app formula is initially delivered as a preview PR in the project's tap. The commands below
become available once that PR is merged and its bottles published. Until then, use the source
build instructions below. Neither installation needs a paid Apple developer account.

## Install and use

```sh
brew install dokterbob/macos-speech-server/macos-speech-server-app
speech-server-app
```

Homebrew installs the app under its formula prefix. The launcher opens the stable
`$(brew --prefix)/opt/macos-speech-server-app/libexec/Speech Server.app` path. The CLI-only
formula's `speech-server` command is unchanged; the app includes a separate
`speech-server-app-cli` command. Both packages can be installed, but their running services
must use different ports.

The first installation requires Homebrew and a terminal command. Daily configuration and
service management take place in the GUI. Choose engines and click **Set Up & Start**.
Parakeet v3 and PocketTTS are the defaults. They download roughly 700 MB on first start;
other engines can require up to 1.75 GB per model. The app displays loading stages. Speech
processing works offline after downloading the models.

The app creates a conventional per-user LaunchAgent at:

```
~/Library/LaunchAgents/org.dokterbob.speech-server.agent.plist
```

This uses `launchctl` in the current user's GUI login domain, without sudo, an installer,
SMAppService, or Apple-issued certificates. macOS can still show a background-item notification
or require approval in **System Settings → General → Login Items & Extensions**. Homebrew
installation is not a promise that every macOS permission prompt disappears.

The supervisor remains available when speech is stopped or model loading fails. Closing or
quitting the GUI leaves speech running. **Stop** stops the server; **Start service at login**
controls the next login. Disabling that switch does not stop a running service. Serving before
login remains an advanced standalone CLI feature. Per-user operation supports downloaded
macOS Enhanced/Premium voices.

## Settings, logs and recovery

- **Settings** offers engine, voice, network, upload-limit and logging controls. Available voices
  come from the running engine; start a selected engine to populate its voice list.
- **Save** validates and writes settings. **Save & Restart** applies them. The UI distinguishes
  pending settings from the active service; engine changes require a restart.
- **YAML** allows text editing. Saving from the form rewrites the document, including comments.
  Direct YAML edits preserve the text. **Restore Previous** restores the previous saved version.
- **Reload** picks up manual edits. Revision checks prevent stale editors overwriting newer files.
  Invalid hand-edited YAML can be repaired in the editor or restored.
- **Logs** shows the latest 128 KB of server logs. The server log rotates at 2 MB with one backup.
  `agent.log` in the same folder contains launch and registration diagnostics.
- **Try Speech** plays generated speech and transcribes selected audio files up to 50 MB.

Config: `~/Library/Application Support/Speech Server/speech-server.yaml`.
Logs: `~/Library/Logs/Speech Server/`. Existing FluidAudio model cache locations are retained.
This configuration is separate from the standalone Homebrew formula's configuration.

Startup failures remain visible without continuous retries. A server that crashes after becoming
ready gets at most three automatic retries until the next explicit Start/Restart. Graceful Stop
waits ten seconds before forced termination. Disabling background operation can also unload an
agent whose management socket is unavailable.

## Connect other devices

The default is **this Mac only**. Enable sharing during onboarding or set the HTTP/Wyoming hosts
to `0.0.0.0` and restart. The Overview lists network addresses and ports. Use an address reachable
from the other device; a specific bind address only accepts connections on that interface.

In Home Assistant, use **Settings → Devices & services → Add integration → Wyoming Protocol**
and enter the Mac's address and Wyoming port, default 10300. HTTP clients use the displayed URL
with `/v1`, normally on port 8080. These speech protocols have no authentication; share only on
a trusted local network, without internet port forwarding. Management remains on a private local
socket and is not exposed through either speech protocol.

## Updates and uninstall

```sh
brew upgrade macos-speech-server-app
```

Then quit and reopen the app. It compares the installed build with the LaunchAgent configuration.
An already-enabled older agent is stopped gracefully and bootstrapped with the new build, preserving
whether speech was running or stopped. A disabled agent is not automatically enabled. The agent's
executable path uses Homebrew's stable `opt` link; its running server uses the same resolved keg
as the agent. The app contains no Sparkle framework and never overwrites Homebrew-managed files.
Until reopened, an existing app/service may still be running its previous version. If an old keg
has been removed by cleanup, reopen the app before starting speech again.

Before uninstalling, click **Disable Background Service**, or run:

```sh
speech-server-app-cli service --app disable
brew uninstall macos-speech-server-app
```

Formula removal does not run user-session uninstall scripts, so disable first. Configuration,
logs and models are retained. No files or aliases are installed in Applications automatically;
users can keep the running app in the Dock if desired.

## Existing CLI users

The app does not stop or migrate the existing CLI service. Occupied ports are reported before
model downloads. To switch deliberately, stop the per-user CLI service with
`brew services stop macos-speech-server` (see [installation](install.md) for system-service
commands), copy desired configuration into the app's YAML editor, and start the app-managed service.
To switch back, disable the app's background service before starting the CLI service.

The app's bundled CLI supports the same headless server and management commands. Replace
`speech-server-app-cli` with `speech-server` if using a standalone build of this revision:

```sh
speech-server-app-cli service --app enable
speech-server-app-cli service --app status --json
speech-server-app-cli service --app start
speech-server-app-cli service --app stop
speech-server-app-cli service --app restart
speech-server-app-cli service --app startup off
speech-server-app-cli service --app logs
speech-server-app-cli config validate ./settings.yaml --json
speech-server-app-cli config --app show --json
speech-server-app-cli config --app save ./settings.yaml --revision REVISION
speech-server-app-cli config --app restore --revision REVISION
speech-server-app-cli service --app disable
```

Use the revision from `config --app show --json` for save/restore. Commands run before model
initialization. The explicit `--app` selects the app-managed service; `brew services` continues
to manage the independent CLI formula. Enable/disable can also be invoked on the app executable
with `--enable-background` / `--disable-background`, without opening a GUI window.

## Build, test and release bottles

```sh
swift build --product speech-server
swift test
swift test --package-path Management
swift build --package-path App
CONFIGURATION=debug scripts/app/build.sh
```

The existing XCTest suite needs full Xcode's test frameworks. The separate management tests use
Swift Testing and no models. `scripts/app/check.sh` runs formatting, management tests, app builds
and ad-hoc bundle verification. Packaging rejects unhandled new runtime resource bundles instead
of silently producing an app that depends on source-tree resources.

The source app is built at `dist/Speech Server.app`; release builds are the default when
`CONFIGURATION` is omitted. All executables are ad-hoc signed. That establishes local code
integrity but does not notarize a browser-downloaded copy. `scripts/app/release.sh` can create
an optional unnotarized preview ZIP; the supported binary distribution is the formula bottle.

Maintainer workflow:

1. Publish the source revision (normally a release tag; the initial preview can pin a commit).
2. Download that immutable source archive and render the new app formula:

   ```sh
   scripts/app/make-formula.py VERSION SOURCE_URL SOURCE_ARCHIVE > macos-speech-server-app.rb
   ```

3. Add/update `Formula/macos-speech-server-app.rb` in a PR to
   `dokterbob/homebrew-macos-speech-server`. Keep the CLI formula unchanged. The template builds
   from source and installs only within its formula prefix; it does not register a user agent
   during installation. The app does that on explicit setup.
4. Run the tap's existing CI on macOS 15 Apple Silicon. Its `--skip-new` option only skips
   extra new-formula audits; it still builds the new formula and its bottle.
5. Review the built bottle, then use the tap's existing `publish.yml` workflow for that PR to
   publish bottles and merge the generated bottle metadata, as with the CLI formula.

No Developer ID, notarization credentials, or Sparkle signing keys are involved. GitHub App
credentials can be supplied via `GH_TOKEN="$(gh app-auth token)" gh …`; git uses the configured
credential helper. Repository instructions reserve workflow-file pushes for a maintainer, so
workflow changes are provided for that handoff separately from source/formula PR commits.

Before announcing the first app bottle, test an actual bottle installation on a clean macOS 15
Apple Silicon Mac: GUI launch, background approval, cold/interrupted downloads, login startup,
app exit while serving, speech playback/transcription, conflicts with the CLI service, upgrade
while running and stopped, restart after cleanup, and disable/uninstall. Unit tests and local
ad-hoc verification do not establish the absence of OS approval prompts on other Macs.
