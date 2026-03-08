# AGENTS.md — Claude Memory Plugin

## Overview

This project builds a Claude Code plugin that provides always-on memory for developer workflows. It automatically records sessions, extracts observations, consolidates memories between sessions, and injects relevant context into new sessions.

The original `../agent.py` serves as the implementation reference — it demonstrates the core memory patterns (ingest, consolidate, query) using Google ADK. This plugin adapts those patterns for the Claude Code hook system.

## Architecture

```
SessionStart hook ──> query.py + inject.py ──> additionalContext (memories)
PostToolUse hook  ──> append to session JSONL (shell, fast)
PreCompact hook   ──> append snapshot to session JSONL
Stop hook         ──> append state to session JSONL
SessionEnd hook   ──> spawn extract.py (background)
                        └──> spawn consolidate.py (background)
```

**Storage**: SQLite at `~/.claude/projects/<project>/claude-memory.db`
**Session logs**: JSONL at `~/.claude/projects/<project>/claude-memory/sessions/<id>.jsonl`
**LLM calls**: Only in extract.py and consolidate.py (background, never in hooks)

## Build & Run

```bash
# Load plugin for development
claude --plugin-dir ./src

# Run setup (creates DB, installs deps)
bash src/scripts/setup.sh

# Run extraction manually
python3 src/scripts/extract.py --session-id <id> --transcript <path>

# Run consolidation manually
python3 src/scripts/consolidate.py

# Query memories
python3 src/scripts/query.py "search term"
```

## Test

```bash
# Unit tests
python3 -m pytest src/tests/ -v

# Lint
python3 -m ruff check src/scripts/

# Plugin validation
claude plugin validate ./src

# Manual integration test
# 1. Start Claude Code with plugin loaded
# 2. Make some edits, run commands
# 3. Exit session
# 4. Start new session — verify memory injection in context
```

## Spec Index

Read these specs in dependency order:

1. **[specs/memory-storage.md](specs/memory-storage.md)** — SQLite schema, storage operations, FTS5 search
2. **[specs/session-recording.md](specs/session-recording.md)** — Hook-based session capture, JSONL logs
3. **[specs/memory-extraction.md](specs/memory-extraction.md)** — Observer pattern, LLM distillation, priority tags
4. **[specs/memory-consolidation.md](specs/memory-consolidation.md)** — Sleep-cycle processing, contradiction resolution
5. **[specs/context-injection.md](specs/context-injection.md)** — SessionStart memory injection, relevance scoring
6. **[specs/plugin-packaging.md](specs/plugin-packaging.md)** — Plugin structure, installation, configuration

## Implementation Reference

The original agent at `../agent.py` contains patterns to adapt:

| agent.py Lines | Pattern | Used In |
|---|---|---|
| 80-108 | SQLite schema (memories, consolidations tables) | storage.py |
| 114-146 | `store_memory()` with JSON fields | storage.py |
| 149-188 | Read/query operations | storage.py, query.py |
| 190-228 | `store_consolidation()` with bidirectional connections | storage.py |
| 319-340 | IngestAgent prompt | extract.py |
| 342-356 | ConsolidateAgent prompt | consolidate.py |
| 527-543 | Consolidation loop with threshold check | consolidate.py |

## File Conventions

- **Hook scripts** (`hooks/*.sh`): POSIX bash, must complete <500ms, JSON stdin/stdout
- **Python scripts** (`scripts/*.py`): Python 3.10+, stdlib + anthropic SDK
- **Tests** (`tests/test_*.py`): pytest, use temp DB fixtures, mock LLM calls
- **All paths**: Use `${CLAUDE_PLUGIN_ROOT}` in hooks, `pathlib.Path` in Python

## Validation Checklist

Before marking a phase complete, verify:

- [ ] All Python scripts import without errors
- [ ] All hook scripts are executable and return valid JSON
- [ ] `storage.py --init` creates the database idempotently
- [ ] `python3 -m pytest src/tests/` passes
- [ ] `claude --plugin-dir ./src` loads without errors
- [ ] Hook response time is <500ms (test with `time echo '{}' | bash hooks/post-tool-use.sh`)
- [ ] Background processes (extract, consolidate) don't block hooks
- [ ] Graceful degradation when DB is missing or locked
