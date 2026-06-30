#!/bin/bash

# claude-codex-usage configuration.
# Copy to ~/.config/claude-codex-usage/config.sh and edit as needed.
# Environment variables take precedence over values set here.

# LaunchAgent refresh interval in seconds. Must be 60 or a multiple of 60.
# Re-run install.sh after changing this value because it is baked into the plist.
REFRESH_INTERVAL="${REFRESH_INTERVAL:-60}"

# Timeout in seconds for one external request or command invocation.
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-15}"

# Additional retry count after the first attempt. 2 means 3 total attempts.
RETRY_COUNT="${RETRY_COUNT:-2}"

# High-usage notification threshold, in percent.
WARN_THRESHOLD="${WARN_THRESHOLD:-80}"

# Reset notification requires the previous usage to be at least this percent.
NOTIFY_THRESHOLD="${NOTIFY_THRESHOLD:-20}"

# Reset notification fires when current usage is at or below this percent.
NOTIFY_FLOOR="${NOTIFY_FLOOR:-5}"

# macOS notification sound name passed to osascript.
NOTIFY_SOUND="${NOTIFY_SOUND:-Ping}"

# Optional executable hook called after reset notification:
#   $RESET_HOOK <service> <window> <previous_percent> <current_percent>
RESET_HOOK="${RESET_HOOK:-}"

# Timeout in seconds for RESET_HOOK.
HOOK_TIMEOUT="${HOOK_TIMEOUT:-60}"

# tmux width below which gauge bars are omitted.
USAGE_NARROW_BELOW="${USAGE_NARROW_BELOW:-100}"

# Gauge bar width in cells for wide tmux display.
CELLS="${CELLS:-8}"

# Show stale marker when fetched_at is older than this many minutes.
STALE_MINUTES="${STALE_MINUTES:-10}"
