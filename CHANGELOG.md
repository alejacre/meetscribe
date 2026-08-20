# Changelog

All notable changes to MeetScribe are documented here.

The project follows semantic versioning once public releases begin.

## Unreleased

### Added

- Configurable per-application recording policies: ignore, ask, and automatic
- Custom meeting applications by bundle identifier
- Pluggable transcript agents with Claude Code and generic command adapters
- Git publication with commit, push, retry, and dirty-worktree protection
- SFTP publication through OpenSSH with strict host verification and staged rename
- Versioned recording manifests and restart-safe publication state
- Settings tabs for triggers, agents, and destinations
- Open source contribution, security, support, and architecture documentation

### Changed

- MLX Whisper installs into MeetScribe-managed directories
- CI test execution has an explicit process-tree watchdog
- The production line-coverage gate increases from 25% to 29%
- Recording notifications retain absolute note paths and meeting identity

### Fixed

- Subprocess completion no longer waits indefinitely when a descendant retains an output pipe
