#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "Usage: ./loop.sh <plan|build>"
    echo ""
    echo "Prints the ralph-loop command for the chosen phase."
    echo ""
    echo "  plan   — Read specs + agent.py, produce IMPLEMENTATION_PLAN.md"
    echo "  build  — Follow IMPLEMENTATION_PLAN.md, implement phase by phase"
    echo ""
    echo "Copy and paste the printed command to start the ralph-loop."
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

case "$1" in
    plan)
        echo "Run this command in Claude Code from the claude-memory-plugin/ directory:"
        echo ""
        echo "  /ralph-loop \"\$(cat PROMPT_plan.md)\" --completion-promise \"PLAN COMPLETE\" --max-iterations 10"
        echo ""
        ;;
    build)
        echo "Run this command in Claude Code from the claude-memory-plugin/ directory:"
        echo ""
        echo "  /ralph-loop \"\$(cat PROMPT_build.md)\" --completion-promise \"BUILD COMPLETE\" --max-iterations 20"
        echo ""
        ;;
    *)
        usage
        ;;
esac
