#!/bin/bash
# Continuous Learning v2 - Instinct Injection Hook
#
# PreToolUse prompt hook: injects learned instincts into session context.
# Caches per session_id to avoid repeated injection.

set -e

# Read stdin (Claude Code hook JSON)
INPUT_JSON=$(cat)

if [ -z "$INPUT_JSON" ]; then
  exit 0
fi

# Resolve python
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_CMD="${CLV2_PYTHON_CMD:-}"
if [ -z "$PYTHON_CMD" ]; then
  for _cmd in python3 python; do
    if command -v "$_cmd" >/dev/null 2>&1; then
      PYTHON_CMD="$_cmd"
      break
    fi
  done
fi

if [ -z "$PYTHON_CMD" ]; then
  exit 0
fi

# Pass stdin JSON to inject script
echo "$INPUT_JSON" | "$PYTHON_CMD" "${SKILL_ROOT}/scripts/inject-instincts.py"
