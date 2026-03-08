# claude-memory

Always-on memory for Claude Code. Automatically records sessions, extracts observations, consolidates insights, and injects relevant context into new sessions.

## Installation

### From plugin directory (development)
```bash
claude --plugin-dir /path/to/claude-memory-plugin/src
```

### From git repository
```bash
claude plugin install https://github.com/user/always-on-memory-agent --subdir claude-memory-plugin/src
```

## How It Works

1. **Session Recording** - Hooks capture tool calls and session activity into JSONL logs
2. **Extraction** - After each session, an LLM distills raw activity into structured observations (architectural decisions, bug fixes, patterns, etc.)
3. **Consolidation** - Between sessions, a background process finds cross-session patterns, resolves contradictions, and manages memory lifecycle
4. **Injection** - At session start, relevant memories are automatically injected into Claude's context

## Configuration

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_MEMORY_PROVIDER` | `google` | LLM provider: `google`, `anthropic`, `openai`, `local` |
| `CLAUDE_MEMORY_MODEL` | `gemini-2.0-flash-lite` | Model for extraction/consolidation |
| `CLAUDE_MEMORY_API_KEY` | Falls back to provider-specific key | API key for the LLM provider |
| `CLAUDE_MEMORY_LOCAL_URL` | `http://localhost:8080` | Base URL for local endpoint |
| `CLAUDE_MEMORY_MAX_INJECT_TOKENS` | `4096` | Max tokens to inject at session start |
| `CLAUDE_MEMORY_RETENTION_DAYS` | `30` | Auto-prune memories older than this |

## Manual Commands

```bash
# Query memories
python3 src/scripts/query.py "authentication"

# Run consolidation manually
python3 src/scripts/consolidate.py

# Run continuous consolidation (every 30 min)
python3 src/scripts/consolidate.py --continuous 30

# Initialize database
python3 src/scripts/storage.py --init
```

## Slash Command

Use `/memory-query <topic>` in Claude Code to search your project's memory.

## Troubleshooting

- **No memories injected**: Check that at least one previous session was recorded and extracted
- **Extraction not running**: Verify `GOOGLE_API_KEY` (or your provider's key) is set
- **Slow session start**: Injection is capped at 500ms; if DB is large, consider pruning

## License

MIT
