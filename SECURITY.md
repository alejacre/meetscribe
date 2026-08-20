# Security Policy

## Supported Versions

Security fixes are applied to the latest release and the default branch. Older releases may not receive patches.

## Reporting a Vulnerability

Do not open a public issue for a vulnerability involving transcript disclosure, recording access, command execution, credentials, path traversal, SSH behavior, or permission bypass.

Use GitHub's private vulnerability reporting for this repository when available. If it is unavailable, contact the maintainer through their GitHub profile with a request for a private reporting channel and do not include exploit details in the initial public message.

Include:

- Affected version or commit
- Reproduction steps
- Expected and observed impact
- Whether real transcripts, audio, credentials, or remote systems were involved
- A suggested fix, if known

The maintainer will acknowledge a complete report when it is reviewed, coordinate a fix, and credit the reporter unless anonymity is requested.

## Security Boundaries

- Local recordings and manifests use owner-only filesystem permissions.
- Agent and destination features are opt-in.
- Custom agents execute as the current macOS user and should be treated as trusted local software.
- SFTP authentication is delegated to OpenSSH; MeetScribe does not store private keys or passwords.
- A selected Git repository and its configured hooks are trusted code execution boundaries.
