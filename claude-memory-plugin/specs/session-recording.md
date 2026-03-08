# Session Recording

## Job To Be Done

Automatically capture all useful activity from Claude Code sessions via hooks, without developer intervention or perceptible latency.

## Mechanism

Claude Code hooks fire on session events. Shell scripts receive JSON on stdin and respond on stdout. Heavy work is dispatched to background processes to stay under the 500ms UX budget.

### Hooks Used

| Hook Event | Script | Purpose |
|---|---|---|
| `SessionStart` | `session-start.sh` | Register session in DB, inject memories (see context-injection spec) |
| `PostToolUse` | `post-tool-use.sh` | Record tool calls and outcomes |
| `PreCompact` | `pre-compact.sh` | Snapshot context before compaction |
| `Stop` | `stop.sh` | Capture session state at stop point |
| `SessionEnd` | `session-end.sh` | Finalize session, trigger extraction + consolidation |

### hooks.json

```json
{
  "hooks": [
    {
      "event": "SessionStart",
      "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
      "timeout": 5000
    },
    {
      "event": "PostToolUse",
      "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use.sh",
      "matcher": {
        "tool_name": ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
      },
      "timeout": 2000
    },
    {
      "event": "PreCompact",
      "command": "${CLAUDE_PLUGIN_ROOT}/hooks/pre-compact.sh",
      "timeout": 5000
    },
    {
      "event": "Stop",
      "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh",
      "timeout": 5000
    },
    {
      "event": "SessionEnd",
      "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-end.sh",
      "timeout": 10000
    }
  ]
}
```

## Hook I/O Contract

### Input (JSON on stdin)

```json
{
  "session_id": "abc-123",
  "transcript_path": "~/.claude/projects/HASH/abc-123.jsonl",
  "tool_name": "Edit",
  "tool_input": { "file_path": "/src/main.py", "old_string": "...", "new_string": "..." }
}
```

Fields vary by hook event:
- `SessionStart`: `session_id`, `transcript_path`
- `PostToolUse`: `session_id`, `transcript_path`, `tool_name`, `tool_input`
- `PreCompact`: `session_id`, `transcript_path`
- `Stop`: `session_id`, `transcript_path`
- `SessionEnd`: `session_id`, `transcript_path`

### Output (JSON on stdout)

```json
{
  "decision": "approve",
  "reason": "event recorded"
}
```

For `SessionStart`, also include `additionalContext` (see context-injection spec).

## Per-Session Event Log

Each session writes events to a JSONL file at:
`~/.claude/projects/<project>/claude-memory/sessions/<session_id>.jsonl`

### Event Format

```json
{
  "timestamp": "2026-03-06T10:30:00Z",
  "event_type": "tool_use",
  "tool_name": "Edit",
  "tool_input_summary": "Edit /src/main.py: replaced foo() with bar()",
  "files_touched": ["/src/main.py"]
}
```

```json
{
  "timestamp": "2026-03-06T10:35:00Z",
  "event_type": "pre_compact",
  "context_summary": "Working on refactoring auth module"
}
```

```json
{
  "timestamp": "2026-03-06T11:00:00Z",
  "event_type": "session_end",
  "duration_minutes": 30,
  "files_touched_count": 5
}
```

### PostToolUse Recording Logic

The `post-tool-use.sh` hook:
1. Reads JSON from stdin
2. Extracts tool name, input summary, and file paths
3. Appends a JSONL event line to the session log (background `>>` append)
4. Responds with `{"decision": "approve"}` immediately

Tool input summarization (keep it short):
- `Edit`: `"Edit {file_path}: {old_string[:50]} -> {new_string[:50]}"`
- `Write`: `"Write {file_path} ({line_count} lines)"`
- `Bash`: `"Bash: {command[:100]}"`
- `Read`: `"Read {file_path}"`
- `Grep`/`Glob`: `"Search: {pattern}"`

## Constraints

- All hooks must respond in <500ms (user-facing latency)
- Background writes use append-only JSONL (no read-modify-write)
- Hook scripts must work on Linux and macOS bash
- No Python dependency in hot-path hooks (shell only for speed)
- Session log directory created on first write if missing
- `SessionEnd` hook may take longer (up to 10s) since it's not blocking UX — it spawns extraction as a background process

## Acceptance Criteria

1. `post-tool-use.sh` completes in <500ms and appends a valid JSONL line to the session log
2. `session-start.sh` registers the session in the SQLite DB via a quick Python call
3. `session-end.sh` spawns extraction as a background process (nohup/disown) and returns immediately
4. `pre-compact.sh` appends a context snapshot event to the session log
5. Session JSONL files are created per-session and contain all recorded events
6. Hooks degrade gracefully if the session log directory is missing (create it)
7. All hook scripts are POSIX-compatible and work without Python in the critical path

## References

- PLAN.md "Hook I/O Format" section for hook contract details
- PLAN.md "Hook System" section for available events
- specs/memory-storage.md for `store_session()` / `end_session()` functions
- specs/memory-extraction.md for extraction triggered by SessionEnd
- specs/context-injection.md for SessionStart memory injection
