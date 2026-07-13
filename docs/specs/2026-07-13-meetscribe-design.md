# MeetScribe  -  Design Spec

Date: 2026-07-13
Status: Approved pending user review

## Purpose

macOS menu bar app that records meeting audio (Zoom, Slack huddles, Chime, Teams, FaceTime, WebEx  -  any app using the microphone), then transcribes it locally with MLX Whisper. Output per meeting: raw audio file + cleanly formatted markdown transcript.

## Target environment

- macOS 26.x (user is on 26.5), Apple Silicon.
- Swift + SwiftUI (`MenuBarExtra`), no Dock icon (LSUIElement).
- Transcription via existing `mlx_whisper` CLI at `~/.local/share/mise/installs/python/3.12/bin/mlx_whisper` (mlx-whisper 0.4.3). Path configurable.
- No BlackHole / aggregate devices  -  system audio captured natively via ScreenCaptureKit.

## Components

### 1. AudioRecorder
- Captures **system audio** (what the user hears) via ScreenCaptureKit audio-only capture.
- Captures **microphone** (what the user says) via AVAudioEngine.
- Writes three files in real time: `audio.m4a` (mixed, for listening), `mic.m4a` (user's voice only), `system.m4a` (everyone else only). AAC, 48 kHz, favor smaller files.
- Required permissions (requested on first use): Screen/System Audio Recording, Microphone.
- Must be resilient: if one source fails mid-recording, keep recording the other and surface a warning.

### 2. MeetingDetector
- Polls CoreAudio every few seconds for processes currently using the microphone.
- Known meeting apps allowlist: Zoom, Slack, Amazon Chime, Microsoft Teams, FaceTime, WebEx (bundle IDs / process names).
- Meeting start (app begins using mic, not currently recording) → user notification with a **Record** action button. Clicking it starts recording. No auto-record.
- Meeting end (app stops using mic while recording) → notification suggesting stop; optional auto-stop after N seconds (configurable, default off).
- Detection is a suggestion layer only  -  manual record/stop from the menu always works regardless.

### 3. Transcriber
- Runs after recording stops: transcribes `mic.m4a` and `system.m4a` separately with `mlx_whisper` (subprocess, JSON output, automatic language detection  -  user works in ES and EN).
- Whisper model configurable in Settings (default: a good quality/speed tradeoff, e.g. `mlx-community/whisper-large-v3-turbo`).
- **Speaker attribution by track:** mic segments are labeled **Me**, system segments **Them**  -  no ML diarization needed; the physical track split is the ground truth. Segments from both tracks are interleaved by start timestamp.
- Merges into `transcript.md`:
  - Header: date, detected meeting app, duration, model used.
  - Body: turns grouped by speaker and speech pauses, each as `[hh:mm:ss] **Me/Them:** text`.
- Keeps raw segments of both tracks as `transcript.json`.
- **Cleanup pass with Claude:** after whisper finishes, runs the `claude` CLI headless (`claude -p`) over the raw transcript to produce the final `transcript.md`: fixes punctuation and casing, removes filler words and false starts, merges fragments into coherent paragraphs, preserves `[hh:mm:ss]` timestamps, **Me/Them** labels, and both languages (ES/EN) as spoken  -  no summarizing, no content changes. Configurable on/off in Settings (default on). If `claude` is unavailable or fails, fall back to the whisper-only formatted transcript and note it in the file header.
- If transcription fails, audio is already safe on disk; notification offers "Retry transcription". Retry also available from the recording's entry in the menu.

### 4. MenuBarUI
- Menu bar icon states: idle / recording (red indicator) / transcribing (progress indicator).
- Menu contents:
  - Record / Stop (with live elapsed time while recording)
  - Last 5 recordings (click → open folder)
  - Open recordings folder
  - Settings
  - Quit
- Settings (simple window or menu subsection):
  - **Output folder** (default `~/Recordings`, user-changeable via folder picker)
  - Whisper model
  - Auto-stop on meeting end (off / N seconds)
  - Path to `mlx_whisper` binary

## Output layout

```
<output-folder>/2026-07-13_15-30_zoom/
├── audio.m4a          # mixed recording (for listening)
├── mic.m4a            # user's voice track
├── system.m4a         # everyone else's track
├── transcript.md      # formatted transcript with Me/Them attribution
└── transcript.json    # raw whisper segments (both tracks)
```

Folder name: `YYYY-MM-DD_HH-mm_<app>` where `<app>` is the detected meeting app, or `manual` if recording was started by hand with no detection.

## Error handling

| Failure | Behavior |
|---|---|
| Missing permissions | Menu shows warning state; deep-link to System Settings panes |
| mlx_whisper missing/fails | Audio preserved; notification + Retry action |
| One audio source fails mid-recording | Continue with the other; warn user |
| Disk write failure | Stop recording, notify immediately |

## Non-goals (v1)

- ML speaker diarization (distinguishing individual remote speakers within "Them"). Track-based Me/Them attribution is in scope; per-person identification is not.
- Auto-record without confirmation.
- Summary generation, calendar integration, cloud upload.

## Testing

- Unit tests: transcript formatter (JSON → markdown), folder naming, settings persistence.
- Manual verification: record a real Zoom/Slack call end-to-end; verify both sides audible in m4a and present in transcript; verify detection notification fires.
