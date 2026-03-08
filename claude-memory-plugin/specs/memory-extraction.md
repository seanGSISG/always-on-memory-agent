# Memory Extraction

## Job To Be Done

Transform raw session recordings into structured, priority-tagged observations using an LLM observer pattern — distillation, not summarization.

## Mechanism

A Python script (`extract.py`) triggered as a background process by the `SessionEnd` hook. It reads the session's JSONL event log and the Claude Code transcript, then uses an LLM to distill observations.

### Trigger Flow

```
SessionEnd hook
  -> spawns: nohup python extract.py --session-id <id> --transcript <path> &
  -> hook returns immediately
  -> extract.py runs in background (30-120s typical)
```

### Extraction Process

1. Read the session event log (`sessions/<session_id>.jsonl`)
2. Read the Claude Code transcript JSONL (`transcript_path` from hook input)
3. Combine into a session summary (truncate to ~8K tokens if needed)
4. Send to LLM with the extraction prompt
5. Parse structured observations from LLM response
6. Store each observation via `storage.store_observation()`
7. Update session record via `storage.end_session()`

## Extraction Prompt

Adapted from `agent.py:319-340` (IngestAgent instruction):

```
You are a Session Observer. You analyze coding session transcripts and extract
structured observations — facts, decisions, patterns, and insights worth remembering.

For this session transcript, extract observations in the following categories:

**P1 (Critical)** — Architectural decisions with rationale, security-sensitive patterns
**P2 (Important)** — Bug fixes with root causes and solutions, dependency quirks and workarounds
**P3 (Useful)** — File relationships and cross-file dependencies, code patterns/conventions established, test strategies that worked
**P4 (Minor)** — Failed approaches and dead ends, environment setup details

For each observation, provide:
- content: A precise, factual statement (include file paths, error messages, function names — never approximate)
- entities: Key entities mentioned (files, functions, packages, services)
- topics: 2-4 topic tags
- priority: P1, P2, P3, or P4
- importance: Float 0.0 to 1.0

Rules:
- Extract concrete facts, not vague summaries
- Include exact file paths, function names, error messages
- Capture the "why" behind decisions, not just the "what"
- Note what DIDN'T work (failed approaches are valuable)
- Maximum 20 observations per session
- Skip trivial file reads and searches that led nowhere

Respond with a JSON array of observations:
[
  {
    "content": "...",
    "entities": ["src/auth.py", "JWT", "refresh_token()"],
    "topics": ["authentication", "security"],
    "priority": "P2",
    "importance": 0.7
  }
]
```

## LLM Provider Abstraction

A thin provider module (`llm_provider.py`) supporting multiple backends:

```python
class LLMProvider:
    def complete(self, system_prompt: str, user_message: str) -> str:
        """Send a completion request and return the text response."""

class GoogleProvider(LLMProvider):     # default (Gemini 3.1 Flash-Lite)
class AnthropicProvider(LLMProvider):
class OpenAIProvider(LLMProvider):
class LocalProvider(LLMProvider):      # OpenAI-compatible local endpoint

def get_provider() -> LLMProvider:
    """Factory based on CLAUDE_MEMORY_PROVIDER env var."""
```

Configuration via environment variables:
- `CLAUDE_MEMORY_PROVIDER`: `google` (default), `anthropic`, `openai`, `local`
- `CLAUDE_MEMORY_MODEL`: Model name (default: `gemini-3.1-flash-lite-preview` — matches original agent.py)
- `CLAUDE_MEMORY_API_KEY`: API key (falls back to `GOOGLE_API_KEY`, `ANTHROPIC_API_KEY`, or `OPENAI_API_KEY`)
- `CLAUDE_MEMORY_LOCAL_URL`: Base URL for local provider (default: `http://localhost:8080`)

## Data Flow

```
Session JSONL + Transcript
    |
    v
extract.py (background process)
    |
    v
LLM (extraction prompt)
    |
    v
JSON array of observations
    |
    v
storage.store_observation() x N
    |
    v
storage.end_session(session_id, summary)
```

## Transcript Parsing

The Claude Code transcript is JSONL with entry types:
- `user` — user messages
- `assistant` — Claude responses
- `tool_use` — tool calls with inputs
- `tool_result` — tool outputs
- `thinking` — Claude's reasoning

Parsing strategy:
1. Read transcript JSONL line by line
2. Skip `thinking` entries (internal reasoning, not useful for memory)
3. Summarize tool_use/tool_result pairs into concise action descriptions
4. Concatenate user/assistant messages for context
5. Truncate combined text to ~8K tokens (prioritize recent entries)

## Constraints

- Runs as a background process (not in the hook's critical path)
- Maximum 20 observations per session (LLM instructed, also enforced in code)
- Transcript truncation: keep last 8K tokens if transcript exceeds limit
- LLM timeout: 60 seconds per call
- Graceful failure: if extraction fails, log error but don't crash — session data is preserved in JSONL for retry
- Lock file: `~/.claude/projects/<project>/claude-memory/extract.lock` prevents concurrent extraction
- Priority mapping: P1=1, P2=2, P3=3, P4=4 (lower number = higher priority)

## Acceptance Criteria

1. `extract.py` runs as a background process and does not block the SessionEnd hook
2. Observations are stored with correct priority, entities, topics, and importance scores
3. Maximum 20 observations are extracted per session
4. LLM provider abstraction supports at least Anthropic and one other provider
5. Transcript parsing handles all entry types and truncates gracefully
6. Failed extraction does not corrupt existing data or prevent future sessions
7. Lock file prevents concurrent extraction processes from racing

## References

- `agent.py:319-340` — IngestAgent prompt (adapt extraction categories from this)
- `agent.py:114-146` — `store_memory()` pattern for storing structured data
- specs/memory-storage.md — `store_observation()` function signature
- specs/session-recording.md — Session JSONL format and SessionEnd trigger
- PLAN.md "Memory Extraction" section for priority categories
