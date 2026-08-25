# Transcript Agent Adapters

MeetScribe supports built-in Claude Code and Kiro CLI adapters, plus a
provider-neutral custom command.

## Custom Command Contract

The configured executable:

1. Receives the complete raw MeetScribe Markdown transcript on stdin.
2. Receives configured arguments directly through `Process`; no shell is used.
3. Receives the configured prompt in the argument containing `{prompt}`. If no argument contains the placeholder, the prompt is appended as the final argument.
4. Writes the processed Markdown to stdout.
5. Exits with status `0` on success.

The executable path must be absolute and executable.

By default, the process receives only `HOME`, `PATH`, `TMPDIR`, `LANG`, and `USER`. Full environment inheritance is an explicit setting because environment variables can contain credentials.

## Output

The required first line is:

```markdown
<!-- topic: lowercase-topic-slug -->
```

It is removed before the note is saved and renames the note. Output without a valid topic
is rejected, leaving the raw transcript under its provisional application-based name and
showing a processing warning. The remaining output must:

- Preserve YAML frontmatter exactly
- Add `## Summary` before `## Transcript`
- Preserve the trailing `<!-- meetscribe: ... -->` metadata comment exactly
- Preserve every timestamp and `**Me:**` / `**Them:**` turn marker in order
- Preserve recognizable source words in every non-empty turn and at least half
  of the transcript tokens overall
- Avoid expanding the transcript body beyond the bounded validation allowance

Example:

```markdown
<!-- topic: project-review -->
---
date: 2026-08-20
attendees: []
tags: [meeting, transcript]
---

## Summary
The team reviewed the project.

## Transcript
[00:00:03] **Me:** Welcome.

<!-- meetscribe: app=zoom, duration=00:10:00, model=example, cleaned=false, processor=none -->
```

Topic slugs are limited to three words and 64 UTF-8 bytes. MeetScribe rejects
structurally unsafe or excessively rewritten output and keeps the raw local
transcript.

## Example Adapter

This minimal executable forwards stdin to an agent CLI that accepts a prompt argument:

```bash
#!/bin/sh
exec /absolute/path/to/agent --prompt "$1"
```

Configure its arguments as:

```text
{prompt}
```

Use an absolute executable path and avoid wrapper scripts when the target CLI can already read stdin. Wrapper scripts execute with the current user's permissions and are part of the trusted computing base.

## Built-in Claude Code Adapter

The Claude Code adapter invokes the local CLI in print mode with:

- The `haiku` model alias
- Tools disabled
- Strict empty MCP configuration
- Session persistence disabled
- Restricted environment variables

Authentication and service selection remain owned by the user's Claude Code installation. Enabling the adapter sends the complete transcript to that configured service.

## Built-in Kiro CLI Adapter

The Kiro adapter invokes the local CLI in non-interactive mode with:

- A temporary workspace-scoped agent
- No tools or MCP servers in that agent
- Restricted environment variables
- Output framing and ANSI control sequences removed before validation
- The temporary local Kiro session deleted after each attempt

Kiro CLI does not consume the transcript from stdin, so MeetScribe includes it
in the initial non-interactive request. Very large transcripts are therefore
subject to the operating system's command-argument size limit. Authentication
and model selection remain owned by the user's Kiro installation.

As with every adapter, MeetScribe rejects incomplete or structurally unsafe
output and retains the raw local transcript.
