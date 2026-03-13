#!/usr/bin/env python3
"""
Inject instincts into Claude Code session context.

Reads hook JSON from stdin (cwd, session_id), collects relevant instincts
(global + project-scoped), and outputs a compact summary for prompt injection.

Caches output per session_id to avoid repeated injection.
"""

import json
import hashlib
import os
import re
import sys
from pathlib import Path

HOMUNCULUS_DIR = Path.home() / ".claude" / "instinctor"
PROJECTS_DIR = HOMUNCULUS_DIR / "projects"
REGISTRY_FILE = HOMUNCULUS_DIR / "projects.json"
GLOBAL_PERSONAL_DIR = HOMUNCULUS_DIR / "instincts" / "personal"
CACHE_DIR = HOMUNCULUS_DIR / ".inject-cache"

# Config defaults
DEFAULT_MIN_CONFIDENCE = 0.5


def load_config() -> dict:
    config_path = Path(__file__).parent.parent / "config.json"
    try:
        with open(config_path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def detect_project_id(cwd: str) -> str | None:
    """Derive project_id from cwd using same logic as detect-project.sh."""
    if not cwd or not os.path.isdir(cwd):
        return None

    # Try git remote URL first
    import subprocess
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode != 0:
            return None
        project_root = result.stdout.strip()

        result = subprocess.run(
            ["git", "-C", project_root, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            remote_url = result.stdout.strip()
            # Strip credentials
            remote_url = re.sub(r'://[^@]+@', '://', remote_url)
            return hashlib.sha256(remote_url.encode()).hexdigest()[:12]

        # Fallback to path hash
        return hashlib.sha256(project_root.encode()).hexdigest()[:12]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def parse_instinct_file(path: Path) -> dict | None:
    """Parse an instinct .md/.yaml file, extracting frontmatter fields."""
    try:
        text = path.read_text()
    except OSError:
        return None

    # Parse YAML frontmatter
    match = re.match(r'^---\s*\n(.*?)\n---\s*\n(.*)', text, re.DOTALL)
    if not match:
        return None

    frontmatter_text = match.group(1)
    body = match.group(2).strip()

    data = {}
    for line in frontmatter_text.split('\n'):
        m = re.match(r'^(\w[\w_-]*)\s*:\s*(.+)$', line)
        if m:
            key = m.group(1)
            val = m.group(2).strip().strip('"').strip("'")
            if key == 'confidence':
                try:
                    val = float(val)
                except ValueError:
                    val = 0.5
            data[key] = val

    data['_body'] = body
    data['_file'] = str(path)
    return data


def collect_instincts(project_id: str | None, min_confidence: float) -> tuple[list, list]:
    """Collect global and project instincts above min_confidence.

    Returns (global_instincts, project_instincts).
    """
    global_instincts = []
    project_instincts = []

    # Global instincts
    if GLOBAL_PERSONAL_DIR.is_dir():
        for f in sorted(GLOBAL_PERSONAL_DIR.iterdir()):
            if f.suffix in ('.md', '.yaml', '.yml'):
                inst = parse_instinct_file(f)
                if inst and inst.get('confidence', 0.5) >= min_confidence:
                    global_instincts.append(inst)

    # Project instincts
    if project_id:
        project_personal = PROJECTS_DIR / project_id / "instincts" / "personal"
        if project_personal.is_dir():
            for f in sorted(project_personal.iterdir()):
                if f.suffix in ('.md', '.yaml', '.yml'):
                    inst = parse_instinct_file(f)
                    if inst and inst.get('confidence', 0.5) >= min_confidence:
                        project_instincts.append(inst)

    # Sort by confidence DESC
    global_instincts.sort(key=lambda x: x.get('confidence', 0.5), reverse=True)
    project_instincts.sort(key=lambda x: x.get('confidence', 0.5), reverse=True)

    return global_instincts, project_instincts


def format_instinct_line(inst: dict) -> str:
    """Format a single instinct as a compact one-liner."""
    trigger = inst.get('trigger', 'unknown')
    # Extract action from body (first sentence after ## Action)
    action = ''
    body = inst.get('_body', '')
    action_match = re.search(r'## Action\s*\n(.+?)(?:\n\n|\n##|$)', body, re.DOTALL)
    if action_match:
        action = action_match.group(1).strip().split('\n')[0]
    else:
        action = body.split('\n')[0] if body else ''

    conf = inst.get('confidence', 0.5)
    conf_pct = int(conf * 100)
    return f"- {trigger}: {action} ({conf_pct}%)"


def format_output(global_instincts: list, project_instincts: list, project_name: str) -> str:
    """Format instincts into compact injection text."""
    if not global_instincts and not project_instincts:
        return ""

    lines = ["# Learned Instincts"]

    if global_instincts:
        lines.append("")
        lines.append("## Global")
        for inst in global_instincts:
            lines.append(format_instinct_line(inst))

    if project_instincts:
        lines.append("")
        lines.append(f"## Project: {project_name}")
        for inst in project_instincts:
            lines.append(format_instinct_line(inst))

    output = '\n'.join(lines)

    # Estimate tokens (~4 chars per token)
    est_tokens = len(output) // 4
    lines.append("")
    lines.append(f"<!-- ~{est_tokens} tokens -->")

    return '\n'.join(lines)


def get_project_name(project_id: str | None) -> str:
    """Get project name from registry."""
    if not project_id:
        return "unknown"
    try:
        with open(REGISTRY_FILE) as f:
            registry = json.load(f)
        return registry.get(project_id, {}).get('name', project_id)
    except (FileNotFoundError, json.JSONDecodeError):
        return project_id


def main():
    # Read stdin
    try:
        input_data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    cwd = input_data.get('cwd', '')
    session_id = input_data.get('session_id', '')

    if not session_id:
        sys.exit(0)

    # Check cache — already injected for this session?
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file = CACHE_DIR / f".inject-{session_id}"
    if cache_file.exists():
        # Already injected this session
        sys.exit(0)

    # Load config
    config = load_config()
    inject_config = config.get('inject', {})

    if not inject_config.get('enabled', True):
        sys.exit(0)

    min_confidence = inject_config.get('min_confidence', DEFAULT_MIN_CONFIDENCE)

    # Detect project
    project_id = detect_project_id(cwd)
    project_name = get_project_name(project_id)

    # Collect instincts
    global_instincts, project_instincts = collect_instincts(project_id, min_confidence)

    # Format output
    output = format_output(global_instincts, project_instincts, project_name)

    if output:
        # Write cache marker
        cache_file.write_text(session_id)
        # Output to stdout for prompt injection
        print(output)


if __name__ == '__main__':
    main()
