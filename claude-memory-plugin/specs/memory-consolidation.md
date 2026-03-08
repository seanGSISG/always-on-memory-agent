# Memory Consolidation

## Job To Be Done

Connect, compress, and improve memories between sessions — like brain sleep cycles — by finding cross-session patterns, resolving contradictions, and intelligently forgetting low-value observations.

## Mechanism

A Python script (`consolidate.py`) that runs as a background process after extraction completes. It reads unconsolidated observations, uses an LLM to find patterns and connections, and stores synthesized insights.

### Trigger Flow

```
extract.py completes
  -> checks: are there >= 3 unconsolidated observations?
  -> if yes: python consolidate.py &
  -> consolidate.py acquires lock, processes, releases lock
```

Also runnable manually or on a schedule:
```bash
python consolidate.py                    # run once
python consolidate.py --continuous 30    # run every 30 minutes
```

## Consolidation Process

Adapted from `agent.py:342-356` (ConsolidateAgent) and `agent.py:527-543` (consolidation loop):

1. Acquire lock file (`consolidate.lock`)
2. Read unconsolidated observations (max 20, most recent first)
3. If fewer than 3 observations, skip (nothing meaningful to consolidate)
4. Read recent consolidation history for context (last 5)
5. Send observations + history to LLM with consolidation prompt
6. Parse response: summary, insight, connections
7. Call `storage.store_consolidation()` — marks source observations as consolidated
8. Run `storage.decay_importance()` — apply time-based importance decay
9. Run `storage.prune_old()` — remove expired low-importance observations
10. Release lock file

## Consolidation Prompt

Adapted from `agent.py:342-356`:

```
You are a Memory Consolidation Agent. You find patterns, connections, and insights
across coding session observations — like a brain consolidating during sleep.

Here are unconsolidated observations from recent sessions:

{observations_json}

And recent consolidation history for context:

{consolidations_json}

Your tasks:
1. Find connections between observations (cross-session patterns)
2. Create a synthesized summary across related observations
3. Identify one key insight or pattern
4. Detect contradictions with previous consolidations and resolve them
5. Note which observations are redundant or superseded

For connections, provide pairs of observation IDs with relationship descriptions.

Respond with JSON:
{
  "summary": "Synthesized summary across observations...",
  "insight": "One key pattern or insight discovered...",
  "connections": [
    {"from_id": 1, "to_id": 5, "relationship": "both relate to auth module refactoring"},
    {"from_id": 3, "to_id": 7, "relationship": "solution in #7 fixes the bug described in #3"}
  ],
  "source_ids": [1, 3, 5, 7],
  "contradictions": [
    {"observation_id": 2, "contradicts": "Previous consolidation said X, but observation shows Y", "resolution": "Y is correct because..."}
  ],
  "redundant_ids": [4]
}
```

## Contradiction Resolution

When the consolidation agent detects contradictions:
1. The newer observation is presumed correct (codebase evolves)
2. The contradicted consolidation is noted but not deleted (historical record)
3. A new consolidation is created that supersedes the old one
4. The `insight` field captures the resolution

## Intelligent Forgetting

Two mechanisms work together:

### Importance Decay
- `decay_importance()` applies exponential decay: `importance *= 0.5 ^ (age_days / half_life)`
- Default half-life: 14 days
- P1 observations decay slower (half-life * 2)
- Run during each consolidation cycle

### Pruning
- `prune_old()` removes observations where:
  - `age > retention_days` (default: 30) AND `importance < 0.3`
  - OR `age > retention_days * 2` AND `importance < 0.5`
- Consolidated observations are pruned more aggressively (their insights live in consolidations)
- Consolidation records are never auto-pruned (they're compact summaries)

### Redundancy Removal
- When the LLM identifies `redundant_ids`, those observations get their importance set to 0.1
- They'll be pruned in the next cycle naturally

## Concurrency

- Lock file: `~/.claude/projects/<project>/claude-memory/consolidate.lock`
- Lock contains PID and timestamp
- Stale lock detection: if lock is >10 minutes old and PID is dead, remove it
- If lock is held, skip consolidation (it'll run next time)
- Pattern:

```python
def acquire_lock(lock_path: Path) -> bool:
    if lock_path.exists():
        data = json.loads(lock_path.read_text())
        pid = data.get("pid")
        age = time.time() - data.get("timestamp", 0)
        if age > 600 and not pid_alive(pid):
            lock_path.unlink()  # stale lock
        else:
            return False  # lock held
    lock_path.write_text(json.dumps({"pid": os.getpid(), "timestamp": time.time()}))
    return True
```

## Constraints

- Minimum 3 unconsolidated observations to trigger consolidation
- Maximum 20 observations per consolidation batch
- LLM timeout: 90 seconds (consolidation prompts are larger)
- Lock file prevents concurrent consolidation
- Background process — never blocks session hooks
- Consolidation records are append-only (never modified after creation)
- Threshold check pattern from `agent.py:534-536`: check count before calling LLM

## Acceptance Criteria

1. Consolidation runs only when >= 3 unconsolidated observations exist
2. Source observations are marked as consolidated after processing
3. Bidirectional connections are stored on linked observations
4. Importance decay reduces scores proportionally to age (P1 decays slower)
5. Pruning removes only low-importance expired observations, never recent ones
6. Lock file prevents concurrent consolidation processes
7. Contradictions are detected and resolved with clear reasoning

## References

- `agent.py:342-356` — ConsolidateAgent prompt and tools
- `agent.py:190-228` — `store_consolidation()` with bidirectional connection updates
- `agent.py:527-543` — Consolidation loop with threshold check
- `agent.py:169-187` — `read_unconsolidated_memories()` pattern
- specs/memory-storage.md — Storage functions used by consolidation
- specs/memory-extraction.md — Extraction triggers consolidation
