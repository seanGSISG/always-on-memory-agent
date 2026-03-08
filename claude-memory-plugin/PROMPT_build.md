You are building **claude-memory**, a Claude Code plugin that provides always-on memory for developer workflows.

## Your Task

Follow `IMPLEMENTATION_PLAN.md` phase by phase. For each phase: implement, test, mark done, then move to the next.

## Steps

For each phase in `IMPLEMENTATION_PLAN.md`:

1. **Read the phase** — understand what files to create and which specs to reference
2. **Read the relevant specs** — each phase references specific spec files in `specs/`
3. **Read `AGENTS.md`** — for build commands, file conventions, and validation checklist
4. **Implement** — create/edit the files listed in the phase
5. **Test** — run the acceptance criteria for the phase:
   - Unit tests: `python3 -m pytest src/tests/ -v` (for phases with tests)
   - Script validation: ensure Python scripts import without errors
   - Hook validation: ensure shell scripts are executable and return valid JSON
6. **Mark done** — update `IMPLEMENTATION_PLAN.md`, changing `[ ]` to `[x]` for completed items
7. **Move to next phase** — repeat until all phases are complete

## Rules

- Follow specs exactly — they define the contracts between components
- Reference `../agent.py` for implementation patterns (specific line ranges are noted in specs)
- All Python code: Python 3.10+, type hints, minimal dependencies
- All shell scripts: POSIX bash, `set -euo pipefail`, executable permissions
- Test with real SQLite operations (use temp DB in tests)
- Mock LLM calls in tests (don't make real API calls)
- Keep hook scripts fast (<500ms) — dispatch heavy work to background processes

## Key Files to Reference

- `IMPLEMENTATION_PLAN.md` — your roadmap (update as you go)
- `AGENTS.md` — operational guide with build commands
- `specs/*.md` — detailed specifications for each component
- `../agent.py` — reference implementation patterns
- `PLAN.md` — project context and design decisions

## Completion Promise

When all phases in `IMPLEMENTATION_PLAN.md` are marked complete and tests pass, output exactly:

BUILD COMPLETE
