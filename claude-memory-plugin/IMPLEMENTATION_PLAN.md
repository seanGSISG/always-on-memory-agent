# Implementation Plan: claude-memory Plugin

## Overview

Build a Claude Code plugin that provides always-on memory for developer workflows. The plugin automatically records sessions via hooks, extracts observations using an LLM observer pattern, consolidates memories between sessions, and injects relevant context into new sessions.

**Reference**: `../agent.py` (always-on memory agent using Google ADK)
**Target**: Claude Code plugin at `src/` with hooks, Python scripts, and a `/memory-query` skill

---

## Phase 1: Storage Foundation

**Goal**: Build the SQLite storage layer that all other components depend on.

### Files to Create

| File | Purpose |
|------|---------|
| `src/scripts/storage.py` | SQLite storage module with all CRUD operations |
| `src/tests/conftest.py` | Shared pytest fixtures (temp DB, helpers) |
| `src/tests/test_storage.py` | Unit tests for all storage operations |

### Spec References

- `specs/memory-storage.md` — Full schema, all function signatures, FTS5 setup
- `agent.py:80-108` — SQLite schema pattern (memories, consolidations tables)
- `agent.py:114-146` — `store_memory()` with JSON entity/topic storage
- `agent.py:190-228` — `store_consolidation()` with bidirectional connection updates

### Implementation Details

1. **`storage.py`** — Single module exposing all storage operations:
   - `init_db(db_path)` — Create tables (observations, consolidations, sessions, FTS5), enable WAL mode, set busy_timeout=5000. Must be idempotent.
   - `store_observation(session_id, content, entities, topics, priority, importance, source_file)` — Insert observation, return ID. Enforce max 2000 char content.
   - `get_observations(limit, unconsolidated_only, session_id, min_priority)` — Query with filters, return list of dicts with parsed JSON fields.
   - `search_observations(query, limit)` — FTS5 search on content, ranked by relevance.
   - `store_consolidation(source_ids, summary, insight, connections)` — Insert consolidation, mark source observations as consolidated, update bidirectional connections (pattern from `agent.py:213-222`).
   - `get_consolidations(limit)` — Return recent consolidation records.
   - `store_session(session_id, branch, working_dir)` / `end_session(session_id, summary)` — Session lifecycle.
   - `decay_importance(half_life_days)` — Exponential decay: `importance *= 0.5 ^ (age_days / half_life)`. P1 observations use `half_life * 2`.
   - `prune_old(retention_days, min_importance)` — Remove expired low-importance observations.
   - `get_db_path()` — Derive path from `CLAUDE_MEMORY_DB_PATH` env var, or `CLAUDE_PROJECT_DIR`, or fallback.
   - CLI entry point: `python storage.py --init` to initialize DB from shell.

2. **`conftest.py`** — Fixtures:
   - `tmp_db` — Creates a temp SQLite DB, yields connection, cleans up.
   - `populated_db` — Temp DB pre-loaded with sample observations and sessions.

3. **`test_storage.py`** — Tests:
   - `test_init_db_idempotent` — Call `init_db()` twice, no errors.
   - `test_store_and_get_observation` — Store, retrieve, verify all fields including parsed JSON.
   - `test_search_observations_fts` — Store several, search by keyword, verify ranking.
   - `test_store_consolidation_marks_consolidated` — Verify source observations get `consolidated=1`.
   - `test_store_consolidation_bidirectional_connections` — Verify both sides get connection entries.
   - `test_session_lifecycle` — `store_session` then `end_session`, verify fields.
   - `test_decay_importance` — Insert observations with old timestamps, run decay, verify scores decreased.
   - `test_prune_old` — Insert old low-importance observations, prune, verify deleted. Recent ones preserved.
   - `test_concurrent_wal` — Two connections, one writing while other reads (WAL mode).

### Acceptance Criteria

- [x] `python storage.py --init` creates the database idempotently
- [x] All 9+ unit tests pass (14 passed)
- [x] FTS5 search returns relevant results
- [x] Bidirectional connections work per `agent.py:213-222` pattern
- [x] WAL mode enables concurrent read/write without corruption
- [x] JSON fields (entities, topics, connections) round-trip correctly

### Estimated Complexity

Medium. ~300 lines of storage.py + ~200 lines of tests. Pure Python stdlib (sqlite3, json, pathlib). No external dependencies.

---

## Phase 2: Session Recording Hooks

**Goal**: Build the shell hook scripts that capture session activity into JSONL event logs.

### Files to Create

| File | Purpose |
|------|---------|
| `src/hooks/hooks.json` | Hook event registrations |
| `src/hooks/post-tool-use.sh` | Record tool calls to session JSONL |
| `src/hooks/pre-compact.sh` | Snapshot context before compaction |
| `src/hooks/stop.sh` | Capture state at stop point |
| `src/hooks/session-start.sh` | Register session (injection added in Phase 4) |
| `src/hooks/session-end.sh` | Finalize session (extraction added in Phase 3) |
| `src/hooks/lib.sh` | Shared shell functions (JSON parsing, path helpers) |

### Spec References

- `specs/session-recording.md` — Hook I/O contract, event format, JSONL structure
- `specs/plugin-packaging.md` — Hook script patterns, `${CLAUDE_PLUGIN_ROOT}` usage

### Implementation Details

1. **`hooks.json`** — Register all 5 hook events with appropriate timeouts and matchers:
   - `SessionStart`: 5000ms timeout
   - `PostToolUse`: 2000ms timeout, matcher for `Read|Write|Edit|Bash|Grep|Glob`
   - `PreCompact`: 5000ms timeout
   - `Stop`: 5000ms timeout
   - `SessionEnd`: 10000ms timeout

2. **`lib.sh`** — Shared utilities:
   - `get_memory_dir()` — Resolve `~/.claude/projects/<project>/claude-memory/`
   - `get_session_log()` — Return path to `sessions/<session_id>.jsonl`
   - `ensure_dir()` — Create session log directory if missing
   - `extract_json_field()` — Extract a field from JSON stdin using Python one-liner (fast)
   - `respond_approve()` — Echo `{"decision": "approve", "reason": "..."}`

3. **`post-tool-use.sh`** — Critical path, must be <500ms:
   - Read JSON from stdin
   - Extract `session_id`, `tool_name`, `tool_input`
   - Summarize tool input (Edit: file + snippet; Write: file + line count; Bash: command; Read: file; Grep/Glob: pattern)
   - Extract `files_touched` from tool_input
   - Append JSONL event line to session log (background `>>` append)
   - Respond immediately with `{"decision": "approve"}`

4. **`pre-compact.sh`** — Append a `pre_compact` event with context summary.

5. **`stop.sh`** — Append a `stop` event with session state.

6. **`session-start.sh`** — Phase 2 version:
   - Register session in SQLite via quick Python call: `python3 -c "from storage import ...; store_session(...)"`
   - Respond with `{"decision": "approve"}` (injection added in Phase 4)

7. **`session-end.sh`** — Phase 2 version:
   - Append a `session_end` event to the session JSONL
   - Call `end_session()` via Python one-liner
   - Respond with `{"decision": "approve"}` (extraction spawn added in Phase 3)

8. **All hook scripts**: Set `#!/usr/bin/env bash`, `set -euo pipefail`, make executable.

### Acceptance Criteria

- [x] All hook scripts are executable (`chmod +x`)
- [x] `echo '{"session_id":"test","tool_name":"Edit","tool_input":{"file_path":"/foo.py"}}' | bash post-tool-use.sh` completes in <500ms (19ms)
- [x] Session JSONL files are created with valid JSONL events
- [x] `hooks.json` is valid JSON with correct event names and timeouts
- [x] `session-start.sh` registers session in SQLite DB
- [x] All hooks respond with valid `{"decision": "approve", ...}` JSON
- [x] Hooks degrade gracefully when directories are missing (create them)
- [x] Scripts work on both Linux and macOS bash

### Estimated Complexity

Medium. ~6 shell scripts averaging ~40 lines each + hooks.json. Shell-only critical path, Python one-liners for DB access. The main challenge is keeping `post-tool-use.sh` under 500ms.

---

## Phase 3: LLM Provider + Memory Extraction

**Goal**: Build the LLM provider abstraction and the extraction pipeline that distills session recordings into structured observations.

### Files to Create

| File | Purpose |
|------|---------|
| `src/scripts/llm_provider.py` | Multi-provider LLM abstraction |
| `src/scripts/extract.py` | Session transcript -> observations pipeline |
| `src/tests/test_extract.py` | Extraction tests with mock LLM |
| `src/requirements.txt` | Python dependencies |

### Spec References

- `specs/memory-extraction.md` — Extraction process, prompt, transcript parsing, LLM provider
- `specs/plugin-packaging.md` — `requirements.txt`, environment variables
- `agent.py:319-340` — IngestAgent prompt (adapt extraction categories)
- `agent.py:114-146` — `store_memory()` pattern

### Implementation Details

1. **`llm_provider.py`** — Thin abstraction over multiple LLM backends:
   - Base class `LLMProvider` with `complete(system_prompt, user_message) -> str`
   - `GoogleProvider` — Uses `google-genai` SDK. Default provider.
   - `AnthropicProvider` — Uses `anthropic` SDK.
   - `OpenAIProvider` — Uses `openai` SDK.
   - `LocalProvider` — OpenAI-compatible local endpoint via `CLAUDE_MEMORY_LOCAL_URL`.
   - `get_provider()` factory — Select based on `CLAUDE_MEMORY_PROVIDER` env var (default: `google`).
   - Handle missing SDK imports gracefully (ImportError -> helpful error message).
   - Model selection via `CLAUDE_MEMORY_MODEL` env var.
   - API key resolution: `CLAUDE_MEMORY_API_KEY` -> provider-specific fallback (`GOOGLE_API_KEY`, etc.)
   - Timeout: 60 seconds per call.

2. **`extract.py`** — Background extraction script:
   - CLI: `python extract.py --session-id <id> --transcript <path>`
   - Lock file: `claude-memory/extract.lock` (prevent concurrent extraction)
   - Process:
     a. Acquire lock (with stale lock detection: >10min + dead PID)
     b. Read session event log (`sessions/<session_id>.jsonl`)
     c. Read Claude Code transcript JSONL (`transcript_path`)
     d. Parse transcript: skip `thinking` entries, summarize tool_use/tool_result pairs, keep user/assistant messages
     e. Truncate combined text to ~8K tokens (prioritize recent entries)
     f. Send to LLM with extraction prompt (adapted from `agent.py:319-340`)
     g. Parse JSON array of observations from LLM response
     h. Enforce max 20 observations
     i. Store each via `storage.store_observation()`
     j. Update session via `storage.end_session(session_id, summary)`
     k. If >= 3 unconsolidated observations exist, spawn `consolidate.py` in background
     l. Release lock
   - Graceful failure: log errors to stderr, don't corrupt data

3. **Update `session-end.sh`** — Add extraction spawn:
   ```bash
   nohup python3 "$PLUGIN_ROOT/scripts/extract.py" \
     --session-id "$SESSION_ID" \
     --transcript "$TRANSCRIPT" \
     > /dev/null 2>&1 &
   ```

4. **`requirements.txt`**:
   ```
   google-genai>=1.0.0
   anthropic>=0.40.0
   openai>=1.0.0
   ```

5. **`test_extract.py`** — Tests with mock LLM:
   - `test_transcript_parsing` — Verify correct filtering and summarization of transcript entries
   - `test_extraction_stores_observations` — Mock LLM returns JSON, verify observations stored in DB
   - `test_extraction_max_20` — LLM returns 25 observations, verify only 20 stored
   - `test_extraction_lock_file` — Verify lock prevents concurrent runs
   - `test_extraction_graceful_failure` — LLM returns garbage, verify no crash, no data corruption
   - `test_provider_factory` — Verify `get_provider()` returns correct class based on env var

### Acceptance Criteria

- [x] `extract.py` runs as a standalone background process
- [x] LLM provider abstraction supports Google (default), Anthropic, and OpenAI
- [x] Transcript parsing handles all entry types (user, assistant, tool_use, tool_result, thinking)
- [x] Observations stored with correct priority (P1=1..P4=4), entities, topics, importance
- [x] Max 20 observations enforced per session
- [x] Lock file prevents concurrent extraction
- [x] Failed extraction doesn't corrupt existing data
- [x] `session-end.sh` spawns extraction as a background process
- [x] All tests pass with mock LLM provider (11 passed)

### Estimated Complexity

High. ~150 lines for llm_provider.py, ~250 lines for extract.py, ~200 lines for tests. External SDK dependencies. LLM prompt engineering for extraction quality.

---

## Phase 4: Context Injection

**Goal**: Build the query and injection pipeline that feeds relevant memories into new sessions via the SessionStart hook.

### Files to Create

| File | Purpose |
|------|---------|
| `src/scripts/query.py` | Query memories with relevance scoring |
| `src/scripts/inject.py` | Format memories as markdown for injection |
| `src/tests/test_inject.py` | Injection formatting and relevance scoring tests |

### Spec References

- `specs/context-injection.md` — Relevance scoring, token budget, output format, query strategy
- `specs/session-recording.md` — SessionStart hook response with `additionalContext`

### Implementation Details

1. **`query.py`** — Memory query engine:
   - `gather_context_signals()` — Collect git branch, working directory, recent files (`git diff --name-only HEAD~5`), extract topic keywords
   - `relevance_score(observation, context)` — Combine: recency (30%), priority (30%), importance (20%), topic match (20%)
   - `query_memories(db_path, context_signals, max_results)` — Orchestrate: get consolidations (last 10), get P1-P2 observations (last 30 days, limit 30), search topic-matched observations, deduplicate, score, rank
   - CLI entry point: `python query.py "search term"` for manual queries (used by `/memory-query` skill)
   - Output: JSON array of scored results for `inject.py` or formatted text for CLI

2. **`inject.py`** — Format scored memories into markdown:
   - `format_injection(scored_candidates, max_tokens)` — Build markdown within token budget
   - Token estimation: `len(text) / 4`
   - Section priority order:
     1. Key Insights — from consolidation insights
     2. Known Issues — P1/P2 bug/problem observations
     3. Recent Decisions — P1/P2 architectural decisions
     4. Patterns — P3 convention/pattern observations
     5. Context — P4 observations (only if budget allows)
   - Deduplication: same observation can't appear in multiple sections
   - Footer: `*{N} memories from {M} sessions | Query: /memory-query <topic>*`
   - `build_injection_context(session_id, db_path)` — Full pipeline: gather signals, query, format

3. **Update `session-start.sh`** — Add injection:
   - Call `python3 inject.py --session-id "$SESSION_ID"` to get formatted context
   - Include result in `additionalContext` field of JSON response
   - Graceful fallback: if Python fails or DB is empty/missing/locked, return plain `{"decision": "approve"}` with no `additionalContext`
   - Must stay under 500ms total

4. **`test_inject.py`** — Tests:
   - `test_relevance_scoring` — Verify scoring formula with known inputs
   - `test_format_injection_token_budget` — Verify output stays within 4096 token budget
   - `test_format_injection_section_order` — Verify consolidation insights appear first
   - `test_format_injection_deduplication` — Same observation doesn't appear twice
   - `test_empty_db_graceful` — Empty DB returns empty string, no error
   - `test_context_signals_git` — Verify git branch/recent files extraction (may mock git)
   - `test_build_injection_under_500ms` — Performance test with populated DB

### Acceptance Criteria

- [x] SessionStart hook returns `additionalContext` with relevant memories
- [x] Injected context stays within 4096 token budget
- [x] Relevance scoring prioritizes recent, high-priority, topic-matched observations
- [x] Consolidation insights appear before individual observations
- [x] Empty/missing/locked DB results in graceful fallback (no error)
- [x] Total hook execution time <500ms including DB query and formatting
- [x] `/memory-query` CLI works: `python query.py "auth"` returns formatted results
- [x] All tests pass (10 passed)

### Estimated Complexity

Medium-High. ~200 lines for query.py, ~150 lines for inject.py, ~150 lines for tests. No LLM calls (pure DB query + formatting). Performance-sensitive (500ms budget).

---

## Phase 5: Memory Consolidation

**Goal**: Build the background consolidation pipeline that finds cross-session patterns, resolves contradictions, and manages memory lifecycle.

### Files to Create

| File | Purpose |
|------|---------|
| `src/scripts/consolidate.py` | Background consolidation pipeline |
| `src/tests/test_consolidate.py` | Consolidation tests with mock LLM |

### Spec References

- `specs/memory-consolidation.md` — Consolidation process, prompt, contradiction resolution, intelligent forgetting
- `agent.py:342-356` — ConsolidateAgent prompt and tools
- `agent.py:527-543` — Consolidation loop with threshold check
- `agent.py:190-228` — `store_consolidation()` pattern

### Implementation Details

1. **`consolidate.py`** — Background consolidation script:
   - CLI: `python consolidate.py` (one-shot) or `python consolidate.py --continuous 30` (every 30 min)
   - Lock file: `claude-memory/consolidate.lock` (with stale lock detection: >10min + dead PID)
   - Process (per cycle):
     a. Acquire lock
     b. Read unconsolidated observations (max 20, most recent first)
     c. If < 3 observations, skip (threshold from `agent.py:534-536`)
     d. Read recent consolidation history (last 5) for context
     e. Send to LLM with consolidation prompt (adapted from `agent.py:342-356`)
     f. Parse response: `summary`, `insight`, `connections`, `source_ids`, `contradictions`, `redundant_ids`
     g. Call `storage.store_consolidation(source_ids, summary, insight, connections)`
     h. Handle contradictions: note in insight, don't delete old consolidations
     i. Handle redundant_ids: set importance to 0.1 (natural pruning)
     j. Run `storage.decay_importance(half_life_days=14)` — P1 gets `half_life * 2`
     k. Run `storage.prune_old(retention_days=30, min_importance=0.3)`
     l. Release lock
   - LLM timeout: 90 seconds
   - Graceful failure: log errors, release lock, don't corrupt data

2. **Lock management** — Shared pattern (could extract to `lib.py` if Phase 3 also needs it):
   ```python
   def acquire_lock(lock_path: Path) -> bool
   def release_lock(lock_path: Path) -> None
   ```
   - Lock contains `{"pid": ..., "timestamp": ...}`
   - Stale detection: age > 600s and PID is dead

3. **`test_consolidate.py`** — Tests with mock LLM:
   - `test_consolidation_threshold` — < 3 observations = skip, >= 3 = process
   - `test_consolidation_stores_result` — Mock LLM response, verify consolidation stored in DB
   - `test_consolidation_marks_sources` — Source observations get `consolidated=1`
   - `test_consolidation_bidirectional_connections` — Connections stored on both sides
   - `test_contradiction_resolution` — Mock contradiction response, verify handling
   - `test_redundancy_handling` — Redundant IDs get importance set to 0.1
   - `test_decay_importance_p1_slower` — P1 observations decay at half rate
   - `test_pruning_respects_recency` — Recent observations never pruned regardless of importance
   - `test_lock_prevents_concurrent` — Two processes, only one acquires lock
   - `test_continuous_mode` — Verify loop timing (mocked sleep)

### Acceptance Criteria

- [x] Consolidation runs only when >= 3 unconsolidated observations exist
- [x] Source observations marked as consolidated after processing
- [x] Bidirectional connections stored correctly
- [x] Importance decay applied (P1 decays slower)
- [x] Pruning removes only expired low-importance observations
- [x] Lock file prevents concurrent consolidation
- [x] Contradictions detected and resolved
- [x] Redundant observations get importance reduced
- [x] Continuous mode works with configurable interval
- [x] All tests pass with mock LLM (12 passed)

### Estimated Complexity

High. ~250 lines for consolidate.py, ~250 lines for tests. LLM prompt engineering. Lock management. Multiple storage operations per cycle.

---

## Phase 6: Integration Testing + Plugin Packaging

**Goal**: Package everything as a working Claude Code plugin, add the `/memory-query` skill, run end-to-end integration tests, and validate the complete flow.

### Files to Create

| File | Purpose |
|------|---------|
| `src/.claude-plugin/plugin.json` | Plugin manifest |
| `src/scripts/setup.sh` | First-run setup script |
| `src/skills/memory-query/SKILL.md` | `/memory-query` slash command |
| `src/tests/test_integration.py` | End-to-end integration tests |
| `src/README.md` | Plugin documentation |
| `src/LICENSE` | License file |

### Spec References

- `specs/plugin-packaging.md` — Full plugin structure, plugin.json, setup.sh, skill definition
- All other specs — Integration verification across all components

### Implementation Details

1. **`plugin.json`** — Plugin manifest:
   ```json
   {
     "name": "claude-memory",
     "version": "0.1.0",
     "description": "Always-on memory for Claude Code",
     "author": "always-on-memory-agent",
     "hooks": "./hooks/hooks.json",
     "skills": ["./skills/memory-query"],
     "setup": "./scripts/setup.sh"
   }
   ```

2. **`setup.sh`** — First-run setup (idempotent):
   - Validate Python 3.10+
   - Install Python dependencies from `requirements.txt`
   - Create memory directories (`claude-memory/sessions/`)
   - Initialize database via `python3 storage.py --init`

3. **`skills/memory-query/SKILL.md`** — Slash command:
   - Argument: query string
   - Runs: `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/query.py "{{query}}"`
   - Presents results organized by relevance

4. **`test_integration.py`** — End-to-end tests:
   - `test_full_session_lifecycle`:
     a. Simulate SessionStart (register session, get injection context)
     b. Simulate PostToolUse events (verify JSONL written)
     c. Simulate SessionEnd (verify extraction spawned)
     d. Run extraction with mock LLM (verify observations stored)
     e. Run consolidation with mock LLM (verify insights created)
     f. Simulate new SessionStart (verify memories injected)
   - `test_plugin_json_valid` — Parse and validate plugin.json schema
   - `test_hooks_json_valid` — Parse and validate hooks.json schema
   - `test_all_hooks_executable` — Verify all .sh files have execute permission
   - `test_all_scripts_importable` — Verify all .py files import without errors
   - `test_setup_idempotent` — Run setup.sh twice, verify no errors
   - `test_graceful_degradation` — Delete DB, verify hooks still respond correctly
   - `test_memory_query_skill` — Run query.py with populated DB, verify output format

5. **Final validation checklist** (manual):
   - `claude --plugin-dir ./src` loads without errors
   - All hook scripts respond with valid JSON
   - `python3 -m pytest src/tests/ -v` — all tests pass
   - Hook response time benchmarks (<500ms)
   - Background processes don't block hooks

6. **`README.md`** — User-facing documentation:
   - Installation instructions (plugin-dir and git install)
   - Configuration (environment variables table)
   - How it works (brief architecture)
   - Troubleshooting

### Acceptance Criteria

- [x] `claude --plugin-dir ./src` loads the plugin without errors
- [x] `setup.sh` runs idempotently and validates dependencies
- [x] All hook scripts are executable and return valid JSON
- [x] `/memory-query` skill is available and returns formatted results
- [x] Full session lifecycle test passes (record -> extract -> consolidate -> inject)
- [x] Plugin works with only `GOOGLE_API_KEY` set (no other config needed)
- [x] All 55 tests pass across all test files
- [x] Graceful degradation when DB is missing or locked

### Estimated Complexity

Medium. Mostly wiring existing components together. ~100 lines for integration tests, ~50 lines each for setup.sh, SKILL.md, plugin.json. Main effort is end-to-end testing and debugging the hook pipeline.

---

## Dependency Graph

```
Phase 1: Storage
    |
    v
Phase 2: Session Recording Hooks
    |
    +-----------+-----------+
    |                       |
    v                       v
Phase 3: Extraction    Phase 4: Injection
    |                       |
    v                       |
Phase 5: Consolidation      |
    |                       |
    +-----------+-----------+
                |
                v
        Phase 6: Integration
```

**Parallelizable**: Phases 3 and 4 can be built independently (both depend on Phase 1+2, neither depends on the other).

## Summary Table

| Phase | Files | Lines (est.) | Dependencies | Key Risk |
|-------|-------|-------------|--------------|----------|
| 1. Storage | 3 | ~500 | None | FTS5 trigger sync |
| 2. Hooks | 7 | ~300 | Phase 1 | <500ms performance |
| 3. Extraction | 4 | ~600 | Phase 1, 2 | LLM response parsing |
| 4. Injection | 3 | ~500 | Phase 1, 2 | 500ms budget with DB query |
| 5. Consolidation | 2 | ~500 | Phase 1, 3 | Lock management, LLM prompts |
| 6. Integration | 6 | ~400 | All | End-to-end hook pipeline |

**Total**: ~25 files, ~2800 lines estimated
