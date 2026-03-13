#!/usr/bin/env python3
"""Parse Claude CLI JSON output: extract instincts from result + write token stats.

Called from observer-loop.sh. Reads JSON from stdin.

Env vars:
  STATS_FILE        - path to token-stats.jsonl
  OBS_COUNT         - number of observations analyzed
  PROJECT_NAME_ENV  - project name
  PROJECT_ID_ENV    - project id
  INSTINCTS_DIR     - directory for project-scoped instincts
  HOMUNCULUS_DIR    - root instinctor directory
"""

import json, sys, os, re, glob
from datetime import datetime, timezone


def extract_and_save_instincts(result_text, instincts_dir, instinctor_dir):
    """Parse result text, extract instinct blocks, save as .md files."""
    if not result_text or "NO_PATTERNS_FOUND" in result_text:
        return 0, 0

    # Split by separator if present, otherwise try to split by frontmatter blocks
    if "===INSTINCT_SEPARATOR===" in result_text:
        chunks = result_text.split("===INSTINCT_SEPARATOR===")
    else:
        # Fallback: split on --- that starts a new frontmatter block
        chunks = re.split(r"(?:^|\n)(?=---\s*\nid:\s)", result_text)

    created = 0
    updated = 0
    # Characters to strip from YAML values: double quote, single quote, zero-width space
    strip_chars = '"' + chr(39) + '\u200b'

    for chunk in chunks:
        chunk = chunk.strip()
        if not chunk:
            continue

        # Extract YAML frontmatter (may have preamble text before ---)
        fm_match = re.search(r"^---\s*\n(.*?)\n---\s*\n?(.*)", chunk, re.DOTALL | re.MULTILINE)
        if not fm_match:
            continue

        frontmatter_text = fm_match.group(1)
        body = fm_match.group(2).strip()

        # Extract id from frontmatter
        id_match = re.search(r"^id:\s*(.+)$", frontmatter_text, re.MULTILINE)
        if not id_match:
            continue

        instinct_id = id_match.group(1).strip().strip(strip_chars)

        # Validate id: only allow kebab-case alphanumeric
        if not re.match(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$", instinct_id) and not re.match(r"^[a-z0-9]$", instinct_id):
            print(f"[instincts] Skipping invalid id: {instinct_id}")
            continue

        # Security: prevent path traversal
        if "/" in instinct_id or "\\" in instinct_id or ".." in instinct_id:
            print(f"[instincts] Skipping suspicious id: {instinct_id}")
            continue

        # Determine target directory based on scope
        scope_match = re.search(r"^scope:\s*(.+)$", frontmatter_text, re.MULTILINE)
        scope = scope_match.group(1).strip().strip(strip_chars) if scope_match else "project"

        if scope == "global":
            target_dir = os.path.join(instinctor_dir, "instincts", "personal")
        else:
            target_dir = instincts_dir

        os.makedirs(target_dir, exist_ok=True)

        file_path = os.path.join(target_dir, f"{instinct_id}.md")
        full_content = f"---\n{frontmatter_text}\n---\n\n{body}\n"

        is_update = os.path.exists(file_path)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(full_content)

        if is_update:
            updated += 1
        else:
            created += 1

        label = "Updated" if is_update else "Created"
        print(f"[instincts] {label} ({scope}): {file_path}")

    return created, updated


def main():
    try:
        data = json.load(sys.stdin)
        result = data.get("result", "")

        # 1. Extract and save instincts from result
        instincts_dir = os.environ.get("INSTINCTS_DIR", "")
        instinctor_dir = os.environ.get("HOMUNCULUS_DIR", os.path.expanduser("~/.claude/instinctor"))
        created, updated = 0, 0
        if result and instincts_dir:
            created, updated = extract_and_save_instincts(result, instincts_dir, instinctor_dir)
            print(f"[instincts] Total: {created} created, {updated} updated")
        elif result:
            print(result)

        # 2. Write token stats
        usage = data.get("usage", {})
        stats = {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "cache_read_tokens": usage.get("cache_read_input_tokens", 0),
            "cost_usd": data.get("cost_usd", 0),
            "duration_ms": data.get("duration_ms", 0),
            "num_turns": data.get("num_turns", 0),
            "observations_analyzed": int(os.environ.get("OBS_COUNT", "0")),
            "instincts_created": created,
            "instincts_updated": updated,
            "project_name": os.environ.get("PROJECT_NAME_ENV", ""),
            "project_id": os.environ.get("PROJECT_ID_ENV", "")
        }

        stats_file = os.environ.get("STATS_FILE", "")
        if stats_file:
            with open(stats_file, "a") as f:
                f.write(json.dumps(stats) + "\n")

        in_t = stats["input_tokens"]
        out_t = stats["output_tokens"]
        cost = stats["cost_usd"]
        print(f"[tokens] in={in_t} out={out_t} total={in_t+out_t} cost=${cost:.4f}")

        # 3. Update global cache for statusLine (sum all projects)
        instinctor = os.path.expanduser("~/.claude/instinctor")
        total = 0
        for sf in glob.glob(os.path.join(instinctor, "projects/*/token-stats.jsonl")):
            with open(sf) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        r = json.loads(line)
                        total += r.get("input_tokens", 0) + r.get("output_tokens", 0)
                    except (json.JSONDecodeError, KeyError):
                        continue
        cache_path = os.path.join(instinctor, ".obs-total")
        with open(cache_path, "w") as cf:
            cf.write(str(total))
    except Exception as e:
        print(f"Stats parse error: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
