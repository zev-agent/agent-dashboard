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
PR_REPOS=(
    "BOS-Development/pinky.tools"
    "zev-agent/agent-dashboard"
    "zev-agent/agent-ops"
    "zev-agent/tool-github-poller"
    "zev-agent/tool-github-webhook-proxy"
    "zev-agent/tool-ci-triage"
    "zev-agent/claude-usage-scraper"
)

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

# Read Anthropic admin key (if available)
ADMIN_KEY_FILE="$HOME/.config/agent-dashboard/.anthropic-admin-key"
ANTHROPIC_ADMIN_KEY=""
if [ -f "$ADMIN_KEY_FILE" ]; then
    ANTHROPIC_ADMIN_KEY=$(cat "$ADMIN_KEY_FILE" | tr -d '[:space:]')
fi

# Use Python to assemble everything
python3 - "$AGENT_WATCHER_DIR" "$MORDECAI_STATE" "$MORDECAI_QUEUE" "$OUTPUT_FILE" "$prs_json" "$ANTHROPIC_ADMIN_KEY" "$CLAUDE_USAGE_FILE" <<'PYEOF'
import sys, os, json, glob, signal
from datetime import datetime, timezone, timedelta

agent_dir = sys.argv[1]
mordecai_state_path = sys.argv[2]
mordecai_queue_path = sys.argv[3]
output_path = sys.argv[4]
prs_raw = sys.argv[5]
admin_key = sys.argv[6] if len(sys.argv) > 6 else ""
claude_usage_path = sys.argv[7] if len(sys.argv) > 7 else ""

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

# --- Usage & Cost (Anthropic Admin API) ---
usage = None
if admin_key:
    try:
        import urllib.request, urllib.error
        now = datetime.now(timezone.utc)
        today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        week_start = today_start - timedelta(days=7)
        headers = {
            "x-api-key": admin_key,
            "anthropic-version": "2023-06-01",
        }

        def api_get(url):
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode())

        # Today's usage
        usage_today_url = (
            "https://api.anthropic.com/v1/organizations/usage_report/messages"
            f"?starting_at={today_start.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            f"&ending_at={now.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            "&bucket_width=1d"
        )
        today_data = api_get(usage_today_url)
        today_input = sum(b.get("input_tokens", 0) for b in today_data.get("data", []))
        today_output = sum(b.get("output_tokens", 0) for b in today_data.get("data", []))

        # Weekly usage
        usage_week_url = (
            "https://api.anthropic.com/v1/organizations/usage_report/messages"
            f"?starting_at={week_start.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            f"&ending_at={now.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            "&bucket_width=1d"
        )
        week_data = api_get(usage_week_url)
        week_input = sum(b.get("input_tokens", 0) for b in week_data.get("data", []))
        week_output = sum(b.get("output_tokens", 0) for b in week_data.get("data", []))

        # Today's cost
        cost_today_url = (
            "https://api.anthropic.com/v1/organizations/cost_report"
            f"?starting_at={today_start.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            f"&ending_at={now.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            "&bucket_width=1d"
        )
        cost_today_data = api_get(cost_today_url)
        cost_today_usd = sum(
            float(b.get("cost_usd", 0)) for b in cost_today_data.get("data", [])
        )

        # Weekly cost
        cost_week_url = (
            "https://api.anthropic.com/v1/organizations/cost_report"
            f"?starting_at={week_start.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            f"&ending_at={now.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            "&bucket_width=1d"
        )
        cost_week_data = api_get(cost_week_url)
        cost_week_usd = sum(
            float(b.get("cost_usd", 0)) for b in cost_week_data.get("data", [])
        )

        usage = {
            "today": {"input_tokens": today_input, "output_tokens": today_output},
            "week": {"input_tokens": week_input, "output_tokens": week_output},
            "cost_today_usd": round(cost_today_usd, 2),
            "cost_week_usd": round(cost_week_usd, 2),
        }
        print(f"Usage data fetched: today ${cost_today_usd:.2f}, week ${cost_week_usd:.2f}")
    except Exception as e:
        print(f"Usage fetch skipped: {e}", file=sys.stderr)
        usage = None

# --- Claude Max Usage (from scraper) ---
claude_max = None
if claude_usage_path and os.path.exists(claude_usage_path):
    try:
        claude_max = load_json(claude_usage_path)
        if claude_max:
            print(f"Claude Max usage loaded (fetched {claude_max.get('fetched_at', 'unknown')})")
    except Exception as e:
        print(f"Claude Max usage load failed: {e}", file=sys.stderr)

# --- Assemble ---
output = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "agents": agents,
    "mordecai_state": mordecai_state,
    "queue": queue,
    "prs": prs,
}
if usage:
    output["usage"] = usage
if claude_max:
    output["claude_max"] = claude_max

with open(output_path, "w") as f:
    json.dump(output, f, indent=2)

print(f"status.json written at {output['generated_at']}")
PYEOF
