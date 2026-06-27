**English** | [日本語](#日本語)

# claude-codex-usage

![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-brightgreen)
![macOS launchd](https://img.shields.io/badge/macOS-launchd-blue)
![Dependencies jq curl tmux codex](https://img.shields.io/badge/dependencies-jq%20%7C%20curl%20%7C%20tmux%20%7C%20codex-informational)

## English

Show **Claude (Anthropic)** and **Codex (OpenAI/ChatGPT)** plan usage in the **tmux status bar**.
A per-user LaunchAgent refreshes usage every 1 minute by default, and the tmux segment renders cached values as colored gauges with reset countdowns.

## Demo

```text
CL 5h ██████░░ 80% ↻1:51:28  7d ███░░░░░ 43% │ CX 5h ░░░░░░░░ 2% ↻4:12:23  7d ░░░░░░░░ 4%
```

- `CL` = Claude, `CX` = Codex. `5h` = 5-hour window, `7d` = weekly window.
- `↻H:MM:SS` = time until the 5-hour window resets.
- Gauge color: green `<50%`, orange `50-79%`, red `>=80%`.
- Responsive width: pass `#{client_width}` to the script. Below `USAGE_NARROW_BELOW` columns, gauge bars are omitted and reset time switches to total minutes:

  ```text
  CL 5h 80% ↻111m  7d 43% │ CX 5h 2% ↻252m  7d 4%
  ```

## Components

| File | Role |
|---|---|
| `refresh.sh` | Fetches Claude and Codex usage, updates caches, and sends notifications. |
| `tmux-usage.sh` | Reads caches and prints the tmux status segment. No network calls. |
| `install.sh` | Creates config/cache/log directories, generates the LaunchAgent plist, loads it, enables it, and kicks the first refresh. |
| `uninstall.sh` | Unloads the LaunchAgent and removes the installed plist. `--purge-cache` also removes caches. |
| `config.example.sh` | Sample user configuration copied to `~/.config/claude-codex-usage/config.sh` by `install.sh`. |
| `test/test.sh` | Shell test suite for cache transforms, notifications, tmux rendering, plist generation, and syntax checks. |

`com.claude-codex-usage.refresh.plist.example` is obsolete; use `install.sh` instead of editing a plist by hand.

## How It Works

```text
launchd (every 1 min) -> refresh.sh -> ~/.cache/claude-codex-usage/*.json -> tmux-usage.sh -> tmux status-right
```

`refresh.sh` is the only process that talks to external services and writes cache files. `tmux-usage.sh` only reads local cache files, so it is cheap to call every second from tmux.

- Config: `~/.config/claude-codex-usage/config.sh`
- Cache: `~/.cache/claude-codex-usage/`
- Log: `~/Library/Logs/claude-codex-usage/refresh.log`
- Claude token: read from the macOS keychain item `Claude Code-credentials`, extracting `claudeAiOauth.accessToken` from its JSON value. `~/.claude/.credentials.json` is used only as a fallback.

## Requirements

- macOS with per-user `launchd`
- `/bin/bash`, `jq`, `curl`, `tmux`, `codex`, `osascript`, `launchctl`
- Claude Code logged in so the OAuth token is available in the login keychain
- Codex CLI installed, authenticated, and reachable on `PATH`
- tmux version that supports `#{client_width}` in formats

## Setup

1. Clone this repository.
2. Install the LaunchAgent:

   ```sh
   ./install.sh
   ```

   The installer creates `~/.config/claude-codex-usage/config.sh` from `config.example.sh` if it does not already exist, generates the plist with absolute paths and a detected `PATH`, loads the job, enables it, and runs one refresh immediately.

3. Add the tmux segment to `~/.tmux.conf`:

   ```tmux
   set -g status-interval 1
   set -g status-right "#(/absolute/path/to/claude-codex-usage/tmux-usage.sh #{client_width}) %H:%M "
   ```

4. Reload tmux:

   ```sh
   tmux source-file ~/.tmux.conf
   ```

To uninstall:

```sh
./uninstall.sh
```

To also remove cached usage and notification state:

```sh
./uninstall.sh --purge-cache
```

## Configuration

Edit `~/.config/claude-codex-usage/config.sh`. If you change `REFRESH_INTERVAL`, run `./install.sh` again because the interval is baked into the generated LaunchAgent plist.

| Variable | Default | Description |
|---|---:|---|
| `REFRESH_INTERVAL` | `60` | Refresh interval in seconds. Must be a multiple of 60. Re-run `install.sh` after changing it. |
| `REQUEST_TIMEOUT` | `15` | Timeout in seconds for one external call. |
| `RETRY_COUNT` | `2` | Additional retry count. Total attempts are `RETRY_COUNT + 1`. |
| `WARN_THRESHOLD` | `80` | High-usage notification threshold in percent. |
| `NOTIFY_THRESHOLD` | `20` | Previous usage must be at least this percent to arm reset notifications. |
| `NOTIFY_FLOOR` | `5` | Current usage at or below this percent is treated as a reset. |
| `NOTIFY_SOUND` | `Ping` | macOS notification sound name. |
| `RESET_HOOK` | `""` | Path to an external script called after a reset notification. |
| `HOOK_TIMEOUT` | `60` | Timeout in seconds for `RESET_HOOK`. |
| `USAGE_NARROW_BELOW` | `100` | Omit gauge bars below this terminal column count. |
| `CELLS` | `8` | Gauge bar width in cells. |
| `STALE_MINUTES` | `10` | Show stale marker after this many minutes. |
| `SLEEP_STALE_MINUTES` | `5` | Cache age threshold used for sleep-resume stale detection. |

## Notifications

- Reset notification: when usage drops to `NOTIFY_FLOOR` or below after the previous usage was `NOTIFY_THRESHOLD` or above, `refresh.sh` sends a macOS notification and then calls `RESET_HOOK` if it is executable.
- High-usage notification: when 5-hour or 7-day usage reaches `WARN_THRESHOLD` or above, `refresh.sh` sends a macOS notification.
- Notifications are tracked per service and per window, so repeated refreshes do not spam the same alert.
- `RESET_HOOK` receives: `<service> <window> <previous_percent> <current_percent>`.

## Caveats

- Claude usage is fetched from `https://api.anthropic.com/api/oauth/usage`. It does not consume model quota, but it can return its own HTTP 429 rate limit. If 1-minute refreshes hit 429 in your environment, raise `REFRESH_INTERVAL` and re-run `install.sh`.
- `launchd` uses a minimal environment; `install.sh` detects command paths and writes a suitable `PATH` into the plist.
- Cache files contain usage data and live outside the repository under `~/.cache/claude-codex-usage/`.
- Do not log or commit tokens. The scripts should only read tokens from keychain or the fallback credentials file.

## License

[MIT](LICENSE)

---

## 日本語

[English](#english) | **日本語**

# claude-codex-usage

![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-brightgreen)
![macOS launchd](https://img.shields.io/badge/macOS-launchd-blue)
![Dependencies jq curl tmux codex](https://img.shields.io/badge/dependencies-jq%20%7C%20curl%20%7C%20tmux%20%7C%20codex-informational)

**Claude（Anthropic）** と **Codex（OpenAI/ChatGPT）** のプラン使用率を **tmux のステータスバー**に表示するツールです。
per-user LaunchAgent が既定で1分ごとに使用率を更新し、tmux セグメントはキャッシュ済みの値を色付きゲージとリセットまでのカウントダウンで描画します。

## デモ表示

```text
CL 5h ██████░░ 80% ↻1:51:28  7d ███░░░░░ 43% │ CX 5h ░░░░░░░░ 2% ↻4:12:23  7d ░░░░░░░░ 4%
```

- `CL` = Claude、`CX` = Codex。`5h` = 5時間枠、`7d` = 週枠です。
- `↻H:MM:SS` = 5時間枠がリセットされるまでの残り時間です。
- ゲージ色: 緑 `<50%`、橙 `50-79%`、赤 `>=80%`。
- 幅でレスポンシブ: スクリプトに `#{client_width}` を渡します。`USAGE_NARROW_BELOW` 未満の列幅ではゲージ棒を省略し、残り時間は総分表示になります。

  ```text
  CL 5h 80% ↻111m  7d 43% │ CX 5h 2% ↻252m  7d 4%
  ```

## 構成ファイル一覧

| ファイル | 役割 |
|---|---|
| `refresh.sh` | Claude と Codex の使用率を取得し、キャッシュ更新と通知送信を行います。 |
| `tmux-usage.sh` | キャッシュを読み、tmux ステータスセグメントを出力します。ネットワーク呼び出しは行いません。 |
| `install.sh` | 設定・キャッシュ・ログディレクトリを作成し、LaunchAgent plist を生成してロード・有効化・初回実行します。 |
| `uninstall.sh` | LaunchAgent を登録解除し、インストール済み plist を削除します。`--purge-cache` でキャッシュも削除します。 |
| `config.example.sh` | `install.sh` により `~/.config/claude-codex-usage/config.sh` へコピーされる設定サンプルです。 |
| `test/test.sh` | キャッシュ変換、通知、tmux 表示、plist 生成、構文確認のシェルテストです。 |

`com.claude-codex-usage.refresh.plist.example` は廃止扱いです。plist を手動編集せず、`install.sh` を使ってください。

## 動作説明

```text
launchd（1分ごと） -> refresh.sh -> ~/.cache/claude-codex-usage/*.json -> tmux-usage.sh -> tmux status-right
```

外部サービスへアクセスしてキャッシュを書くのは `refresh.sh` だけです。`tmux-usage.sh` はローカルキャッシュを読むだけなので、tmux から毎秒呼んでも軽量です。

- 設定: `~/.config/claude-codex-usage/config.sh`
- キャッシュ: `~/.cache/claude-codex-usage/`
- ログ: `~/Library/Logs/claude-codex-usage/refresh.log`
- Claude トークン: macOS キーチェーン項目 `Claude Code-credentials` の JSON 値から `claudeAiOauth.accessToken` を抽出します。`~/.claude/.credentials.json` はフォールバックです。

## 必要環境

- per-user `launchd` が使える macOS
- `/bin/bash`、`jq`、`curl`、`tmux`、`codex`、`osascript`、`launchctl`
- Claude Code にログイン済みで、OAuth トークンがログインキーチェーンにあること
- Codex CLI がインストール・認証済みで、`PATH` から見えること
- tmux フォーマットで `#{client_width}` が使えるバージョン

## セットアップ

1. このリポジトリを clone します。
2. LaunchAgent をインストールします。

   ```sh
   ./install.sh
   ```

   インストーラーは、存在しない場合に `config.example.sh` から `~/.config/claude-codex-usage/config.sh` を作成し、絶対パスと検出済み `PATH` を含む plist を生成し、ジョブをロード・有効化して即時に1回実行します。

3. `~/.tmux.conf` に tmux セグメントを追加します。

   ```tmux
   set -g status-interval 1
   set -g status-right "#(/absolute/path/to/claude-codex-usage/tmux-usage.sh #{client_width}) %H:%M "
   ```

4. tmux 設定を再読み込みします。

   ```sh
   tmux source-file ~/.tmux.conf
   ```

アンインストール:

```sh
./uninstall.sh
```

使用率キャッシュと通知状態も削除する場合:

```sh
./uninstall.sh --purge-cache
```

## 設定パラメータ一覧

`~/.config/claude-codex-usage/config.sh` を編集します。`REFRESH_INTERVAL` を変更した場合は、生成済み LaunchAgent plist に反映するため `./install.sh` を再実行してください。

| 変数 | 既定値 | 説明 |
|---|---:|---|
| `REFRESH_INTERVAL` | `60` | 取得間隔（秒）。60の倍数。変更後は `install.sh` を再実行 |
| `REQUEST_TIMEOUT` | `15` | 外部呼び出し1回のタイムアウト（秒） |
| `RETRY_COUNT` | `2` | 追加リトライ回数（初回含む合計 `RETRY_COUNT + 1` 回） |
| `WARN_THRESHOLD` | `80` | 高使用率通知のしきい値（%） |
| `NOTIFY_THRESHOLD` | `20` | リセット通知の対象となる前回使用率（%） |
| `NOTIFY_FLOOR` | `5` | リセット判定の今回使用率（%） |
| `NOTIFY_SOUND` | `Ping` | 通知サウンド名 |
| `RESET_HOOK` | `""` | リセット通知後に呼ぶ外部スクリプトのパス |
| `HOOK_TIMEOUT` | `60` | `RESET_HOOK` のタイムアウト（秒） |
| `USAGE_NARROW_BELOW` | `100` | この列数未満でゲージ棒を省略 |
| `CELLS` | `8` | ゲージ棒の幅（セル数） |
| `STALE_MINUTES` | `10` | stale 表示のしきい値（分） |
| `SLEEP_STALE_MINUTES` | `5` | スリープ復帰時の stale 判定しきい値（分） |

## 通知機能

- リセット通知: 前回使用率が `NOTIFY_THRESHOLD` 以上で、今回使用率が `NOTIFY_FLOOR` 以下に下がったとき、`refresh.sh` が macOS 通知を送り、その後に実行可能な `RESET_HOOK` を呼びます。
- 高使用率通知: 5時間枠または7日枠の使用率が `WARN_THRESHOLD` 以上になったとき、`refresh.sh` が macOS 通知を送ります。
- 通知状態はサービス別・枠別に記録されるため、同じ状態で通知が連打されません。
- `RESET_HOOK` の引数は `<service> <window> <previous_percent> <current_percent>` です。

## 注意事項

- Claude 使用率は `https://api.anthropic.com/api/oauth/usage` から取得します。モデル利用枠は消費しませんが、このエンドポイント自体の HTTP 429 レート制限はあり得ます。1分間隔で 429 が頻発する環境では `REFRESH_INTERVAL` を上げて `install.sh` を再実行してください。
- `launchd` の環境変数は最小限です。`install.sh` がコマンドの場所を検出し、plist に適切な `PATH` を書き込みます。
- キャッシュファイルは使用率データを含むため、リポジトリ外の `~/.cache/claude-codex-usage/` に保存します。
- トークンをログやコミットに含めないでください。スクリプトはキーチェーンまたはフォールバックの認証情報ファイルから読み取るだけにしてください。

## ライセンス

[MIT](LICENSE)
