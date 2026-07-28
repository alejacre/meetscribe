# MeetScribe

A tiny macOS menu bar app that records meetings and transcribes them locally, with optional explicitly enabled Claude cleanup.

MeetScribe watches for Zoom, Slack huddles, Amazon Chime, Microsoft Teams, FaceTime, and WebEx grabbing your microphone, offers to record with one click, and turns the audio into a clean, speaker-attributed Markdown transcript using [MLX Whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) running on-device.

## Features

- **Meeting detection** - polls CoreAudio for known meeting apps and offers to record via a notification action. Manual record/stop always works too.
- **Dual-track capture** - records your mic and meeting-app audio as separate tracks via `ScreenCaptureKit`, so speaker attribution (`Me` / `Them`) comes from the physical source, not guesswork. Manual recording is labeled as all-system-audio capture.
- **Local transcription** - runs `mlx_whisper` per track, interleaves segments by timestamp, and suppresses mic-picked-up echo of the system track for people not on headphones.
- **Optional Claude cleanup** - disabled by default. When explicitly enabled, the full transcript is sent to the service configured by the `claude` CLI. MeetScribe disables Claude tools and session persistence, validates that every timestamped speaker turn survives, and falls back to the raw transcript on failure.
- **Obsidian-friendly output** - each recording becomes a flat Markdown note (YAML frontmatter + transcript) with audio and raw JSON tucked into a hidden `.assets/` sidecar folder, so it drops straight into a notes vault without cluttering it.
- **Menu bar native** - no Dock icon, live elapsed-time counter, recent recordings menu, in-app transcript search, global hotkey (`⌥⇧R`) to start/stop, launch at login.
- **First-run setup wizard** - installs the transcription engine, pre-downloads a model, and walks you through permissions on first launch. Re-openable anytime from the menu.

## Requirements

- macOS 15+ (Apple Silicon)
- Xcode 16+ / Swift 6
- Screen Recording and Microphone permissions (the setup wizard requests them)
- [`uv`](https://docs.astral.sh/uv/) installed from Homebrew or a verified Astral package
- Optional: [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) (`claude`) for transcript cleanup

The setup wizard installs the pinned transcription engine through `uv`. It does not execute remote installer scripts. Supported model revisions are locked and verified before download.

## Install

Clone and build a signed `.app` bundle:

```bash
git clone https://github.com/alejacre/meetscribe.git
cd meetscribe
./build.sh
open build/MeetScribe.app
```

`build.sh` compiles, assembles, and signs `build/MeetScribe.app`. It never modifies `/Applications`. Run `./install.sh` when you explicitly want to replace the installed copy.

The build looks for a local identity named `MeetScribe Dev Signing` to keep the signature stable across development rebuilds; otherwise it uses an ad-hoc signature. Distribution releases use `scripts/release.sh`, which requires a Developer ID Application identity and notarytool profile, enables hardened runtime, notarizes and staples the app, runs Gatekeeper assessment, and emits a SHA-256 checksum.

To create your own stable signing identity: open **Keychain Access** → **Certificate Assistant** → **Create a Certificate…**, name it `MeetScribe Dev Signing`, type "Code Signing".

## First-run setup

On first launch a setup wizard opens automatically and walks you through:

1. **Transcription engine** - detects `mlx_whisper`; if missing, installs the pinned version with `uv`, streaming progress live.
2. **Whisper model** - pick a locked model revision and pre-download it (~1.5 GB for the default turbo).
3. **Permissions** - grants Screen Recording, Microphone, and Notifications with deep links to the right System Settings panes.
4. **Output folder** - where notes and audio are saved (point it at a notes vault if you like).
5. **Claude cleanup** - optional explicit opt-in, with disclosure that the complete transcript leaves the Mac.

Re-run it anytime from the menu bar → **Setup assistant…**.

## Usage

1. Launch `MeetScribe.app` - a waveform icon appears in the menu bar.
2. Join a meeting in a supported app; MeetScribe notifies you and offers to record.
3. Stop recording from the menu, the notification, or `⌥⇧R`.
4. Transcription runs in the background; a notification fires when the note is ready.
5. Find it via **Recent recordings**, **Search transcripts…**, or directly in the output folder.

Detected meetings are filtered to the selected meeting application. Manual recording captures all system audio and is labeled accordingly. Failed transcriptions remain visible in **Recent recordings** with a retry action. Recordings can be moved to Trash from the same menu.

## Output

Each recording produces a note at `<output-folder>/<date>-<topic>.md`:

```markdown
---
date: 2026-07-13
attendees: []
tags: [meeting, transcript]
---

## Summary
(added by the Claude cleanup pass, if enabled)

## Transcript
[00:00:03] **Me:** ...
[00:00:07] **Them:** ...

<!-- meetscribe: app=zoom, duration=45:02, model=whisper-large-v3-turbo, cleaned=true -->
```

Audio and raw Whisper JSON live alongside it in a hidden sidecar so they don't clutter a notes vault:

```
<output-folder>/
├── 2026-07-13-q3-budget-review.md
└── .assets/2026-07-13-q3-budget-review/
    ├── audio.m4a      # mixed recording (for listening)
    ├── mic.m4a        # your voice track
    ├── system.m4a     # everyone else's track
    └── transcript.json
```

## Settings

| Setting | Description |
|---|---|
| Output folder | Where notes and assets are written (default `~/Recordings`, change to point at a notes vault) |
| Whisper model | Any `mlx-community/whisper-*` model |
| `mlx_whisper` path | Location of the transcription binary |
| Claude cleanup | Explicit opt-in to send transcripts to the configured Claude service |
| Global shortcut | `⌥⇧R` start/stop toggle |
| Launch at login | via `SMAppService` |

## Architecture

| Component | Responsibility |
|---|---|
| `MeetingDetector` | CoreAudio polling for apps using the microphone |
| `AudioRecorder` | `ScreenCaptureKit` + `AVAudioEngine` dual-track capture, offline mixdown |
| `Transcriber` | Per-track `mlx_whisper` subprocess invocation and JSON parsing |
| `TranscriptFormatter` | Segment interleaving, echo suppression, Markdown rendering |
| `ClaudeCleaner` | Optional headless `claude -p` cleanup pass |
| `RecordingCoordinator` | Orchestrates the record → transcribe → cleanup pipeline and notifications |
| `RecordingSession` | Note/asset path conventions |
| `SetupModel` / `SetupView` | First-run wizard: engine install, model download, permissions |
| `ToolFinder` | Locates CLI binaries (candidate dirs + login-shell PATH) |
| `Permissions` | Screen Recording / Microphone / Notification TCC helpers |
| `Subprocess` | Sync + streaming subprocess execution |

## Testing

```bash
swift test
```

Unit tests cover recording startup cancellation, failed-recording recovery, transactional finalization, file permissions, real Whisper invocation boundaries, transcript validation, formatter behavior, subprocess process-tree timeout/cancellation, model locks, settings, and setup helpers. CI runs warning-free debug and release builds plus coverage.

## Release

Create a notarized release:

```bash
CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="meetscribe-notary" \
VERSION="1.1.0" \
scripts/release.sh
```

The script produces `build/MeetScribe-<version>.zip` and a matching `.sha256`.

## Privacy

Audio, raw Whisper JSON, and Markdown transcripts are stored locally with owner-only permissions and retained until you move the recording to Trash. Selecting a synced output folder can upload those files through that provider. Notification text is generic.

Local Whisper transcription does not use a cloud service. Claude cleanup is a separate, disabled-by-default feature that sends the complete transcript to the service configured by the user's Claude CLI.

## Non-goals

- ML speaker diarization within "Them" (per-remote-person identification)
- Auto-record without confirmation
- Cloud upload or accounts

## License

MIT - see [LICENSE](LICENSE).
