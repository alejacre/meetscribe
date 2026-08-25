# Destinations

Every recording is staged and retained locally before publication. Destinations are disabled by default and operate only after a transcript is ready.

The default export contains only the Markdown note. The recovery manifest, raw
`transcript.json`, and mixed/source audio tracks are separate opt-ins.

## Git

Configuration:

- Repository root
- Relative folder inside the repository
- Include recovery manifest toggle
- Include raw Whisper JSON toggle
- Include audio toggle

Requirements:

- The selected folder must be the repository root.
- The current branch must have an upstream remote.
- Git author name and email must already be configured.
- The worktree must be clean except for files from the same recording retry.

Publication:

1. Materializes files atomically under the configured relative folder.
2. Stages only that recording's paths.
3. Creates a commit when content changed.
4. Pushes the current branch to its upstream.

If a push fails after the local commit, retrying pushes the existing commit instead of creating a duplicate. MeetScribe does not resolve merge conflicts, force-push, switch branches, or modify unrelated changes.

Git hooks belong to the selected repository and can execute as the current user. Select only repositories you trust.

## SFTP over SSH

Configuration:

- SSH host or alias
- Remote folder
- Include audio toggle

MeetScribe invokes:

```text
/usr/bin/sftp -b - -oBatchMode=yes -oStrictHostKeyChecking=yes <host>
```

Authentication, proxying, ports, usernames, identities, and host aliases come from OpenSSH, including `~/.ssh/config` and `SSH_AUTH_SOCK`. MeetScribe does not store passwords or private keys.

Publication uploads a complete package into:

```text
<remote-folder>/.meetscribe-incoming/<upload-id>
```

The upload identifier is stable for a recording. Before each attempt, MeetScribe
removes known files from any previous partial upload at that identifier. It also
attempts the same cleanup when an upload or promotion fails, and reports when
that cleanup cannot be confirmed. A retry therefore reuses and cleans the same
staging location instead of accumulating a new directory for every attempt.

MeetScribe then renames the temporary directory to the final recording name.

When the final directory already exists, MeetScribe first attempts the server's
atomic rename extension. If the server rejects replacement, it moves the
existing directory into the private incoming area, promotes the completed
upload, and removes the known backup files. Backup and promotion are separate
SFTP operations: if either operation has an ambiguous transport failure,
MeetScribe attempts to restore the backup before reporting failure. Backup data
can remain under `.meetscribe-incoming` when the remote state is ambiguous; the
error is surfaced for operator review.

Before enabling SFTP, verify the host key outside MeetScribe:

```bash
sftp <host-alias>
```

Do not disable strict host-key checking to make a failed connection pass.

## Recovery

The local manifest records `pending`, `publishing`, `succeeded`, or `failed` for each configured destination, together with attempt count and the last error. Requested incomplete publications resume at application startup. Changing destination configuration produces a new fingerprint and republishes the recording on the next request.
