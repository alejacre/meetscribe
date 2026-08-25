# Architecture

MeetScribe is a local-first pipeline. The local recording workspace is created before transcription, agent processing, or publication so external failures never become the only copy of a recording.

## Pipeline

```text
CoreAudio meeting detection / manual action
                    |
                    v
          RecordingCoordinator
                    |
                    v
    RecordingBackgroundWorkController
                    |
                    v
        RecordingSession + manifest
                    |
            AudioRecorder
                    |
   RecordingTranscriptionService
                    |
         TranscriptProcessing
                    |
       local Markdown becomes ready
                    |
        PublicationService
             /             \
 GitRepositoryDestination  SFTPDestination
```

## Boundaries

### Trigger

`MeetingDetector` reports a set of active applications. `MeetingRule` maps a bundle identifier to a display name, stable output label, and `ignore`, `ask`, or `automatic` policy.

Notification actions carry the meeting bundle identifier so simultaneous prompts cannot select the wrong application. Manual and hotkey recordings do not inherit a pending meeting prompt.

### Local Workspace

`RecordingSession` owns note and sidecar paths. `RecordingManifest` gives every recording a stable UUID and persists source, lifecycle, transcript, and destination state. The manifest is written atomically with mode `0600`; its asset directory uses `0700`.

The manifest schema is versioned. Incompatible changes require an explicit migration and schema update.

Topic-based renames write a private move journal before changing either the note
or its asset directory. Library refresh completes or rolls back an interrupted
rename before exposing recordings.

Transcript search uses an actor-isolated incremental index. It refreshes only
Markdown files whose size or modification date changed, removes deleted notes,
and performs matching away from the main actor with cancellation between lines.

### Transcript Agent

`TranscriptProcessing` accepts Markdown and returns processed Markdown plus a
required, bounded topic slug. The built-in Claude Code, Kiro CLI, and custom-command
implementations share validation for structure, turn identity, and bounded
source-token preservation.

Agents run after raw local Markdown is written. Topic renaming completes before
processed Markdown replaces the raw note, so any processing or rename failure
leaves a raw transcript intact.

### Destination

`RecordingDestination` validates and publishes a `RecordingExportPackage`. Packages contain the note, manifest, raw Whisper JSON, and optional audio. `PublicationService` persists attempts and errors, and `RecordingCoordinator` resumes requested incomplete publications after restart.

## Adding an Integration

### Transcript Agent

1. Implement `TranscriptProcessing`.
2. Keep provider authentication outside MeetScribe.
3. Preserve the adapter contract and structural validation.
4. Add configuration, UI, tests, and documentation.

Prefer the generic command adapter when it can express the integration without provider-specific code.

### Destination

1. Implement `RecordingDestination`.
2. Validate configuration before copying data.
3. Avoid shells and interpolate no user input into command text.
4. Make retries idempotent and avoid exposing a partial final result.
5. Return actionable errors and add a local integration test where practical.

## Concurrency

Recording runs on the main actor. `RecordingBackgroundWorkController` owns
deduplication, counters, notifications, and detached transcription/publication
jobs, while `RecordingTranscriptionService` owns the local transformation
pipeline. Manifest reads and writes are serialized; move journals and atomic
manifest writes provide recovery across restarts.

## Trust Model

- The macOS user and selected local output folder are trusted.
- A selected executable, Git repository and its hooks, SSH configuration, and remote server are explicit trust boundaries.
- Meeting applications and transcript contents are untrusted input.
- No destination or transcript agent is enabled by default.
