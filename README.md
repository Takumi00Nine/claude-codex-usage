# Claude and Codex Usage Statusline

A lightweight Claude Code status line that shows Claude (Anthropic) and Codex (OpenAI/ChatGPT) plan usage.

```text
🤖 Opus │ ✳️ Claude ▏█████░░░░░ 51% ↻2h13m (週 6%) │ ⬢ Codex ▏█░░░░░░░░░ 6% ↻4h44m (週 14%)
```

The label `週` means "weekly": the bar and reset timer show the five-hour window, while the percentage in parentheses shows weekly usage.

## Features

- Shows each five-hour allowance as a bar, percentage, and time until reset
- Shows weekly usage as a compact percentage in parentheses
- Colors usage green through 50%, yellow through 80%, and red above 80%
- Displays both Claude and Codex plan usage in one status line
- Keeps rendering lightweight and non-blocking by refreshing slow data in the background

## Requirements

- macOS
- Bash
- [`jq`](https://jqlang.github.io/jq/)
- `curl`
- [Codex CLI](https://github.com/openai/codex), installed and signed in
- Claude Code, signed in to a Pro or Max plan

This tool currently requires macOS because it reads Claude credentials from Keychain and uses BSD `date -j`. Linux support requires adjustments to credential lookup and date parsing.

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/your-user/usage-statusline.git
   cd usage-statusline
   ```

2. Make the scripts executable:

   ```bash
   chmod +x *.sh
   ```

3. Add a `statusLine` entry to `~/.claude/settings.json`. Set `command` to the absolute path where you cloned the repository:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/absolute/path/to/usage-statusline/statusline.sh",
       "padding": 0
     }
   }
   ```

Merge the `statusLine` key into your existing settings object if the file already contains other settings. The first render may show `--` until the background refresh finishes.

## How It Works

`statusline.sh` is called by Claude Code and always returns quickly. It prefers Claude usage data supplied directly in statusline stdin:

- `rate_limits.five_hour.used_percentage`
- `rate_limits.five_hour.resets_at` as an epoch timestamp
- `rate_limits.seven_day.used_percentage`

When that data is unavailable, `refresh.sh` falls back to the unofficial Claude OAuth usage endpoint:

```text
https://api.anthropic.com/api/oauth/usage
```

The Claude OAuth token is read from macOS Keychain first, then from `~/.claude/.credentials.json`. The response is stored in `claude-cache.json`.

For Codex, `refresh.sh` starts `codex app-server` in the background and sends the JSON-RPC method `account/rateLimits/read`. Its response is stored in `codex-cache.json`.

Caches have a five-minute TTL. Refreshes use `flock` when available and an atomic `mkdir` lock on standard macOS installations. Statusline rendering never waits for network or app-server refreshes.

## Caveats

- The Claude OAuth endpoint and Codex app-server JSON-RPC method are unofficial and undocumented. Updates to either CLI may break this tool without notice.
- Claude usage targets Pro/Max subscriptions. Codex usage targets the rate limits associated with a ChatGPT subscription.
- Cache files contain plan and usage data. They are excluded from Git by `.gitignore` and should not be committed.

## Troubleshooting

### Values stay at `--`

Confirm that Claude Code and Codex CLI are signed in. The relevant unofficial endpoint or JSON-RPC response may also have changed.

### Colors do not appear

Confirm that your terminal and Claude Code status line render ANSI color escape sequences. Also verify that the reported values are numeric percentages.

### Codex values are stale

Codex data refreshes only after the status line runs and notices a missing or expired cache. Render the status line again, or run:

```bash
/absolute/path/to/usage-statusline/refresh.sh codex
```

## License

MIT. See [LICENSE](LICENSE).

Before publishing, replace `<YOUR NAME>` in `LICENSE` with your name or GitHub handle.
