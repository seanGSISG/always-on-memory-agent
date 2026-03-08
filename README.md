# claude-memory

Always-on memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Automatically records sessions, extracts structured observations via LLM, consolidates cross-session insights, and injects relevant context when you start a new session — so Claude remembers what you've been working on.

## What It Does

Every Claude Code session generates valuable context — architectural decisions, bug fixes, failed approaches, dependency quirks. Without memory, each session starts from scratch. `claude-memory` fixes that.

### The Memory Loop

```
Session Start ──► Inject relevant memories into context
       │
  Work happens (tool calls, edits, searches recorded)
       │
  Session End ──► Extract observations via LLM (background)
       │
  Consolidate ──► Find cross-session patterns, resolve contradictions (background)
       │
  Next Session ──► Inject again, now with richer context
```

### What Gets Remembered

Observations are extracted with priority levels:

| Priority | Category | Examples |
|----------|----------|----------|
| **P1** | Critical | Architectural decisions with rationale, security-sensitive patterns |
| **P2** | Important | Bug fixes with root causes, dependency quirks and workarounds |
| **P3** | Useful | Code patterns/conventions, file relationships, test strategies |
| **P4** | Minor | Failed approaches, dead ends, environment setup details |

Each observation includes entities (files, functions, packages), topic tags, and an importance score that decays over time — so stale memories fade naturally while critical decisions persist.

## Architecture

```
claude-memory-plugin/src/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest (v0.2.0)
├── hooks/
│   ├── hooks.json               # Hook event registrations
│   ├── lib.sh                   # Shared shell functions (venv resolution)
│   ├── session-start.sh         # Register session + inject memories
│   ├── session-end.sh           # Finalize session + spawn extraction
│   ├── post-tool-use.sh         # Record tool calls to session log
│   ├── pre-tool-use.sh          # Advisory memory warnings (PreToolUse)
│   ├── pre-compact.sh           # Log context compaction events
│   └── stop.sh                  # Log session stop events
├── scripts/
│   ├── storage.py               # SQLite layer (FTS5, WAL mode)
│   ├── extract.py               # LLM-powered observation extraction
│   ├── consolidate.py           # Cross-session pattern synthesis
│   ├── query.py                 # Relevance-scored memory search
│   ├── inject.py                # Context injection formatter
│   ├── status.py                # Database statistics
│   ├── forget.py                # Soft/hard observation deletion
│   ├── gate_check.py            # Danger pattern matching for PreToolUse
│   ├── llm_provider.py          # Multi-provider LLM abstraction
│   └── setup.sh                 # Plugin setup (venv, deps, DB init)
├── skills/
│   ├── memory-query/            # /memory-query — search memories
│   ├── memory-status/           # /memory-status — DB health stats
│   ├── memory-consolidate/      # /memory-consolidate — manual consolidation
│   └── memory-forget/           # /memory-forget — remove observations
└── tests/                       # 55 tests (pytest)
```

### How Each Hook Works

| Event | Hook | What Happens |
|-------|------|-------------|
| **SessionStart** | `session-start.sh` | Registers session in SQLite, queries memory DB, injects relevant observations as markdown into Claude's context |
| **PostToolUse** | `post-tool-use.sh` | Appends a JSONL event to the session log (tool name, file paths, input summary) |
| **PreToolUse** | `pre-tool-use.sh` | Checks Bash commands for danger patterns (`git push`, `rm -rf`, etc.) and searches memory for relevant warnings about files being edited. Advisory only — never blocks |
| **SessionEnd** | `session-end.sh` | Finalizes session, spawns background extraction process that reads the transcript, calls an LLM to distill observations, and stores them in SQLite |
| **PreCompact** | `pre-compact.sh` | Logs context compaction event to session log |
| **Stop** | `stop.sh` | Logs session stop event |

### Storage

SQLite with WAL mode and FTS5 full-text search. Three tables:

- **observations** — Individual facts extracted from sessions (content, entities, topics, priority, importance, timestamps)
- **consolidations** — Synthesized insights from cross-session analysis (summary, insight, connections, source observation IDs)
- **sessions** — Session metadata (branch, working directory, timestamps)

The database lives at `$CLAUDE_PROJECT_DIR/claude-memory.db` (or a hash-based path under `~/.claude/projects/`).

### Memory Lifecycle

1. **Extraction** — After each session, observations are extracted and stored with initial importance scores
2. **Decay** — Importance scores decay exponentially (14-day half-life; P1 observations use 28-day half-life)
3. **Consolidation** — When >= 3 unconsolidated observations exist, an LLM finds patterns, connections, and contradictions across sessions
4. **Pruning** — Observations older than 30 days with importance below 0.3 are automatically removed

## Setup

### Prerequisites

- Python 3.10+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- An LLM API key (Google, Anthropic, or OpenAI) — or use Claude Code's built-in `claude -p` mode (no extra key needed)

### Install from GitHub

```bash
# Install as a Claude Code plugin
/plugin install https://github.com/seanGSISG/always-on-memory-agent --subdir claude-memory-plugin/src
```

### Install from local directory (development)

```bash
# Clone the repo
git clone https://github.com/seanGSISG/always-on-memory-agent.git
cd always-on-memory-agent

# Create venv and install dependencies
cd claude-memory-plugin
uv venv .venv
source .venv/bin/activate
uv pip install -r src/requirements.txt

# Run with plugin directory
claude --plugin-dir ./src
```

### Configure the LLM Provider

The plugin needs an LLM to extract observations and run consolidation. Set one of these:

```bash
# Option 1: Google Gemini (default, cheapest)
export GOOGLE_API_KEY="your-key"

# Option 2: Anthropic
export CLAUDE_MEMORY_PROVIDER="anthropic"
export ANTHROPIC_API_KEY="your-key"

# Option 3: OpenAI
export CLAUDE_MEMORY_PROVIDER="openai"
export OPENAI_API_KEY="your-key"

# Option 4: Claude Code pipe mode (no extra key needed, uses your Claude subscription)
export CLAUDE_MEMORY_PROVIDER="claude"

# Option 5: Local OpenAI-compatible endpoint
export CLAUDE_MEMORY_PROVIDER="local"
export CLAUDE_MEMORY_LOCAL_URL="http://localhost:8080"
```

Or create a config file at `~/.config/claude-memory/config.json`:

```json
{
  "provider": "google",
  "model": "gemini-3.1-flash-lite-preview",
  "fallback_to_claude": true
}
```

When `fallback_to_claude` is `true` (default), the plugin automatically falls back to `claude -p` if no API key is found.

## Usage

### Automatic (zero effort)

Once installed, memory works automatically:

- **Session start**: Relevant memories appear as injected context (markdown heading "Project Memory")
- **During session**: Tool calls are logged silently in the background
- **Session end**: Observations are extracted and stored (background, ~5-10 seconds)
- **Periodically**: Cross-session consolidation runs to synthesize insights

### Slash Commands

| Command | Description |
|---------|-------------|
| `/memory-query <topic>` | Search memories for a topic, file, or concept |
| `/memory-status` | Show database statistics — observation counts, priority distribution, DB size |
| `/memory-consolidate` | Manually trigger consolidation (with optional dry-run preview) |
| `/memory-forget <query>` | Find and remove observations (soft or hard delete, with preview and confirmation) |

### CLI Scripts

```bash
# Search memories
python3 scripts/query.py "authentication"

# Database health check
python3 scripts/status.py

# Run consolidation manually
python3 scripts/consolidate.py

# Preview what would be consolidated
python3 scripts/consolidate.py --dry-run

# Run consolidation in foreground with result output
python3 scripts/consolidate.py --foreground

# Run continuous consolidation (every 30 minutes)
python3 scripts/consolidate.py --continuous 30

# Preview observations to forget
python3 scripts/forget.py --query "outdated pattern" --preview

# Soft-forget (reduces importance, pruned next cycle)
python3 scripts/forget.py --query "outdated pattern" --mode soft --confirm

# Hard-forget (immediate deletion)
python3 scripts/forget.py --query "outdated pattern" --mode hard --confirm

# Initialize database
python3 scripts/storage.py --init
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MEMORY_PROVIDER` | `google` | LLM provider: `google`, `anthropic`, `openai`, `local`, `claude` |
| `CLAUDE_MEMORY_MODEL` | Provider-specific | Model for extraction/consolidation |
| `CLAUDE_MEMORY_API_KEY` | Falls back to provider key | Universal API key override |
| `CLAUDE_MEMORY_LOCAL_URL` | `http://localhost:8080` | Base URL for local OpenAI-compatible endpoint |
| `CLAUDE_MEMORY_MAX_INJECT_TOKENS` | `4096` | Max tokens to inject at session start |
| `CLAUDE_MEMORY_RETENTION_DAYS` | `30` | Auto-prune memories older than this |
| `CLAUDE_MEMORY_DB_PATH` | Auto-derived | Override database file location |

### Default Models

| Provider | Default Model |
|----------|--------------|
| Google | `gemini-3.1-flash-lite-preview` |
| Anthropic | `claude-haiku-4-5-20251001` |
| OpenAI | `gpt-4o-mini` |
| Claude | `haiku` (via `claude -p`) |

## How Relevance Scoring Works

When memories are injected at session start or queried with `/memory-query`, results are ranked by a composite score:

| Component | Weight | Calculation |
|-----------|--------|-------------|
| Recency | 30% | Linear decay over 30 days |
| Priority | 30% | P1=1.0, P2=0.7, P3=0.4, P4=0.2 |
| Importance | 20% | Stored importance value (decays with half-life) |
| Topic Match | 20% | Overlap between observation topics and current git context |

Consolidation insights are boosted with P1 priority and 0.8 importance for consistent high ranking.

## Injected Context Format

At session start, memories are organized into sections:

```markdown
# Project Memory (auto-injected)

## Key Insights
- Cross-session patterns synthesized by consolidation

## Known Issues
- P1/P2 observations about bugs, errors, failures

## Recent Decisions
- P1/P2 architectural decisions and rationale

## Patterns
- P3 code conventions, file relationships

## Context
- P4 environment details, failed approaches

---
*12 memories from 5 sessions | Query: /memory-query <topic>*
```

## Tests

```bash
cd claude-memory-plugin
source .venv/bin/activate
python3 -m pytest src/tests/ -v
```

55 tests covering storage, extraction, injection, consolidation, and integration.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| No memories injected at session start | Complete at least one session first — extraction runs after `SessionEnd` |
| Extraction not running | Check that your LLM API key is set, or set `CLAUDE_MEMORY_PROVIDER=claude` to use pipe mode |
| "Another extraction/consolidation is running" | A lock file exists from a previous run — it auto-expires after 10 minutes |
| Database locked errors | SQLite WAL mode handles most concurrency, but rapid back-to-back sessions may conflict briefly |
| Slow session start | Injection is designed to be fast (<500ms), but a very large DB may slow queries — run `/memory-consolidate` to synthesize and prune |

## License

MIT
