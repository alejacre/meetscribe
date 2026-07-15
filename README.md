# MeetScribe

A tiny macOS menu bar app that records your meetings and transcribes them locally  -  no cloud, no accounts, no per-minute billing.

MeetScribe watches for Zoom, Slack huddles, Amazon Chime, Microsoft Teams, FaceTime, and WebEx grabbing your microphone, offers to record with one click, and turns the audio into a clean, speaker-attributed Markdown transcript using [MLX Whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) running on-device.

## Features

- **Meeting detection** - polls CoreAudio for known meeting apps and offers to record via a notification action. Manual record/stop always works too.
- **Dual-track capture** - records your mic and system audio (everyone else) as separate tracks via `ScreenCaptureKit`, so speaker attribution (`Me` / `Them`) comes from the physical source, not guesswork.
- **Local transcription** - runs `mlx_whisper` per track, interleaves segments by timestamp, and suppresses mic-picked-up echo of the system track for people not on headphones.
- **Optional Claude cleanup** - if the `claude` CLI is available, a headless pass fixes punctuation, removes filler words, adds a short summary, and derives a topic slug for the note filename. Falls back to the raw whisper transcript if unavailable.
- **Obsidian-friendly output** - each recording becomes a flat Markdown note (YAML frontmatter + transcript) with audio and raw JSON tucked into a hidden `.assets/` sidecar folder, so it drops straight into a notes vault without cluttering it.
- **Menu bar native** - no Dock icon, live elapsed-time counter, recent recordings menu, in-app transcript search, global hotkey (`⌥⇧R`) to start/stop, launch at login.
- **First-run setup wizard** - installs the transcription engine, pre-downloads a model, and walks you through permissions on first launch. Re-openable anytime from the menu.

## Requirements

- macOS 15+ (Apple Silicon)
- Screen Recording and Microphone permissions (the setup wizard requests them)
- Optional: [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) (`claude`) for transcript cleanup

The transcription engine ([`mlx_whisper`](https://github.com/ml-explore/mlx-examples/tree/main/whisper)) does not need to be pre-installed - the setup wizard installs it for you via [`uv`](https://docs.astral.sh/uv/) (bootstrapping `uv` itself if needed) and downloads the whisper model.

## Install

Clone and build a signed `.app` bundle:

```bash
git clone https://github.com/alejacre/meetscribe.git
cd meetscribe
./build.sh
open build/MeetScribe.app
```

`build.sh` compiles a release build with `swift build`, assembles the `.app`, and code-signs it. It looks for a local self-signed identity named `MeetScribe Dev Signing` to keep the signature stable across rebuilds (so macOS doesn't re-ask for Screen Recording / Microphone permission every time); if that identity isn't found it falls back to an ad-hoc signature.

To create your own stable signing identity: open **Keychain Access** → **Certificate Assistant** → **Create a Certificate…**, name it `MeetScribe Dev Signing`, type "Code Signing".

## First-run setup

On first launch a setup wizard opens automatically and walks you through:

1. **Transcription engine** - detects `mlx_whisper`; if missing, one-click installs it with `uv tool install mlx-whisper` (installing `uv` first if needed), streaming progress live.
2. **Whisper model** - pick a model and pre-download it (~1.5 GB for the default turbo) so your first real transcription is fast.
3. **Permissions** - grants Screen Recording, Microphone, and Notifications with deep links to the right System Settings panes.
4. **Output folder** - where notes and audio are saved (point it at a notes vault if you like).
5. **Claude cleanup** - detects the `claude` CLI and toggles the cleanup pass.

Re-run it anytime from the menu bar → **Setup assistant…**.

## Usage

1. Launch `MeetScribe.app` - a waveform icon appears in the menu bar.
2. Join a meeting in a supported app; MeetScribe notifies you and offers to record.
3. Stop recording from the menu, the notification, or `⌥⇧R`.
4. Transcription runs in the background; a notification fires when the note is ready.
5. Find it via **Recent recordings**, **Search transcripts…**, or directly in the output folder.

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
| Claude cleanup | Toggle the punctuation/filler/summary pass |
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

Unit tests cover transcript formatting, echo suppression, note-path conventions, settings persistence, the WAV builder, subprocess streaming, and the wizard's model-cache mapping / progress parsing / log handling.

## Non-goals

- ML speaker diarization within "Them" (per-remote-person identification)
- Auto-record without confirmation
- Cloud upload or accounts

## License

MIT - see [LICENSE](LICENSE).
