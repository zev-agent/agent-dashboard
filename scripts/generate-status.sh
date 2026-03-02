#!/usr/bin/env bash
set -euo pipefail

# generate-status.sh — Collects agent, queue, and PR data into a single status.json
# Run via cron every 1-2 minutes. Uses Python for JSON processing (no jq dependency).

OUTPUT_DIR="$HOME/.config/agent-dashboard"
OUTPUT_FILE="$OUTPUT_DIR/status.json"
AGENT_WATCHER_DIR="$HOME/.config/agent-watcher"
MORDECAI_STATE="$HOME/.config/mordecai-watcher/state.json"
MORDECAI_QUEUE="$HOME/.config/mordecai-watcher/queue.json"
PR_REPO="BOS-Development/pinky.tools"

mkdir -p "$OUTPUT_DIR"

# Fetch PRs
prs_json="[]"
if command -v gh &>/dev/null; then
    prs_json=$(gh pr list --repo "$PR_REPO" --state open \
        --json number,title,state,statusCheckRollup,url,author,createdAt,updatedAt \
        --limit 20 2>/dev/null) || prs_json="[]"
fi

# Use Python to assemble everything
python3 - "$AGENT_WATCHER_DIR" "$MORDECAI_STATE" "$MORDECAI_QUEUE" "$OUTPUT_FILE" "$prs_json" <<'PYEOF'
import sys, os, json, glob, signal
from datetime import datetime, timezone

agent_dir = sys.argv[1]
mordecai_state_path = sys.argv[2]
mordecai_queue_path = sys.argv[3]
output_path = sys.argv[4]
prs_raw = sys.argv[5]

KNOWN_AGENTS = ["mordecai", "signet", "donut", "samantha", "quasar"]

def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError, ValueError):
        return False

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

# --- Agents ---
agents = []
for name in KNOWN_AGENTS:
    path = os.path.join(agent_dir, f"{name}.json")
    data = load_json(path)
    if data:
        pid = data.get("pid")
        status = "running" if pid and pid_alive(pid) else "idle"
        agents.append({
            "name": name,
            "status": status,
            "description": data.get("description"),
            "workdir": data.get("workdir"),
            "started_at": data.get("started_at"),
            "pid": pid,
        })
    else:
        agents.append({
            "name": name,
            "status": "offline",
            "description": None,
            "workdir": None,
            "started_at": None,
            "pid": None,
        })

# --- Mordecai state ---
mordecai_state = load_json(mordecai_state_path)

# --- Queue ---
queue = load_json(mordecai_queue_path) or []

# --- PRs ---
try:
    prs = json.loads(prs_raw)
except Exception:
    prs = []

# --- Assemble ---
output = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "agents": agents,
    "mordecai_state": mordecai_state,
    "queue": queue,
    "prs": prs,
}

with open(output_path, "w") as f:
    json.dump(output, f, indent=2)

print(f"status.json written at {output['generated_at']}")
PYEOF
