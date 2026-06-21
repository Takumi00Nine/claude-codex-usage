# claude-codex-usage

**English** | [日本語](#日本語)

Show **Claude (Anthropic)** and **Codex (OpenAI/ChatGPT)** plan usage in the **tmux status bar**.
A background agent fetches usage every 5 minutes; a tmux segment renders it as colored gauges with a reset countdown.

```text
CL 5h ██████░░ 80% ↻1:51:28  7d ███░░░░░ 43% │ CX 5h ░░░░░░░░ 2% ↻4:12:23  7d ░░░░░░░░ 4%
```

- `CL` = Claude, `CX` = Codex. `5h` = 5-hour window, `7d` = weekly window.
- `↻H:MM:SS` = time until the 5-hour window resets.
- Gauge color: green `<50%`, orange `50–80%`, red `≥80%`.
- **Responsive width**: pass `#{client_width}` to the script (see Setup). When the terminal is narrower than the threshold (default `100` cols, override with `USAGE_NARROW_BELOW`), the gauge bars are dropped — labels and `%` are kept — and the reset countdown switches to total minutes (`↻137m`), so it degrades gracefully instead of being clipped:

  ```text
  CL 5h 80% ↻111m  7d 43% │ CX 5h 2% ↻252m  7d 4%
  ```

## Components

| File | Role |
|---|---|
| `refresh.sh` | Fetches Claude (OAuth usage API) and Codex (`codex app-server`) usage, writes `claude-cache.json` / `codex-cache.json`. Network + **read-only** token use (no quota consumed). |
| `tmux-usage.sh` | Reads the caches and prints a colored tmux status segment. **No network** — cheap to call every second. |
| `com.claude-codex-usage.refresh.plist.example` | LaunchAgent template that runs `refresh.sh all` every 5 minutes (so values advance while idle). |

## How it works

```
launchd (every 5 min) ─▶ refresh.sh ─▶ *-cache.json ─▶ tmux-usage.sh ─▶ tmux status-right
```

`refresh.sh` is the only writer of the caches; `tmux-usage.sh` only reads them. Decoupling the
fetch (slow, network) from the render (fast, local) keeps the status bar instant.

## Requirements
- macOS, `jq`, `curl`, `tmux`
- **Claude**: logged in to Claude Code (OAuth token in the login keychain)
- **Codex**: `codex` CLI reachable on `PATH` (e.g. a version-manager shim dir like `~/.anyenv/envs/nodenv/shims`)

## Setup

### 1. tmux status bar
Add to `~/.tmux.conf` (use the absolute path where you cloned this repo):

```tmux
set -g status-interval 1    # so the ↻ countdown ticks per second
set -g status-right "#(/absolute/path/to/claude-codex-usage/tmux-usage.sh #{client_width}) %H:%M "
```

`#{client_width}` lets the script adapt to the terminal width (see *Responsive width* above).
tmux expands it in the rendering client's context, which is more reliable than calling
`tmux display-message` from inside `#()`. Reload: `tmux source-file ~/.tmux.conf`.

### 2. Background refresh (launchd)
launchd is used (not cron) because the Claude token lives in the keychain, which is TCC-protected:
a per-user LaunchAgent runs in the GUI session and can read it without Full Disk Access; cron cannot.

```sh
cp com.claude-codex-usage.refresh.plist.example ~/Library/LaunchAgents/com.claude-codex-usage.refresh.plist
# edit the file: set refresh.sh's absolute path and a PATH that contains `codex`, `jq`, `curl`
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-codex-usage.refresh.plist
launchctl enable    gui/$(id -u)/com.claude-codex-usage.refresh
launchctl kickstart -k gui/$(id -u)/com.claude-codex-usage.refresh   # run once now
```

## Caveats
- The Claude usage endpoint (`api.anthropic.com/api/oauth/usage`) does **not** consume your token quota, but it has its **own request-rate limit** (HTTP 429). A 5-minute cadence (288/day) is fine; hammering it while debugging will trip 429 (clears in minutes).
- launchd uses a minimal `PATH`; set `PATH` in the plist so `codex` is found.
- Cache files (`*-cache.json`) hold usage data and are git-ignored — do not commit them.

## License
[MIT](LICENSE)

---

## 日本語

**Claude（Anthropic）** と **Codex（OpenAI/ChatGPT）** のプラン使用率を **tmux のステータスバー**に表示するツール。バックグラウンドのエージェントが5分ごとに使用率を取得し、tmux セグメントが色付きゲージ＋リセットまでのカウントダウンで描画する。

```text
CL 5h ██████░░ 80% ↻1:51:28  7d ███░░░░░ 43% │ CX 5h ░░░░░░░░ 2% ↻4:12:23  7d ░░░░░░░░ 4%
```

- `CL`=Claude / `CX`=Codex。`5h`=5時間枠、`7d`=週枠。
- `↻時:分:秒` = 5時間枠がリセットされるまでの残り時間。
- ゲージ色: 緑 `<50%` / 橙 `50〜80%` / 赤 `≥80%`。
- **幅でレスポンシブ**: スクリプトに `#{client_width}` を渡すと（セットアップ参照）、ターミナル幅がしきい値（既定 `100` 列、`USAGE_NARROW_BELOW` で変更可）より狭い時はゲージ棒を省略（ラベルと `%` は維持）し、リセット残りを総分表示（`↻137m`）に切り替える。切り捨てられず崩れにくい:

  ```text
  CL 5h 80% ↻111m  7d 43% │ CX 5h 2% ↻252m  7d 4%
  ```

### 構成
| ファイル | 役割 |
|---|---|
| `refresh.sh` | Claude（OAuth usage API）と Codex（`codex app-server`）の使用率を取得し `claude-cache.json` / `codex-cache.json` に書く。ネット通信あり・トークンは**読み取りのみ**（枠を消費しない）。 |
| `tmux-usage.sh` | キャッシュを読んで色付き tmux セグメントを出力。**通信なし**＝毎秒呼んでも軽い。 |
| `com.claude-codex-usage.refresh.plist.example` | `refresh.sh all` を5分ごとに実行する LaunchAgent テンプレ（アイドル中も値が進む）。 |

### 仕組み
```
launchd（5分毎） ─▶ refresh.sh ─▶ *-cache.json ─▶ tmux-usage.sh ─▶ tmux status-right
```
キャッシュを書くのは `refresh.sh` だけ、読むのは `tmux-usage.sh` だけ。取得（遅い・通信）と描画（速い・ローカル）を分離してバーを即時化している。

### 必要環境
- macOS、`jq`、`curl`、`tmux`
- **Claude**: Claude Code にログイン済み（OAuth トークンがログイン keychain にある）
- **Codex**: `codex` CLI が `PATH` から見える（例: `~/.anyenv/envs/nodenv/shims` のような version-manager の shim ディレクトリ）

### セットアップ
**1. tmux バー**（`~/.tmux.conf` に追記、パスは clone した絶対パスに）:
```tmux
set -g status-interval 1
set -g status-right "#(/absolute/path/to/claude-codex-usage/tmux-usage.sh #{client_width}) %H:%M "
```
`#{client_width}` を渡すとスクリプトがターミナル幅に追従する（上記「幅でレスポンシブ」）。tmux は描画対象クライアントの文脈でこれを展開するため、`#()` の中から `tmux display-message` を呼ぶより確実。反映: `tmux source-file ~/.tmux.conf`。

**2. バックグラウンド取得（launchd）**: cron ではなく launchd を使う。Claude トークンは TCC 保護下の keychain にあり、GUIセッションで動く per-user LaunchAgent なら Full Disk Access なしで読めるが、cron は読めないため。
```sh
cp com.claude-codex-usage.refresh.plist.example ~/Library/LaunchAgents/com.claude-codex-usage.refresh.plist
# 編集: refresh.sh の絶対パスと、codex/jq/curl が通る PATH を設定
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-codex-usage.refresh.plist
launchctl enable    gui/$(id -u)/com.claude-codex-usage.refresh
launchctl kickstart -k gui/$(id -u)/com.claude-codex-usage.refresh
```

### 注意事項
- Claude の usage エンドポイントは**トークン枠を消費しない**が、**リクエスト回数の制限（HTTP 429）が別途ある**。5分間隔（1日288回）は問題ないが、デバッグ時の連打で 429 を踏む（数分で解消）。
- launchd は最小 `PATH`。plist の `PATH` に `codex` の場所を入れること。
- キャッシュ（`*-cache.json`）は使用量データを含むため git 管理外（コミットしない）。

### ライセンス
[MIT](LICENSE)
