# Instinctor — Continuous Learning for Claude Code

A learning system that turns your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions into reusable knowledge through atomic **instincts** — small learned behaviors with confidence scoring.

Claude Code observes how you work, detects patterns, and creates instincts that are automatically injected into future sessions. Project-scoped instincts prevent cross-project contamination: React patterns stay in React, Python conventions stay in Python.

Inspired by the instinct system from [Everything Claude Code](https://github.com/affaan-m/everything-claude-code). Extracted, rewritten and extended as a standalone lightweight tool.

## How it works

```
Session → Hooks capture tool use → Observer analyzes patterns → Instincts created
                                                                      ↓
Next session ← Instincts injected into context ← Auto-promote to global if universal
```

1. **Observe** — PreToolUse/PostToolUse hooks capture every tool call (Read, Edit, Bash, etc.)
2. **Analyze** — Background observer batches observations, sends to Claude Haiku for pattern detection
3. **Create** — Patterns with 3+ occurrences become instincts with confidence scores (0.3–0.85)
4. **Inject** — On next session start, relevant instincts are injected into Claude's context
5. **Promote** — Instincts found in 2+ projects with high confidence auto-promote to global scope

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/Zrslll/instinctor.git
cd instinctor
```

### 2. Link skill into Claude Code

```bash
# Create hardlinks (recommended — changes sync both ways)
mkdir -p ~/.claude/skills/continuous-learning-v2
cp -al skill/* ~/.claude/skills/continuous-learning-v2/

# Or symlink
ln -s "$(pwd)/skill" ~/.claude/skills/continuous-learning-v2
```

### 3. Create data directory

```bash
mkdir -p ~/.claude/instinctor/instincts/personal
```

### 4. Register hooks in `~/.claude/settings.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/skills/continuous-learning-v2/hooks/observe.sh pre"
          },
          {
            "type": "command",
            "command": "bash $HOME/.claude/skills/continuous-learning-v2/hooks/inject-instincts.sh"
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
            "command": "bash $HOME/.claude/skills/continuous-learning-v2/hooks/observe.sh post"
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
            "command": "bash $HOME/.claude/skills/continuous-learning-v2/agents/start-observer.sh stop 2>/dev/null"
          }
        ]
      }
    ]
  }
}
```

### 5. (Optional) Add statusLine

```json
{
  "statusLine": {
    "type": "command",
    "command": "input=$(cat); obs=''; if [ -f \"$HOME/.claude/instinctor/.obs-total\" ]; then t=$(cat \"$HOME/.claude/instinctor/.obs-total\" 2>/dev/null); if [ -n \"$t\" ] && [ \"$t\" -gt 0 ] 2>/dev/null; then if [ \"$t\" -ge 1000 ]; then obs=$(awk \"BEGIN{printf \\\" obs:%.1fk\\\", $t/1000}\"); else obs=\" obs:${t}\"; fi; fi; fi; gc=0; pc=0; gd=\"$HOME/.claude/instinctor/instincts/personal\"; if [ -d \"$gd\" ]; then for f in \"$gd\"/*.md \"$gd\"/*.yaml; do [ -f \"$f\" ] && gc=$((gc+1)); done; fi; for pd in \"$HOME/.claude/instinctor/projects\"/*/instincts/personal; do if [ -d \"$pd\" ]; then for f in \"$pd\"/*.md \"$pd\"/*.yaml; do [ -f \"$f\" ] && pc=$((pc+1)); done; fi; done; printf \"instincts:%sg+%sp%s\" \"$gc\" \"$pc\" \"$obs\""
  }
}
```

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- Python 3.8+
- `jq` (for statusLine, optional)
- Git (for project detection)

## Project structure

```
instinctor/
├── skill/                          # Claude Code skill (link to ~/.claude/skills/)
│   ├── SKILL.md                    # Detailed skill documentation
│   ├── config.json                 # Configuration (observer interval, inject settings)
│   ├── agents/
│   │   ├── observer-loop.sh        # Background analysis loop
│   │   ├── observer.md             # Observer agent prompt
│   │   └── start-observer.sh       # Observer lifecycle management
│   ├── hooks/
│   │   ├── observe.sh              # PreToolUse/PostToolUse observation hook
│   │   └── inject-instincts.sh     # Session instinct injection hook
│   └── scripts/
│       ├── inject-instincts.py     # Collects and formats instincts for injection
│       ├── instinct-cli.py         # CLI: status, import, export, promote, evolve
│       ├── detect-project.sh       # Project detection (git remote hash)
│       ├── parse-observer-output.py # Parses Claude output into instinct files
│       └── test_parse_instinct.py  # Tests
└── data/                           # Runtime data (gitignored, auto-created)
    ├── instincts/personal/         # Global instincts
    ├── projects/<hash>/            # Per-project observations & instincts
    ├── observations.jsonl          # Current observation buffer
    └── projects.json               # Project registry
```

## Instinct format

```yaml
---
id: grep-before-read
trigger: when locating function definitions in large files
confidence: 0.7
domain: workflow
scope: project          # or "global"
project_id: 1c3b9c15e467
---

# Grep Before Read

## Action
Use grep -n to find line numbers before using Read with offset.

## Evidence
- Observed 4 times in session abc123
- Pattern: grep → Read with offset
```

## CLI usage

```bash
# View all instincts
python3 skill/scripts/instinct-cli.py status

# List projects
python3 skill/scripts/instinct-cli.py projects

# Promote project instincts to global (auto-detect candidates)
python3 skill/scripts/instinct-cli.py promote --force

# Dry run promotion
python3 skill/scripts/instinct-cli.py promote --dry-run

# Export instincts
python3 skill/scripts/instinct-cli.py export -o instincts-backup.yaml
```

## Configuration

Edit `skill/config.json`:

```json
{
  "version": "2.2",
  "observer": {
    "enabled": true,
    "run_interval_minutes": 5,
    "min_observations_to_analyze": 20
  },
  "inject": {
    "enabled": true,
    "min_confidence": 0.5
  }
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `observer.enabled` | `true` | Enable background observation analysis |
| `observer.run_interval_minutes` | `5` | How often observer checks for new observations |
| `observer.min_observations_to_analyze` | `20` | Minimum observations before triggering analysis |
| `inject.enabled` | `true` | Enable instinct injection into sessions |
| `inject.min_confidence` | `0.5` | Minimum confidence threshold for injection |

## How promotion works

When the same instinct appears in 2+ projects with average confidence >= 0.8, it qualifies for auto-promotion to global scope. This happens automatically after the observer creates new instincts.

Examples:
- "Always validate input before processing" — universal, promotes to global
- "Use BLoC pattern for state management" — project-specific, stays local

## License

[MIT](LICENSE)
