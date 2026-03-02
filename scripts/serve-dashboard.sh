#!/usr/bin/env bash
set -euo pipefail

# serve-dashboard.sh — Serves the agent dashboard on port 4001
# Serves public/index.html and symlinks status.json for polling.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PUBLIC_DIR="$PROJECT_DIR/public"
STATUS_SOURCE="$HOME/.config/agent-dashboard/status.json"
STATUS_LINK="$PUBLIC_DIR/status.json"
PORT="${DASHBOARD_PORT:-4001}"

# Ensure status.json exists (generate initial if missing)
if [[ ! -f "$STATUS_SOURCE" ]]; then
    echo "No status.json found — running generate-status.sh first..."
    bash "$SCRIPT_DIR/generate-status.sh"
fi

# Symlink status.json into public dir so the server can serve it
if [[ ! -L "$STATUS_LINK" ]]; then
    ln -sf "$STATUS_SOURCE" "$STATUS_LINK"
fi

echo "Dashboard: http://localhost:$PORT"
echo "Serving from: $PUBLIC_DIR"
echo "Press Ctrl+C to stop."

cd "$PUBLIC_DIR"
python3 -m http.server "$PORT" --bind 0.0.0.0
