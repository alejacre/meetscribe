# Contributing to MeetScribe

MeetScribe welcomes focused bug fixes, tests, documentation, new meeting-app definitions, transcript-agent adapters, and storage destinations.

## Before You Start

1. Search existing issues and pull requests.
2. Open an issue before a large behavioral or architectural change.
3. Keep privacy-sensitive behavior opt-in and visible.
4. Never add real meeting audio, transcripts, credentials, hostnames, or personal data to tests or examples.

## Development Setup

Requirements:

- macOS 15 or later on Apple Silicon
- Xcode 16 or later
- Swift 6

Build and test:

```bash
swift build -Xswiftc -warnings-as-errors
scripts/run-tests.sh
scripts/check-coverage.sh
swift build -c release -Xswiftc -warnings-as-errors
```

Build the application bundle:

```bash
./build.sh
open build/MeetScribe.app
```

The first launch requests macOS privacy permissions. Unit tests must not require those permissions, network access, a real meeting, or external credentials.

## Design Rules

- Preserve the local recording before invoking an agent or destination.
- Keep transcript agents and remote publication disabled by default.
- Invoke commands with executable and argument arrays, never shell interpolation.
- Treat transcripts, audio, environment variables, and SSH configuration as sensitive.
- Make retries idempotent and persist enough state to recover after restart.
- Add a schema migration before changing persisted configuration or manifest fields incompatibly.
- Prefer small protocols at integration boundaries over provider-specific conditionals in `RecordingCoordinator`.

See [Architecture](docs/architecture.md), [Agent adapters](docs/agent-adapters.md), and [Destinations](docs/destinations.md).

## Tests

Tests should use generated text/audio, temporary directories, fake executables, and local bare Git repositories. A change to a trigger, agent, destination, manifest, subprocess, or recovery path needs a focused regression test.

Manual checks are appropriate for:

- Screen Recording and Microphone permission flows
- Capture from a real meeting application
- Notification actions
- A real SSH/SFTP server
- Developer ID signing and notarization

Describe any manual checks in the pull request.

## Pull Requests

- Keep the change focused.
- Explain user-visible behavior and privacy impact.
- Include validation commands and their results.
- Update documentation for configuration or contract changes.
- Do not commit generated `.build/`, `build/`, recordings, or credentials.

By contributing, you agree that your contribution is licensed under the MIT License.
