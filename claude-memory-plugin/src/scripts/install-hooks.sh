#!/usr/bin/env bash
set -euo pipefail

# Generate .claude/settings.json at the project root with absolute paths to hook scripts.
# Usage: ./install-hooks.sh [project-root]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PLUGIN_ROOT/hooks"
PROJECT_ROOT="${1:-$(cd "$PLUGIN_ROOT/../.." && pwd)}"
SETTINGS_DIR="$PROJECT_ROOT/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

mkdir -p "$SETTINGS_DIR"

# If settings.json exists, merge hooks into it; otherwise create fresh
if [ -f "$SETTINGS_FILE" ]; then
    echo "Updating existing $SETTINGS_FILE with memory hooks..."
else
    echo "Creating $SETTINGS_FILE with memory hooks..."
fi

cat > "$SETTINGS_FILE" << SETTINGS_EOF
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOKS_DIR/session-start.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOKS_DIR/post-tool-use.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOKS_DIR/pre-compact.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOKS_DIR/stop.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOKS_DIR/session-end.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

echo "Hooks installed to $SETTINGS_FILE"
echo "Hook scripts point to: $HOOKS_DIR/"
