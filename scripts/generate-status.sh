#!/usr/bin/env bash
set -euo pipefail

# generate-status.sh — Collects agent, queue, and PR data into a single status.json
# Run via cron every 1-2 minutes. Uses Python for JSON processing (no jq dependency).

OUTPUT_DIR="$HOME/.config/agent-dashboard"
OUTPUT_FILE="$OUTPUT_DIR/status.json"
CLAUDE_USAGE_FILE="$OUTPUT_DIR/claude-usage.json"
AGENT_WATCHER_DIR="$HOME/.config/agent-watcher"
MORDECAI_STATE="$HOME/.config/mordecai-watcher/state.json"
MORDECAI_QUEUE="$HOME/.config/mordecai-watcher/queue.json"
TASK_TRACKER="$HOME/.config/task-tracker/active-tasks.json"
PR_REPO="BOS-Development/pinky.tools"

mkdir -p "$OUTPUT_DIR"

# Fetch PRs from all tracked repos
prs_json="[]"
if command -v gh &>/dev/null; then
    all_prs="["
    first=true
    for repo in "${PR_REPOS[@]}"; do
        repo_prs=$(gh pr list --repo "$repo" --state open \
            --json number,title,state,statusCheckRollup,url,author,createdAt,updatedAt \
            --limit 20 2>/dev/null) || repo_prs="[]"
        # Add repo field to each PR and append to combined list
        tagged=$(python3 -c "
import json, sys
prs = json.loads(sys.argv[1])
for pr in prs:
    pr['repo'] = sys.argv[2]
print(json.dumps(prs))
" "$repo_prs" "$repo" 2>/dev/null) || tagged="[]"
        # Strip brackets and append
        inner=$(echo "$tagged" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d)[1:-1])")
        if [ -n "$inner" ]; then
            if [ "$first" = true ]; then
                all_prs+="$inner"
                first=false
            else
                all_prs+=",$inner"
            fi
        fi
    done
    all_prs+="]"
    prs_json="$all_prs"
fi

# Use Python to assemble everything
python3 - "$AGENT_WATCHER_DIR" "$MORDECAI_STATE" "$MORDECAI_QUEUE" "$OUTPUT_FILE" "$prs_json" "$TASK_TRACKER" <<'PYEOF'
import sys, os, json, glob, signal
from datetime import datetime, timezone, timedelta

agent_dir = sys.argv[1]
mordecai_state_path = sys.argv[2]
mordecai_queue_path = sys.argv[3]
output_path = sys.argv[4]
prs_raw = sys.argv[5]
task_tracker_path = sys.argv[6] if len(sys.argv) > 7 else ""

KNOWN_AGENTS = ["mordecai", "signet", "donut", "samantha", "quasar"]

# --- API Cache ---
USAGE_CACHE_FILE = os.path.join(os.path.expanduser("~"), ".config", "agent-dashboard", "usage-cache.json")
USAGE_CACHE_MAX_AGE = 900  # 15 minutes

def load_usage_cache():
    if os.path.exists(USAGE_CACHE_FILE):
        try:
            with open(USAGE_CACHE_FILE, "r") as f:
                cache = json.load(f)
            cached_at = datetime.fromisoformat(cache.get("cached_at", "1970-01-01T00:00:00+00:00"))
            age = (datetime.now(timezone.utc) - cached_at).total_seconds()
            if age < USAGE_CACHE_MAX_AGE:
                return cache.get("data")
        except:
            pass
    return None

def save_usage_cache(data):
    cache = {
        "cached_at": datetime.now(timezone.utc).isoformat(),
        "data": data
    }
    os.makedirs(os.path.dirname(USAGE_CACHE_FILE), exist_ok=True)
    with open(USAGE_CACHE_FILE, "w") as f:
        json.dump(cache, f)


AGENT_ROLES = {
    "mordecai": "Engineering",
    "signet": "Ops & Infrastructure",
    "donut": "Product Vision",
    "samantha": "Observability",
    "quasar": "Security",
    "zev": "Coordinator",
}

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
            "role": AGENT_ROLES.get(name, ""),
            "status": status,
            "description": data.get("description"),
            "workdir": data.get("workdir"),
            "started_at": data.get("started_at"),
            "pid": pid,
        })
    else:
        agents.append({
            "name": name,
            "role": AGENT_ROLES.get(name, ""),
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


# --- Active Tasks ---
active_tasks = []
if task_tracker_path and os.path.exists(task_tracker_path):
    task_data = load_json(task_tracker_path)
    if task_data and "tasks" in task_data:
        stale_threshold = timedelta(hours=2)
        current_time = datetime.now(timezone.utc)
        for t in task_data["tasks"]:
            if t.get("status") == "active":
                spawned = datetime.strptime(t["spawned_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                task_age = current_time - spawned
                pid = t.get("pid")
                pid_ok = pid_alive(pid) if pid else False
                status = "stale" if (task_age > stale_threshold and not pid_ok) else "active"
                active_tasks.append({**t, "status": status})
            elif t.get("status") == "stale":
                active_tasks.append(t)

# --- Assemble ---
output = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "agents": agents,
    "mordecai_state": mordecai_state,
    "queue": queue,
    "prs": prs,
    "active_tasks": active_tasks,
}

# --- Claude Max usage (from scraper) ---
claude_usage_path = os.path.join(os.path.expanduser("~"), ".config", "agent-dashboard", "claude-usage.json")
claude_data = load_json(claude_usage_path)
if claude_data:
    output["claude_max"] = claude_data

with open(output_path, "w") as f:
    json.dump(output, f, indent=2)

print(f"status.json written at {output['generated_at']}")
PYEOF
