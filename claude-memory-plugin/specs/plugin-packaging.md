# Plugin Packaging

## Job To Be Done

Package the always-on memory system as a Claude Code plugin that installs with one command, requires zero configuration, and works immediately.

## Directory Structure

```
claude-memory-plugin/src/
  .claude-plugin/
    plugin.json                  # Plugin manifest
  hooks/
    hooks.json                   # Hook event registrations
    session-start.sh             # Inject memories (SessionStart)
    post-tool-use.sh             # Record tool events (PostToolUse)
    pre-compact.sh               # Snapshot before compaction (PreCompact)
    stop.sh                      # Capture state at stop (Stop)
    session-end.sh               # Trigger extraction + consolidation (SessionEnd)
  scripts/
    storage.py                   # SQLite storage layer
    extract.py                   # Session -> observations (LLM)
    consolidate.py               # Observations -> insights (LLM)
    query.py                     # Query memories for injection
    inject.py                    # Format memories for context injection
    llm_provider.py              # Multi-provider LLM abstraction
    setup.sh                     # First-run setup (create dirs, validate deps)
  skills/
    memory-query/
      SKILL.md                   # /memory-query slash command
  tests/
    test_storage.py              # Storage layer unit tests
    test_extract.py              # Extraction tests (with mock LLM)
    test_consolidate.py          # Consolidation tests (with mock LLM)
    test_inject.py               # Injection formatting tests
    conftest.py                  # Shared fixtures (temp DB, mock provider)
  README.md
  LICENSE
  requirements.txt               # Python dependencies (minimal)
```

## plugin.json

```json
{
  "name": "claude-memory",
  "version": "0.1.0",
  "description": "Always-on memory for Claude Code — automatically records sessions, extracts observations, consolidates insights, and injects relevant context.",
  "author": "always-on-memory-agent",
  "hooks": "./hooks/hooks.json",
  "skills": ["./skills/memory-query"],
  "setup": "./scripts/setup.sh"
}
```

## Hook Scripts

Each hook script follows this pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT=$(cat)  # Read JSON from stdin

# Extract fields
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))")

# Do work (fast path or background dispatch)
# ...

# Respond
echo '{"decision": "approve", "reason": "recorded"}'
```

For `session-end.sh` (background dispatch):
```bash
#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))")
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))")

# Spawn extraction in background
nohup python3 "$PLUGIN_ROOT/scripts/extract.py" \
  --session-id "$SESSION_ID" \
  --transcript "$TRANSCRIPT" \
  > /dev/null 2>&1 &

echo '{"decision": "approve", "reason": "extraction triggered"}'
```

## setup.sh (First-Run)

```bash
#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Setting up claude-memory plugin..."

# 1. Validate Python 3.10+
python3 -c "import sys; assert sys.version_info >= (3, 10), f'Python 3.10+ required, got {sys.version}'" || {
  echo "ERROR: Python 3.10+ is required"
  exit 1
}

# 2. Install Python dependencies
pip3 install --quiet -r "$PLUGIN_ROOT/requirements.txt" 2>/dev/null || \
  pip3 install --quiet --user -r "$PLUGIN_ROOT/requirements.txt"

# 3. Create memory directories
MEMORY_DIR="${CLAUDE_PROJECT_DIR:-$HOME/.claude/projects/default}/claude-memory"
mkdir -p "$MEMORY_DIR/sessions"

# 4. Initialize database
python3 "$PLUGIN_ROOT/scripts/storage.py" --init

echo "claude-memory plugin ready."
```

## requirements.txt

```
google-adk>=1.0.0
google-genai>=1.0.0
anthropic>=0.40.0
openai>=1.0.0
```

Note: `google-adk` and `google-genai` are the primary dependencies (default provider). The others are optional for alternative providers. The LLM provider module handles import errors gracefully.

## /memory-query Skill

`skills/memory-query/SKILL.md`:

```markdown
---
name: memory-query
description: Query your project memory for observations, insights, and session history
arguments:
  - name: query
    description: What to search for in memory (topic, file, concept)
    required: true
---

Search the project memory database for relevant observations and insights.

1. Run the query script:
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/query.py "{{query}}"
   ```

2. Present the results organized by relevance, showing:
   - Matching observations with their priority and age
   - Related consolidation insights
   - Connected observations

3. If no results found, suggest broader search terms.
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_MEMORY_PROVIDER` | `google` | LLM provider: `google`, `anthropic`, `openai`, `local` |
| `CLAUDE_MEMORY_MODEL` | `gemini-3.1-flash-lite-preview` | Model name for extraction/consolidation |
| `CLAUDE_MEMORY_API_KEY` | Falls back to `GOOGLE_API_KEY` / provider-specific key | API key for the LLM provider |
| `CLAUDE_MEMORY_LOCAL_URL` | `http://localhost:8080` | Base URL for local OpenAI-compatible endpoint |
| `CLAUDE_MEMORY_MAX_INJECT_TOKENS` | `4096` | Max tokens to inject at session start |
| `CLAUDE_MEMORY_RETENTION_DAYS` | `30` | Auto-prune observations older than this |
| `CLAUDE_MEMORY_DB_PATH` | Auto-detected | Override database path |
| `CLAUDE_PROJECT_DIR` | Auto-detected | Claude Code project directory |

## Installation Methods

### From plugin directory (development)
```bash
claude --plugin-dir /path/to/claude-memory-plugin/src
```

### From git repository
```bash
claude plugin install https://github.com/user/always-on-memory-agent --subdir claude-memory-plugin/src
```

## Cross-Platform Requirements

- Shell hooks: POSIX-compatible bash (Linux, macOS, Git Bash on Windows)
- Python scripts: Python 3.10+ (no platform-specific code)
- SQLite: Built into Python stdlib (no external binary needed)
- File paths: Use `pathlib.Path` in Python, `$HOME` in shell
- Background processes: `nohup ... &` (works on all POSIX systems)
- No Windows-specific `.bat` or `.ps1` files needed (Claude Code runs in WSL on Windows)

## Constraints

- Zero mandatory configuration (works with defaults + existing `GOOGLE_API_KEY`)
- First-run setup must be idempotent (safe to run multiple times)
- Plugin must not modify any files outside its own directory and `~/.claude/projects/`
- All Python imports must handle missing optional packages gracefully
- Hook scripts must be executable (`chmod +x`)
- No Node.js dependency (Python + bash only)

## Acceptance Criteria

1. `claude --plugin-dir ./src` loads the plugin without errors
2. `setup.sh` creates the database and validates dependencies idempotently
3. All hook scripts are executable and respond with valid JSON
4. `/memory-query` skill is available and returns formatted results
5. Plugin works with only `GOOGLE_API_KEY` set (no other config needed)
6. Plugin works on both Linux and macOS without modification
7. `requirements.txt` lists all Python dependencies with version constraints

## References

- specs/memory-storage.md — `storage.py` schema and operations
- specs/session-recording.md — Hook scripts and hooks.json
- specs/memory-extraction.md — `extract.py` and `llm_provider.py`
- specs/memory-consolidation.md — `consolidate.py`
- specs/context-injection.md — `inject.py` and `query.py`
- PLAN.md "Plugin Packaging" section for full structure
