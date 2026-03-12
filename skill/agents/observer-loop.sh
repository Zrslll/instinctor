#!/usr/bin/env bash
# Continuous Learning v2 - Observer background loop

set +e
unset CLAUDECODE

SLEEP_PID=""
USR1_FIRED=0
STATS_FILE="${PROJECT_DIR}/token-stats.jsonl"

# Resolve python command
PYTHON_CMD="${CLV2_PYTHON_CMD:-}"
if [ -z "$PYTHON_CMD" ]; then
  for _cmd in python3 python; do
    if command -v "$_cmd" >/dev/null 2>&1; then
      PYTHON_CMD="$_cmd"
      break
    fi
  done
fi

cleanup() {
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$PID_FILE"
  fi
  exit 0
}
trap cleanup TERM INT

analyze_observations() {
  if [ ! -f "$OBSERVATIONS_FILE" ]; then
    return
  fi

  obs_count=$(wc -l < "$OBSERVATIONS_FILE" 2>/dev/null || echo 0)
  if [ "$obs_count" -lt "$MIN_OBSERVATIONS" ]; then
    return
  fi

  echo "[$(date)] Analyzing $obs_count observations for project ${PROJECT_NAME}..." >> "$LOG_FILE"

  if [ "${CLV2_IS_WINDOWS:-false}" = "true" ] && [ "${ECC_OBSERVER_ALLOW_WINDOWS:-false}" != "true" ]; then
    echo "[$(date)] Skipping claude analysis on Windows due to known non-interactive hang issue (#295). Set ECC_OBSERVER_ALLOW_WINDOWS=true to override." >> "$LOG_FILE"
    return
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "[$(date)] claude CLI not found, skipping analysis" >> "$LOG_FILE"
    return
  fi

  prompt_file="$(mktemp "${TMPDIR:-/tmp}/ecc-observer-prompt.XXXXXX")"
  {
    cat <<PROMPT
You are an observation analyzer. You receive session observations as text below and must output instinct definitions directly.

Analyze the following observations for the project "${PROJECT_NAME}" and identify patterns (user corrections, error resolutions, repeated workflows, tool preferences).
If you find 3+ occurrences of the same pattern, output each instinct using the format below.

All observations are provided in this prompt text. Do not request any file access.
Separate each instinct with a line containing only: ===INSTINCT_SEPARATOR===

Each instinct MUST use this exact format (YAML frontmatter + markdown body):

---
id: kebab-case-name
trigger: when <specific condition>
confidence: <0.3-0.85 based on frequency: 3-5 times=0.5, 6-10=0.7, 11+=0.85>
domain: <one of: code-style, testing, git, debugging, workflow, file-patterns>
source: session-observation
scope: project
project_id: ${PROJECT_ID}
project_name: ${PROJECT_NAME}
---

# Title

## Action
<what to do, one clear sentence>

## Evidence
- Observed N times in session <id>
- Pattern: <description>
- Last observed: <date>

Rules:
- Be conservative, only clear patterns with 3+ observations
- Use narrow, specific triggers
- Never include actual code snippets, only describe patterns
- The YAML frontmatter (between --- markers) with id field is MANDATORY
- If a pattern seems universal (not project-specific), set scope to global instead of project
- Examples of global patterns: always validate user input, prefer explicit error handling
- Examples of project patterns: use React functional components, follow Django REST framework conventions
- If no clear patterns found, output exactly: NO_PATTERNS_FOUND

=== OBSERVATIONS START ===
PROMPT
    cat "$OBSERVATIONS_FILE"
    echo ""
    echo "=== OBSERVATIONS END ==="
  } > "$prompt_file"

  timeout_seconds="${ECC_OBSERVER_TIMEOUT_SECONDS:-120}"
  exit_code=0
  output_file="$(mktemp "${TMPDIR:-/tmp}/ecc-observer-output.XXXXXX")"

  claude -p --model haiku --max-turns 1 --output-format json --tools "" < "$prompt_file" > "$output_file" 2>>"$LOG_FILE" &
  claude_pid=$!

  (
    sleep "$timeout_seconds"
    if kill -0 "$claude_pid" 2>/dev/null; then
      echo "[$(date)] Claude analysis timed out after ${timeout_seconds}s; terminating process" >> "$LOG_FILE"
      kill "$claude_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  wait "$claude_pid"
  exit_code=$?
  kill "$watchdog_pid" 2>/dev/null || true
  rm -f "$prompt_file"

  echo "[$(date)] Claude finished (exit=$exit_code, output_size=$(wc -c < "$output_file" 2>/dev/null || echo 0))" >> "$LOG_FILE"
  if [ "$exit_code" -eq 0 ] && [ -s "$output_file" ] && [ -n "$PYTHON_CMD" ]; then
    # Parse JSON output: extract instincts + write token stats
    PARSE_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/parse-observer-output.py"
    PROMOTE_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/instinct-cli.py"
    echo "[$(date)] Running parser: $PYTHON_CMD $PARSE_SCRIPT" >> "$LOG_FILE"
    parse_output=$(STATS_FILE="$STATS_FILE" \
    OBS_COUNT="$obs_count" \
    PROJECT_NAME_ENV="$PROJECT_NAME" \
    PROJECT_ID_ENV="$PROJECT_ID" \
    INSTINCTS_DIR="$INSTINCTS_DIR" \
    HOMUNCULUS_DIR="${CONFIG_DIR:-$HOME/.claude/homunculus}" \
    "$PYTHON_CMD" "$PARSE_SCRIPT" < "$output_file" 2>&1)
    echo "$parse_output" >> "$LOG_FILE"

    # Auto-promote if new instincts were created
    if echo "$parse_output" | grep -qi "created"; then
      echo "[$(date)] New instincts created, running auto-promote..." >> "$LOG_FILE"
      CLAUDE_PROJECT_DIR="${PROJECT_ROOT:-}" "$PYTHON_CMD" "$PROMOTE_SCRIPT" promote --force >> "$LOG_FILE" 2>&1 || true
    fi
  else
    echo "[$(date)] Claude analysis failed (exit=$exit_code, python=$PYTHON_CMD)" >> "$LOG_FILE"
  fi

  rm -f "$output_file"

  if [ -f "$OBSERVATIONS_FILE" ]; then
    archive_dir="${PROJECT_DIR}/observations.archive"
    mkdir -p "$archive_dir"
    mv "$OBSERVATIONS_FILE" "$archive_dir/processed-$(date +%Y%m%d-%H%M%S)-$$.jsonl" 2>/dev/null || true
  fi
}

on_usr1() {
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
  USR1_FIRED=1
  analyze_observations
}
trap on_usr1 USR1

echo "$$" > "$PID_FILE"
echo "[$(date)] Observer started for ${PROJECT_NAME} (PID: $$)" >> "$LOG_FILE"

while true; do
  sleep "$OBSERVER_INTERVAL_SECONDS" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""

  if [ "$USR1_FIRED" -eq 1 ]; then
    USR1_FIRED=0
  else
    analyze_observations
  fi
done
