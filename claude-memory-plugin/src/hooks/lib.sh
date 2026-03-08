#!/usr/bin/env bash
# Shared shell functions for claude-memory hooks

get_memory_dir() {
    local project_dir="${CLAUDE_PROJECT_DIR:-$HOME/.claude/projects/default}"
    echo "${project_dir}/claude-memory"
}

get_session_log() {
    local session_id="$1"
    local memory_dir
    memory_dir="$(get_memory_dir)"
    echo "${memory_dir}/sessions/${session_id}.jsonl"
}

ensure_dir() {
    local dir="$1"
    [ -d "$dir" ] || mkdir -p "$dir"
}

resolve_python() {
    # 3-tier venv resolution: production -> dev -> system
    local plugin_root="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local prod_python="$HOME/.config/claude-memory/.venv/bin/python3"
    local dev_python="${plugin_root}/../.venv/bin/python3"
    if [ -x "$prod_python" ]; then
        echo "$prod_python"
    elif [ -x "$dev_python" ]; then
        echo "$dev_python"
    else
        echo "python3"
    fi
}

extract_json_field() {
    local field="$1"
    local python
    python="$(resolve_python)"
    "$python" -c "import sys,json; print(json.load(sys.stdin).get('$field',''))"
}
