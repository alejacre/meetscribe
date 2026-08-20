# Recording Manifest

Each recording sidecar contains `manifest.json`. It is the local source of truth for identity, recovery, and publication status.

The current `schemaVersion` is `1`. The machine-readable definition is [recording-manifest.schema.json](recording-manifest.schema.json).

## Lifecycle

```text
recording -> recorded -> transcribing -> ready
     \            \            \
                    failed
```

- `recording`: capture started.
- `recorded`: capture and mix completed.
- `transcribing`: local Whisper work is running.
- `ready`: the local Markdown note is complete.
- `failed`: capture, mix, or transcription needs attention.

## Publication

`publicationRequestedAt` distinguishes recordings that should resume from recordings that have never been published. Each destination stores:

- Stable destination identifier
- Configuration fingerprint
- `pending`, `publishing`, `succeeded`, or `failed`
- Attempt count
- Last error and success timestamp when present

The local manifest is authoritative. Copies included in destinations represent the state at the time that package was materialized.

## Compatibility

Readers must reject unsupported future schema versions before interpreting them. A change that removes, renames, or changes the meaning of a field requires:

1. A schema version increment.
2. A migration for existing local manifests.
3. Fixtures for the previous and new versions.
4. Updated documentation and JSON Schema.
