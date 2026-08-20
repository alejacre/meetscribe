# MeetScribe

[![CI](https://github.com/alejacre/meetscribe/actions/workflows/ci.yml/badge.svg)](https://github.com/alejacre/meetscribe/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

MeetScribe is a local-first macOS menu bar app for recording meetings, transcribing them on-device, optionally processing the transcript with an agent, and publishing the result to storage you control.

The built-in integration uses Claude Code, but the transcript-agent contract accepts any executable that reads Markdown from stdin and returns validated Markdown on stdout. Recordings always land in a local workspace first; Git and SFTP over SSH are optional destinations.

## Features

- **Configurable triggers** - choose `Ignore`, `Ask before recording`, or `Record automatically` for each meeting app. Add any macOS app by bundle identifier.
- **Dual-track capture** - records your microphone and meeting audio separately with `ScreenCaptureKit`, producing deterministic `Me` / `Them` attribution.
- **Local transcription** - runs locked MLX Whisper models on Apple Silicon, interleaves timestamps, and suppresses speaker echo captured by the microphone.
- **Pluggable transcript agents** - use no agent, the hardened Claude Code adapter, or a custom command with an editable prompt and arguments.
- **Storage you control** - choose the local output folder and optionally publish completed recordings to a Git repository or an SFTP server using your OpenSSH configuration.
- **Recoverable jobs** - each recording has a private, versioned manifest. Failed transcription and publication jobs remain available for retry and publication resumes after restart.
- **Native macOS workflow** - menu bar status, notifications, recent recordings, transcript search, global start/stop shortcut, and launch at login.

## Requirements

- macOS 15 or later on Apple Silicon
- Xcode 16 or later with Swift 6
- Screen Recording and Microphone permissions
- [`uv`](https://docs.astral.sh/uv/) installed from Homebrew or a verified Astral package
- Optional: [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for the built-in transcript agent
- Optional: Git and/or an OpenSSH-compatible SFTP server for remote publication

## Build

```bash
git clone https://github.com/alejacre/meetscribe.git
cd meetscribe
./build.sh
open build/MeetScribe.app
```

`build.sh` creates and verifies `build/MeetScribe.app`. It uses a local code-signing identity named `MeetScribe Dev Signing` when available and otherwise applies an ad-hoc development signature. It never modifies `/Applications`; run `./install.sh` explicitly to install the app.

The first-run assistant:

1. Installs the pinned `mlx-whisper` version into MeetScribe-managed directories using your existing `uv` installation.
2. Downloads and verifies a locked Whisper model revision.
3. Walks through Screen Recording, Microphone, and Notification permissions.
4. Lets you select the local recording folder.
5. Offers an explicit opt-in to the Claude Code transcript agent.

## Configure

### Triggers

Open **Settings > Triggers** and select a policy for each application:

- `Ignore` never prompts or starts a recording.
- `Ask before recording` sends an actionable notification.
- `Record automatically` starts while the configured app is actively using the microphone.

Zoom, Slack, Amazon Chime, Microsoft Teams, FaceTime, and Webex are included. Custom applications require their macOS bundle identifier.

### Transcript Agents

Open **Settings > Agent** and select:

- `None` to keep local Whisper output unchanged.
- `Claude Code` to use the local `claude` CLI with tools and session persistence disabled.
- `Custom command` to select any executable, arguments, and prompt.

Custom commands run directly without a shell. The transcript is provided on stdin, and the returned Markdown must preserve frontmatter, metadata, timestamps, and speaker markers. See [Agent adapters](docs/agent-adapters.md).

### Destinations

Local storage is always the source of truth. Optional destinations publish after transcription:

- **Git repository** copies the selected artifacts, commits them, and pushes the current branch to its configured upstream.
- **SFTP over SSH** uses `/usr/bin/sftp`, `~/.ssh/config`, SSH keys or agent authentication, strict host-key checking, and a temporary remote directory followed by `rename`.

Audio export is disabled by default for both destinations. See [Destinations](docs/destinations.md).

## Output

Each recording produces a Markdown note and a hidden sidecar directory:

```text
<output-folder>/
|-- 2026-08-20-project-review.md
`-- .assets/2026-08-20-project-review/
    |-- manifest.json
    |-- audio.m4a
    |-- mic.m4a
    |-- system.m4a
    `-- transcript.json
```

```markdown
---
date: 2026-08-20
attendees: []
tags: [meeting, transcript]
---

## Summary
Added by the configured transcript agent, when enabled.

## Transcript
[00:00:03] **Me:** ...
[00:00:07] **Them:** ...

<!-- meetscribe: app=zoom, duration=45:02, model=whisper-large-v3-turbo, cleaned=true, processor=claude-code -->
```

The manifest records a stable UUID, source application, trigger, lifecycle, transcript run, and per-destination publication state. See [Recording manifest](docs/recording-manifest.md).

## Privacy

- Audio and transcription are local by default.
- Owner-only permissions are applied to recording assets and manifests.
- Transcript agents and remote destinations are disabled until explicitly configured.
- Claude Code and custom agents receive the complete transcript when enabled.
- Git and SFTP export Markdown, manifest, and raw transcript JSON. Audio is separate opt-in.
- MeetScribe never stores SSH private keys or passwords.

You are responsible for obtaining any consent required to record or process a meeting in your jurisdiction and organization.

## Architecture

```text
Meeting trigger -> Local recording -> MLX Whisper -> Transcript agent -> Local note
                                                              |
                                                    Git / SFTP destinations
```

The pipeline is built around typed configuration, a persistent recording manifest, transcript-agent adapters, and destination adapters. See [Architecture](docs/architecture.md).

## Testing

```bash
scripts/run-tests.sh
scripts/check-coverage.sh
swift build -c release -Xswiftc -warnings-as-errors
```

The suite includes unit tests for configuration, manifests, trigger state, transcript validation, process-tree handling, and recovery, plus a Git integration test that commits and pushes to a local bare remote.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Bug reports and feature proposals use the repository issue forms. Security issues follow [SECURITY.md](SECURITY.md).

## Non-goals

- Identifying individual remote speakers within the `Them` track
- Hosting user accounts, transcripts, or credentials
- Bypassing macOS permissions, meeting-app controls, or recording-consent requirements
- Storing SSH passwords or private keys

## License

MIT - see [LICENSE](LICENSE).
