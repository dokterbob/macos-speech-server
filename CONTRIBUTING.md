# Contributing to macos-speech-server

Thanks for your interest in contributing. This document covers the development workflow, conventions, and expectations for contributors.

See [README.md](README.md) for requirements, configuration, and API documentation.

## Getting started

```bash
git clone https://github.com/dokterbob/macos-speech-server.git
cd macos-speech-server
cp speech-server.yaml.example speech-server.yaml
swift build
```

On first run, ASR and TTS models are downloaded automatically (several minutes, cached after).

## Development workflow

All changes go through a pull request — never push directly to `main`.

1. **Create a branch** from an up-to-date `main`:
   ```bash
   git checkout main && git pull
   git checkout -b feature/my-feature   # or fix/issue-description
   ```

2. **Install the pre-commit hook** (once) to catch formatting issues before they reach CI:
   ```bash
   scripts/install-hooks.sh
   ```

3. **Write tests first.** Unit tests live in `Tests/speech-serverTests/`. The project follows test-driven development: write the test file before the implementation. The test should fail to compile or fail to pass until the implementation is added — this ensures the test actually defines the contract.

4. **Implement the change.**

5. **Format all Swift files** before committing:
   ```bash
   swift format --in-place --recursive Sources/ Tests/
   ```

6. **Run the tests:**
   ```bash
   swift test
   ```
   Unit tests (no models required) run in seconds. Integration tests download FluidAudio models on first run; subsequent runs use the on-disk cache. Run a subset with `--filter`:
   ```bash
   swift test --filter WyomingSession   # fast, no models
   swift test --filter Transcription    # needs models
   ```

7. **Open a pull request** targeting `main`. See [PR guidelines](#pr-guidelines) below.

## Code style

All Swift code is formatted with `swift format` (bundled with Swift 6.2). The config is in `.swift-format` at the repo root:

- 120-character line length
- 4-space indentation
- `AlwaysUseLowerCamelCase` enabled — do not use snake_case property names; use explicit `CodingKeys` when mapping to snake_case JSON fields

CI enforces formatting on every push and PR. The pre-commit hook catches issues locally before they reach CI.

## Project conventions

- **Async middleware**: use `AsyncMiddleware` (not `EventLoopFuture`-based `Middleware`).
- **Logging**: `request.logger` inside request handlers, `app.logger` during setup. All operational notices use `.notice`; anomalies use `.warning` or higher.
- **Errors**: all errors bubble up through `OpenAIErrorMiddleware`, which converts them to OpenAI-format JSON. Throw `Abort(.badRequest)` for client errors, or create a typed error that maps to the appropriate status.
- **Config**: all runtime settings live in `ServerConfig`. Adding a new option means adding a field with a sensible default via `decodeIfPresent` — partial configs must remain valid.
- **New engines**: adding a new STT or TTS engine requires: a `case` in the engine enum, a `Settings` struct, a `case` in the `configure.swift` switch, and an implementation of `STTService` or `TTSService`.

## Keeping docs in sync

- **User-visible changes** (new endpoint, changed behaviour, new field): update [README.md](README.md).
- **Architectural changes** (new service, new constraint, new convention, new gotcha): update [AGENTS.md](AGENTS.md).
- Both files should be updated in the same commit as the code change.

## PR guidelines

- **One concern per PR.** Keep PRs focused — a bug fix and a refactor are separate PRs.
- **Explain the why.** The PR description should explain what problem is being solved, not just list what changed. Link to any relevant issues.
- **CI must be green.** Both the formatting lint check and the test suite must pass before merging.
- **Tests are required.** New behaviour needs tests. Bug fixes should include a test that would have caught the bug.
- **Draft PRs** are welcome for early feedback on direction before the implementation is complete.

## Reporting issues

Open a GitHub issue with:

- macOS version and Swift version (`swift --version`)
- Steps to reproduce
- Expected vs. actual behaviour
- Relevant log output (run with `log_level: debug` in `speech-server.yaml`)

## License

By contributing, you agree that your contributions will be licensed under the [AGPL-3.0](LICENSE).
