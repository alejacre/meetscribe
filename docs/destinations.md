# Destinations

Every recording is staged and retained locally before publication. Destinations are disabled by default and operate only after a transcript is ready.

The default export contains:

- Markdown note
- `manifest.json`
- Raw `transcript.json`

Mixed and source audio tracks are separate opt-in.

## Git

Configuration:

- Repository root
- Relative folder inside the repository
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

It then renames that temporary directory to the final recording name. Failed uploads remain outside the final name and can be retried.

Before enabling SFTP, verify the host key outside MeetScribe:

```bash
sftp <host-alias>
```

Do not disable strict host-key checking to make a failed connection pass.

## Recovery

The local manifest records `pending`, `publishing`, `succeeded`, or `failed` for each configured destination, together with attempt count and the last error. Requested incomplete publications resume at application startup. Changing destination configuration produces a new fingerprint and republishes the recording on the next request.
