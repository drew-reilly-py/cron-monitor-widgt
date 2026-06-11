#!/usr/bin/env bash
set -euo pipefail

LABEL="local.codex.cron-monitor-widget"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_VALUE="$(id -u)"

launchctl bootout "gui/$UID_VALUE" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "Uninstalled $LABEL"
