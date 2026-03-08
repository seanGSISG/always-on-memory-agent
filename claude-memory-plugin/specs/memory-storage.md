# Memory Storage

## Job To Be Done

Provide a reliable SQLite-based storage layer for observations, consolidations, and session metadata with full-text search and zero external dependencies.

## Mechanism

SQLite database at `~/.claude/projects/<project>/claude-memory.db` using WAL mode for concurrent read/write access. The storage layer is a Python module (`storage.py`) exposing CRUD operations used by all other components.

## Schema

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    content TEXT NOT NULL,
    entities TEXT NOT NULL DEFAULT '[]',       -- JSON array of strings
    topics TEXT NOT NULL DEFAULT '[]',         -- JSON array of strings
    priority INTEGER NOT NULL DEFAULT 3,       -- P1 (highest) to P4 (lowest)
    importance REAL NOT NULL DEFAULT 0.5,      -- 0.0 to 1.0, decays over time
    source_file TEXT,                          -- file that triggered this observation
    created_at TEXT NOT NULL,                  -- ISO 8601 UTC
    consolidated INTEGER NOT NULL DEFAULT 0   -- 0=pending, 1=consolidated
);

CREATE TABLE IF NOT EXISTS consolidations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_ids TEXT NOT NULL,                  -- JSON array of observation IDs
    summary TEXT NOT NULL,
    insight TEXT NOT NULL,
    connections TEXT NOT NULL DEFAULT '[]',    -- JSON array of {from_id, to_id, relationship}
    created_at TEXT NOT NULL                   -- ISO 8601 UTC
);

CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL UNIQUE,
    branch TEXT,
    working_dir TEXT,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    summary TEXT
);

-- Full-text search index on observation content
CREATE VIRTUAL TABLE IF NOT EXISTS observations_fts USING fts5(
    content,
    content='observations',
    content_rowid='id'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS observations_ai AFTER INSERT ON observations BEGIN
    INSERT INTO observations_fts(rowid, content) VALUES (new.id, new.content);
END;

CREATE TRIGGER IF NOT EXISTS observations_ad AFTER DELETE ON observations BEGIN
    INSERT INTO observations_fts(observations_fts, rowid, content) VALUES ('delete', old.id, old.content);
END;

CREATE TRIGGER IF NOT EXISTS observations_au AFTER UPDATE ON observations BEGIN
    INSERT INTO observations_fts(observations_fts, rowid, content) VALUES ('delete', old.id, old.content);
    INSERT INTO observations_fts(rowid, content) VALUES (new.id, new.content);
END;
```

## Storage Operations

### Core Functions

```python
def init_db(db_path: str) -> sqlite3.Connection
    # Create tables, enable WAL, return connection

def store_observation(
    session_id: str, content: str, entities: list[str],
    topics: list[str], priority: int, importance: float,
    source_file: str | None = None
) -> int
    # Returns observation ID

def get_observations(
    limit: int = 50,
    unconsolidated_only: bool = False,
    session_id: str | None = None,
    min_priority: int | None = None
) -> list[dict]

def search_observations(query: str, limit: int = 20) -> list[dict]
    # FTS5 search on content

def store_consolidation(
    source_ids: list[int], summary: str, insight: str,
    connections: list[dict]
) -> int
    # Marks source observations as consolidated
    # Updates bidirectional connections on observations
    # Pattern from agent.py:190-228

def get_consolidations(limit: int = 10) -> list[dict]

def store_session(session_id: str, branch: str | None, working_dir: str | None) -> None
def end_session(session_id: str, summary: str | None = None) -> None

def prune_old(retention_days: int = 30, min_importance: float = 0.3) -> int
    # Delete observations older than retention_days with importance < min_importance
    # Returns count of pruned rows

def decay_importance(half_life_days: int = 14) -> None
    # Apply exponential decay: importance *= 0.5 ^ (age_days / half_life_days)
    # Run periodically (e.g., during consolidation)
```

### Connection Updates (from agent.py:213-222)

When storing consolidations with connections, update both sides:

```python
for conn in connections:
    from_id, to_id = conn["from_id"], conn["to_id"]
    relationship = conn["relationship"]
    # Add connection to both observations' entities
    for obs_id in [from_id, to_id]:
        existing = get_observation_connections(obs_id)
        linked = to_id if obs_id == from_id else from_id
        existing.append({"linked_to": linked, "relationship": relationship})
        update_observation_connections(obs_id, existing)
```

## Constraints

- Database path: `~/.claude/projects/<project>/claude-memory.db` (derived from `CLAUDE_PROJECT_DIR` env var or current working directory hash)
- WAL mode for concurrent access (extraction writing while injection reads)
- `busy_timeout = 5000` to handle lock contention
- All timestamps in ISO 8601 UTC
- JSON fields (`entities`, `topics`, `connections`, `source_ids`) stored as JSON strings
- Max observation content length: 2000 characters
- FTS5 for search (built into SQLite, no extensions needed)
- Connection pool: single connection per process, reused

## Acceptance Criteria

1. `init_db()` creates all tables idempotently (safe to call multiple times)
2. `store_observation()` returns a valid ID and the observation is queryable immediately
3. `search_observations("some query")` returns relevant results ranked by FTS5 score
4. `store_consolidation()` marks source observations as consolidated and updates bidirectional connections
5. `prune_old()` removes only observations exceeding retention period with low importance
6. `decay_importance()` reduces importance scores proportionally to age
7. Concurrent read/write from separate processes does not corrupt the database (WAL mode)

## References

- `agent.py:80-108` — SQLite schema pattern (memories, consolidations, processed_files tables)
- `agent.py:114-146` — `store_memory()` with JSON entity/topic storage
- `agent.py:190-228` — `store_consolidation()` with bidirectional connection updates
- `agent.py:149-188` — Read/query operations pattern
