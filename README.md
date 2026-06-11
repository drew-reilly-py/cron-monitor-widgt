# Cron Monitor Desktop Widget

A native macOS SwiftUI desktop widget that monitors your user crontab.

It shows every cron entry from `crontab -l`, checks a row only when the matching script process is running, and also shows the last update time for cron log files when the cron line redirects to a log with `>` or `>>`.

## Requirements

- macOS with Swift command-line tools or Xcode installed
- A user crontab

## Build and run once

```sh
bash build-app.sh
open "Cron Monitor Desktop Widget.app"
```

`build-app.sh` embeds the current machine's `crontab -l` output into the binary as a fallback. That keeps rows visible even if macOS GUI app context returns an empty crontab.

## Start automatically at login

```sh
bash install-launch-agent.sh
```

This installs:

```text
~/Library/LaunchAgents/local.codex.cron-monitor-widget.plist
```

The widget starts when you log into macOS. It does not use `KeepAlive`, so quitting it intentionally keeps it closed until next login or manual restart.

## Uninstall

```sh
bash uninstall-launch-agent.sh
```

## Notes

- The header count is `running / total`.
- Fast jobs may finish between polls and remain unchecked. Use the row's `log HH:MM` timestamp to see whether a cron log was updated recently.
- The app polls every 2 seconds and refreshes again after macOS wake.
