#!/usr/bin/env bash
# Continuous Learning v2 - Observer background loop

set +e
unset CLAUDECODE

SLEEP_PID=""
USR1_FIRED=0
ANALYZING=0
GRACEFUL_EXIT=0
ACTIVE_CLAUDE_PID=""
IDLE_CYCLES=0
MAX_IDLE_CYCLES=6  # exit after 6 empty cycles (~30 min at 5-min interval)

# Resolve python command (needed for auto-promote)
PYTHON_CMD="${CLV2_PYTHON_CMD:-}"
if [ -z "$PYTHON_CMD" ]; then
  for _cmd in python3 python; do
    if command -v "$_cmd" >/dev/null 2>&1; then
      PYTHON_CMD="$_cmd"
      break
    fi
  done
fi

CLEANUP_DONE=0
cleanup() {
  [ "$CLEANUP_DONE" -eq 1 ] && return
  CLEANUP_DONE=1
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  # Kill active claude process if running
  if [ -n "$ACTIVE_CLAUDE_PID" ] && kill -0 "$ACTIVE_CLAUDE_PID" 2>/dev/null; then
    echo "[$(date)] Cleanup: killing claude process $ACTIVE_CLAUDE_PID" >> "$LOG_FILE"
    kill "$ACTIVE_CLAUDE_PID" 2>/dev/null || true
  fi
  if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$PID_FILE"
  fi
  exit 0
}
trap cleanup TERM INT

# Global concurrency: max parallel claude-observer processes across all projects
_count_running_claude_observers() {
  pgrep -f "claude.*--model haiku.*--max-turns" 2>/dev/null | wc -l | tr -d ' '
}
MAX_PARALLEL_ANALYSES="${MAX_PARALLEL_ANALYSES:-3}"

analyze_observations() {
  if [ ! -f "$OBSERVATIONS_FILE" ]; then
    return 1  # no file — idle
  fi

  obs_count=$(wc -l < "$OBSERVATIONS_FILE" 2>/dev/null || echo 0)
  if [ "$obs_count" -lt "$MIN_OBSERVATIONS" ]; then
    return 1  # signal: nothing to do (for idle tracking)
  fi

  IDLE_CYCLES=0
  ANALYZING=1

  echo "[$(date)] Analyzing $obs_count observations for project ${PROJECT_NAME}..." >> "$LOG_FILE"

  if [ "${CLV2_IS_WINDOWS:-false}" = "true" ] && [ "${ECC_OBSERVER_ALLOW_WINDOWS:-false}" != "true" ]; then
    echo "[$(date)] Skipping claude analysis on Windows due to known non-interactive hang issue (#295). Set ECC_OBSERVER_ALLOW_WINDOWS=true to override." >> "$LOG_FILE"
    ANALYZING=0
    return
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "[$(date)] claude CLI not found, skipping analysis" >> "$LOG_FILE"
    ANALYZING=0
    return
  fi

  # Global concurrency limit
  _running=$(_count_running_claude_observers)
  if [ "$_running" -ge "$MAX_PARALLEL_ANALYSES" ]; then
    echo "[$(date)] Skipping analysis: $_running claude processes already running (max=$MAX_PARALLEL_ANALYSES)" >> "$LOG_FILE"
    ANALYZING=0
    return
  fi

  # Collect existing instincts for deduplication
  existing_instincts=""
  for _idir in "${INSTINCTS_DIR}" "${CONFIG_DIR:-$HOME/.claude/instinctor}/instincts/personal"; do
    if [ -d "$_idir" ]; then
      for _if in "$_idir"/*.md "$_idir"/*.yaml "$_idir"/*.yml; do
        [ -f "$_if" ] || continue
        _id=$(grep '^id:' "$_if" 2>/dev/null | head -1 | sed 's/^id:[[:space:]]*//')
        _trigger=$(grep '^trigger:' "$_if" 2>/dev/null | head -1 | sed 's/^trigger:[[:space:]]*//')
        [ -n "$_id" ] && existing_instincts="${existing_instincts}
- ${_id}: ${_trigger}"
      done
    fi
  done

  # Snapshot instincts before analysis to detect new ones
  _instincts_before=""
  if [ -d "$INSTINCTS_DIR" ]; then
    _instincts_before=$(ls "$INSTINCTS_DIR"/*.md 2>/dev/null | sort)
  fi

  prompt_file="$(mktemp "${TMPDIR:-/tmp}/ecc-observer-prompt.XXXXXX")"
  cat > "$prompt_file" <<PROMPT
You are an observation analyzer for the project "${PROJECT_NAME}" (id: ${PROJECT_ID}).

Your task:
1. Read the ENTIRE observations file in ONE call (no offset/limit): ${OBSERVATIONS_FILE}
2. Identify repeating patterns (user corrections, error resolutions, repeated workflows, tool preferences)
3. If you find 3+ occurrences of the same pattern, create an instinct file in ${INSTINCTS_DIR}/

IMPORTANT: Read the whole file at once. Do NOT use offset or limit parameters. Do NOT read it in chunks.

Each instinct file must be named <id>.md and use this exact format:

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

=== EXISTING INSTINCTS (DO NOT DUPLICATE) ===${existing_instincts}
=== END EXISTING INSTINCTS ===

Rules:
- DEDUPLICATION: Do NOT create an instinct if an existing instinct above covers the same or similar behavior. Check trigger overlap carefully.
- REPEATABLE PATTERNS ONLY: Only create instincts for behaviors that will repeat in future sessions. Skip one-time actions like "create README", "set up project", "run initial audit", "fix specific bug".
- Ask yourself: "Will the user do this again next week?" If no — skip it.
- Be conservative, only clear patterns with 3+ observations
- Use narrow, specific triggers — not vague ("when working with files") but precise ("when reading files larger than 500 lines")
- Never include actual code snippets, only describe patterns
- Do NOT create tautological instincts ("use bash for bash operations", "read files before editing")
- Do NOT create instincts that describe obvious/default tool behavior
- The YAML frontmatter (between --- markers) with id field is MANDATORY
- If a pattern seems universal (not project-specific), set scope to global instead of project
- If no clear NEW patterns found, do NOT create any files. Just say: NO_PATTERNS_FOUND
PROMPT

  timeout_seconds="${ECC_OBSERVER_TIMEOUT_SECONDS:-300}"
  exit_code=0

  claude --print --model haiku --max-turns 20 \
    --allowedTools "Read,Write,Glob" \
    --permission-mode bypassPermissions \
    < "$prompt_file" >> "$LOG_FILE" 2>&1 &
  ACTIVE_CLAUDE_PID=$!

  (
    sleep "$timeout_seconds"
    if kill -0 "$ACTIVE_CLAUDE_PID" 2>/dev/null; then
      echo "[$(date)] Claude analysis timed out after ${timeout_seconds}s; terminating process" >> "$LOG_FILE"
      kill "$ACTIVE_CLAUDE_PID" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  wait "$ACTIVE_CLAUDE_PID"
  exit_code=$?
  ACTIVE_CLAUDE_PID=""
  kill "$watchdog_pid" 2>/dev/null || true
  rm -f "$prompt_file"

  echo "[$(date)] Claude finished (exit=$exit_code)" >> "$LOG_FILE"

  # Check if new instinct files appeared
  _instincts_after=""
  if [ -d "$INSTINCTS_DIR" ]; then
    _instincts_after=$(ls "$INSTINCTS_DIR"/*.md 2>/dev/null | sort)
  fi

  _new_instincts=$(comm -13 <(echo "$_instincts_before") <(echo "$_instincts_after") 2>/dev/null | grep -v '^$')
  _new_count=0
  if [ -n "$_new_instincts" ]; then
    _new_count=$(echo "$_new_instincts" | wc -l | tr -d ' ')
  fi

  if [ "$_new_count" -gt 0 ]; then
    echo "[$(date)] Claude created $_new_count new instinct(s):" >> "$LOG_FILE"
    echo "$_new_instincts" >> "$LOG_FILE"

    # Auto-promote new instincts
    PROMOTE_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/instinct-cli.py"
    if [ -n "$PYTHON_CMD" ] && [ -f "$PROMOTE_SCRIPT" ]; then
      echo "[$(date)] Running auto-promote..." >> "$LOG_FILE"
      CLAUDE_PROJECT_DIR="${PROJECT_ROOT:-}" "$PYTHON_CMD" "$PROMOTE_SCRIPT" promote --force >> "$LOG_FILE" 2>&1 || true
    fi
  else
    echo "[$(date)] No new instincts created" >> "$LOG_FILE"
  fi

  # Archive processed observations (Claude read the whole file)
  if [ -f "$OBSERVATIONS_FILE" ]; then
    archive_dir="${PROJECT_DIR}/archive"
    mkdir -p "$archive_dir"
    mv "$OBSERVATIONS_FILE" "$archive_dir/processed-$(date +%Y%m%d-%H%M%S).jsonl" || true
    echo "[$(date)] Observations archived to $archive_dir" >> "$LOG_FILE"
  fi
  ANALYZING=0

  # Exit if graceful stop was requested during analysis
  if [ "$GRACEFUL_EXIT" -eq 1 ]; then
    echo "[$(date)] Graceful stop: analysis complete, exiting" >> "$LOG_FILE"
    cleanup
  fi
}

on_usr1() {
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
  USR1_FIRED=1
  if [ "$ANALYZING" -eq 0 ]; then
    analyze_observations
  fi
}
trap on_usr1 USR1

# Graceful stop: finish current analysis, then exit
on_usr2() {
  echo "[$(date)] Graceful stop requested" >> "$LOG_FILE"
  GRACEFUL_EXIT=1
  # If not analyzing, exit immediately
  if [ "$ANALYZING" -eq 0 ]; then
    cleanup
  fi
  # Otherwise, will exit after analyze_observations completes
}
trap on_usr2 USR2

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
    # Single analysis pass — Claude reads the whole file
    analyze_observations
    _rc=$?

    if [ "$_rc" -eq 1 ]; then
      IDLE_CYCLES=$((IDLE_CYCLES + 1))
      if [ "$IDLE_CYCLES" -ge "$MAX_IDLE_CYCLES" ]; then
        echo "[$(date)] Observer idle for $IDLE_CYCLES cycles, exiting" >> "$LOG_FILE"
        cleanup
      fi
    fi
  fi
done
