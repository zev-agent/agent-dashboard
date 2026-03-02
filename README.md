# Agent Dashboard

Local web dashboard for monitoring agent status, task queue, and PR checks.

Dark theme (Neocom Dark) — polls `status.json` every 7 seconds — no auth required.

## Quick Start

```bash
# 1. Generate initial status data
./scripts/generate-status.sh

# 2. Start the dashboard on port 4001
./scripts/serve-dashboard.sh
```

Open **http://localhost:4001** in a browser.

## Architecture

```
generate-status.sh  →  ~/.config/agent-dashboard/status.json
                                    ↑
serve-dashboard.sh  →  symlinks into public/  →  index.html polls it
```

### Data Sources

| Source | Path |
|--------|------|
| Running agents | `~/.config/agent-watcher/*.json` |
| Mordecai state | `~/.config/mordecai-watcher/state.json` |
| Task queue | `~/.config/mordecai-watcher/queue.json` |
| Open PRs | `gh pr list --repo BOS-Development/pinky.tools` |

### Dashboard Views

- **Agent Status** — all 5 agents with status, current task, runtime, last update
- **Task Queue** — active/queued items, collapsible completed section
- **PR Tracker** — open PRs with CI check status

## Systemd Setup (optional)

```bash
# Install service + timer as user units
cp agent-dashboard.service ~/.config/systemd/user/
cp agent-dashboard-generator.service ~/.config/systemd/user/
cp agent-dashboard-generator.timer ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now agent-dashboard.service
systemctl --user enable --now agent-dashboard-generator.timer
```

## Cron Alternative

```bash
# Add to crontab (crontab -e)
* * * * * /path/to/agent-dashboard/scripts/generate-status.sh
```

## Config

| Env Var | Default | Description |
|---------|---------|-------------|
| `DASHBOARD_PORT` | `4001` | Server port |
