# Context Injection

## Job To Be Done

Automatically inject the most relevant memories into new Claude Code sessions so developers never lose context, with zero manual effort.

## Mechanism

The `SessionStart` hook queries the memory database and returns relevant observations and consolidation insights via the `additionalContext` field in the hook's JSON response.

### Hook Response Format

```json
{
  "decision": "approve",
  "reason": "memory context injected",
  "additionalContext": "# Project Memory\n\n## Recent Insights\n- ..."
}
```

The `additionalContext` string is injected into Claude's context at session start, appearing as system-level information Claude can reference.

## Relevance Scoring

Each observation/consolidation gets a relevance score combining multiple signals:

```python
def relevance_score(observation, context) -> float:
    score = 0.0

    # Recency: recent observations score higher
    age_days = (now - observation.created_at).days
    recency = max(0, 1.0 - (age_days / 30))  # linear decay over 30 days
    score += recency * 0.3

    # Priority: P1 > P2 > P3 > P4
    priority_weight = {1: 1.0, 2: 0.7, 3: 0.4, 4: 0.2}
    score += priority_weight.get(observation.priority, 0.2) * 0.3

    # Importance: stored importance score (with decay applied)
    score += observation.importance * 0.2

    # Topic match: overlap with current context signals
    topic_overlap = len(set(observation.topics) & context.active_topics)
    score += min(topic_overlap / 3, 1.0) * 0.2

    return score
```

### Context Signals

Gathered at session start to inform relevance:
- **Git branch**: current branch name, parsed for topic keywords
- **Working directory**: project path
- **Recent files**: last 10 modified files in the project (from `git diff --name-only HEAD~5`)
- **Time of day**: used only for recency weighting

## Token Budget

- Maximum injection: **4096 tokens** (~4K tokens, configurable via `CLAUDE_MEMORY_MAX_INJECT_TOKENS`)
- Token estimation: `len(text) / 4` (rough chars-to-tokens ratio)
- If budget is exceeded, drop lowest-scored observations first

## Output Format

The injected context is formatted as concise markdown:

```markdown
# Project Memory (auto-injected)

## Key Insights
- Auth module uses JWT with 15-min refresh tokens; refresh logic in src/auth/refresh.py
- Database migrations must run before tests; see scripts/migrate.sh

## Recent Decisions
- Chose SQLAlchemy over raw SQL for the API layer (PR #42) — rationale: team familiarity
- Moved to pytest-asyncio for async test support

## Known Issues
- Flaky test in tests/test_api.py:test_concurrent_writes — race condition, needs lock
- Import order matters in src/plugins/__init__.py — circular dependency if changed

## Patterns
- All API endpoints follow src/routes/{resource}.py convention
- Error responses use {"error": str, "code": int} format

---
*{N} memories from {M} sessions | Query: /memory-query <topic>*
```

### Section Priority

Include sections in this order, stopping when token budget is reached:
1. **Key Insights** — consolidation insights (highest value, already synthesized)
2. **Known Issues** — P1/P2 observations about bugs or problems
3. **Recent Decisions** — P1/P2 observations about architectural choices
4. **Patterns** — P3 observations about conventions and patterns
5. **Context** — P4 observations (only if budget allows)

## Query Strategy

```python
def build_injection_context(session_id: str, db_path: str) -> str:
    db = init_db(db_path)
    context = gather_context_signals()  # git branch, recent files

    # 1. Get recent consolidation insights (last 10)
    consolidations = get_consolidations(limit=10)

    # 2. Get high-priority observations (P1-P2, last 30 days)
    critical = get_observations(limit=30, min_priority=2)

    # 3. Get topic-matched observations
    if context.active_topics:
        matched = search_observations(" ".join(context.active_topics), limit=20)
    else:
        matched = []

    # 4. Score and rank all candidates
    candidates = deduplicate(consolidations + critical + matched)
    scored = [(relevance_score(c, context), c) for c in candidates]
    scored.sort(reverse=True)

    # 5. Format within token budget
    return format_injection(scored, max_tokens=4096)
```

## Graceful Fallback

The injection must never fail visibly:

| Condition | Behavior |
|---|---|
| DB doesn't exist | Return `{"decision": "approve"}` with no `additionalContext` |
| DB is locked | Return `{"decision": "approve"}` with no `additionalContext` |
| DB is empty | Return `{"decision": "approve"}` with no `additionalContext` |
| Query error | Log error to stderr, return `{"decision": "approve"}` |
| Python not available | Shell hook returns `{"decision": "approve"}` directly |

## Constraints

- Must complete in <500ms (it's a SessionStart hook, blocks session)
- Token budget: 4096 tokens default, configurable
- No LLM calls during injection (pure database query + formatting)
- Read-only database access (no writes during injection)
- Deduplication: same observation shouldn't appear in multiple sections
- Progressive disclosure: include footer with `/memory-query` hint for deeper access

## Acceptance Criteria

1. SessionStart hook returns valid JSON with `additionalContext` containing relevant memories
2. Injected context stays within the configured token budget
3. Relevance scoring prioritizes recent, high-priority, topic-matched observations
4. Empty/missing/locked database results in graceful fallback (no error, no crash)
5. Total hook execution time is <500ms including DB query and formatting
6. Consolidation insights appear before individual observations
7. Output is well-formatted markdown that Claude can parse and reference

## References

- specs/memory-storage.md — `get_observations()`, `get_consolidations()`, `search_observations()`
- specs/session-recording.md — SessionStart hook contract and hooks.json
- PLAN.md "Context Injection Points" section
- PLAN.md "Configuration" section for `CLAUDE_MEMORY_MAX_INJECT_TOKENS`
