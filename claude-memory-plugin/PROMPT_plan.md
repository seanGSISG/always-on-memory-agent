You are planning the implementation of **claude-memory**, a Claude Code plugin that provides always-on memory for developer workflows.

## Your Task

Read all project specs and the reference implementation, then produce a detailed `IMPLEMENTATION_PLAN.md` with ordered build phases.

## Steps

1. **Read all specs** in order:
   - `specs/memory-storage.md` — foundation layer
   - `specs/session-recording.md` — hook-based capture
   - `specs/memory-extraction.md` — LLM observation extraction
   - `specs/memory-consolidation.md` — background consolidation
   - `specs/context-injection.md` — session start injection
   - `specs/plugin-packaging.md` — plugin structure and packaging

2. **Read the operational guide**: `AGENTS.md`

3. **Read the reference implementation**: `../agent.py` (the original always-on memory agent)
   - Pay special attention to lines 80-108 (schema), 114-146 (store), 190-228 (consolidation), 319-356 (prompts), 527-543 (background loop)

4. **Read the project plan**: `PLAN.md` for context and design decisions

5. **Analyze dependencies** between components:
   - What must be built first? (storage layer)
   - What can be built in parallel? (extraction and injection are independent)
   - What requires integration testing? (end-to-end hook flow)

6. **Produce `IMPLEMENTATION_PLAN.md`** with:
   - 4-6 ordered phases
   - Each phase lists: files to create, spec references, acceptance criteria, estimated complexity
   - Phase 1 should be the storage foundation
   - Final phase should be integration testing and packaging
   - Each phase should be completable in one ralph-loop build iteration

## Output

Write the plan to `IMPLEMENTATION_PLAN.md` in this directory. The plan should be detailed enough that a developer (or Claude in build mode) can follow it step-by-step without ambiguity.

## Completion Promise

When the plan is complete and written to `IMPLEMENTATION_PLAN.md`, output exactly:

PLAN COMPLETE
