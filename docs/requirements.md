# 要件定義書 — claude-codex-usage リビルド

> ステータス: **Implemented**（リビルド実装済み。README と実装に合わせて更新）
> 作成: 2026-06-28

> **⚠️ 実装方針**: 既存コードへの後方互換性は不要。現在の構造・ファイル名・インターフェースに縛られず、要件に対して最適な設計で完全に作り直してよい。

---

## 1. 背景・目的

Claude と Codex の使用率（5時間枠・週枠）を tmux のステータスバーにリアルタイムで表示する。
初版は試作的に実装したため、今回はゼロから設計し直す。

### 解決したいこと
- 使用率が逼迫しているときに一目でわかる
- tmux を開いている間は常に最新値が見える（アイドル中も自動更新）
- Claude Pro / Codex ChatGPT Plus どちらも同じ画面で確認できる

---

## 2. 旧版の問題点（リビルドで解消済み）

| # | 問題 | 影響 |
|---|---|---|
| P1 | キャッシュファイルがリポジトリ直下（`$BASE_DIR/*.json`） | git-ignore 必須、clone 場所に依存 |
| P2 | LaunchAgent の plist に絶対パスを手書きする必要がある | セットアップが煩雑・ミスしやすい |
| P3 | plist の Label 名が example と実際にインストールしたもので不一致 | 管理が混乱する |
| P4 | ロック機構に `flock` + mkdir フォールバックの二重実装 | 複雑・macOS でほぼ mkdir しか使わない |
| P5 | Codex 取得に `sleep 6` で決め打ち待機 | 遅い・タイミングによっては取りこぼす |
| P6 | 失敗時にキャッシュが古いまま残り、ユーザーに伝わらない | 古い値を正しい値と誤認する |
| P7 | インストール・アンインストール手順が手作業のみ | 再セットアップが辛い |
| P8 | テストなし | リグレッションを検出できない |

---

## 3. スコープ

### In scope（リビルド対象）
- データ取得スクリプト（`refresh.sh` 相当）のリビルド
- tmux 描画スクリプト（`tmux-usage.sh` 相当）のリビルド
- LaunchAgent のインストール・アンインストール自動化
- キャッシュ置き場所の整理
- エラー状態の表示
- セットアップ手順の簡略化（1コマンド化）

### Out of scope
- Claude / Codex 以外のサービスへの対応
- tmux 以外の表示先（例: zsh プロンプト、iTerm2 等）
- GUI 設定画面

---

## 4. 機能要件

### FR-1: データ取得

| ID | 要件 |
|---|---|
| FR-1-1 | Claude の使用率（5時間枠・週枠・リセット時刻）を OAuth API から取得する |
| FR-1-2 | Codex の使用率（5時間枠・週枠・リセット時刻）を `codex app-server` から取得する |
| FR-1-3 | 取得結果をキャッシュファイルに原子的（atomic write）に書き込む |
| FR-1-4 | 同一対象に対して同時実行が重複しないようロック制御する |
| FR-1-5 | 取得失敗時は usage 値を含むキャッシュを破壊しない（古い usage 値を維持する） |
| FR-1-6 | 取得失敗時はキャッシュ内の `last_error` フィールドのみ更新する（usage 値は上書きしない） |
| FR-1-7-a | 取得**成功**時は `last_error` フィールドを削除または `null` にクリアする（成功後に `ERR` 表示が残らないようにする） |
| FR-1-7 | `refresh.sh claude` / `refresh.sh codex` / `refresh.sh all` の3モードをサポートする |
| FR-1-8 | 全外部呼び出しにタイムアウトを設ける。Claude API・Codex app-server・osascript は `REQUEST_TIMEOUT` 秒、`RESET_HOOK` は `HOOK_TIMEOUT` 秒（既定60秒）で別途制限する |
| FR-1-9 | 取得失敗時は初回試行の後 `RETRY_COUNT` 回追加で再試行する（例: `RETRY_COUNT=2` なら合計3回試行）。429 の場合は追加リトライせず、その他のリトライ対象失敗は 1 秒固定バックオフを適用する |

### FR-2: tmux 描画

| ID | 要件 |
|---|---|
| FR-2-1 | `CL` (Claude) と `CX` (Codex) の使用率をゲージ＋パーセントで表示する |
| FR-2-2 | 表示する枠は 5時間枠（`5h`）と週枠（`7d`）の2つ |
| FR-2-3 | 5時間枠のリセットまでの残り時間（`↻H:MM:SS`）を表示する |
| FR-2-4 | 利用率に応じてゲージを色分けする（緑 <50% / 橙 50–80% / 赤 ≥80%） |
| FR-2-5 | ターミナル幅が狭い場合（既定: 100列未満）はゲージバーを省略し、% と残り時間（`↻NNm`）のみ表示する |
| FR-2-6 | キャッシュが存在しない場合は `n/a` を表示する |
| FR-2-7 | キャッシュが古い（既定: 10分超）場合は経過時間を表示する（例: `(15分前)`） |
| FR-2-8 | 取得エラーが記録されている場合はエラー状態を示す表示をする（例: `ERR`） |
| FR-2-9 | ネットワーク接続なし・純粋にキャッシュ読み取りのみで動作する（毎秒呼ばれても軽い） |

### FR-3: LaunchAgent（バックグラウンド定期取得）

| ID | 要件 |
|---|---|
| FR-3-1 | macOS launchd の per-user LaunchAgent として動作する |
| FR-3-2 | **1分ごと**に `refresh.sh all` を実行する（既定: 1分） |
| FR-3-2-a | LaunchAgent は `StartCalendarInterval`（毎分）を使う。スリープ中に逃した実行を復帰後に coalesce して動かす副作用を利用し、FR-8 のスリープ復帰対応を兼ねる |
| FR-3-2-b | `REFRESH_INTERVAL` による間隔変更は**分単位**（60の倍数）に制約する。変更後は `install.sh` の再実行が必要 |
| FR-3-3 | ロード時に即時1回実行する（`RunAtLoad`） |
| FR-3-4 | `codex`・`jq`・`curl` が見つかる PATH を plist に設定する |
| FR-3-5 | 429・タイムアウト等の失敗時の再試行・バックオフは FR-1-8/1-9 に準じる（Claude・Codex 両方） |

### FR-4: インストール・アンインストール

| ID | 要件 |
|---|---|
| FR-4-1 | `install.sh` 1スクリプトでセットアップを完結させる（plist の手動編集は不要） |
| FR-4-2 | install.sh は plist に絶対パスと PATH を自動で書き込む |
| FR-4-3 | install.sh は LaunchAgent のロード・有効化・初回キックも行う |
| FR-4-4 | `uninstall.sh` でクリーンに削除できる（LaunchAgent の unload + plist 削除） |
| FR-4-5 | install.sh は依存コマンド（`jq`・`curl`・`codex`）の有無を事前チェックして欠けていたら案内する |

### FR-5: リセット通知

| ID | 要件 |
|---|---|
| FR-5-1 | 5時間枠の利用率がリセットされてゼロ（または低水準）に戻ったとき、macOS 通知を発火する |
| FR-5-2 | Claude と Codex それぞれ独立して通知する（片方だけリセットされた場合も個別に通知） |
| FR-5-3 | 通知にはサービス名・前の利用率・リセット後の利用率を含める（例: `Claude リセット: 78% → 0%`） |
| FR-5-4 | 通知にはサウンドを付ける（既定: `Ping`。別作業中でも気づけるように） |
| FR-5-5 | macOS 標準の `osascript` で通知する（追加サービス・アプリ不要） |
| FR-5-6 | iPhone への通知転送は Handoff / 同一 Apple ID の macOS 標準動作に委ねる（追加実装なし） |
| FR-5-7 | 通知は `refresh.sh` の実行タイミングで判定する（tmux-usage.sh では判定しない） |
| FR-5-8 | リセット検知後は通知済みフラグを残し、次回の `refresh.sh` 実行で二重通知しない |
| FR-5-10 | 通知済みフラグは「利用率が `NOTIFY_THRESHOLD` 以上に再上昇したとき」に解除する。解除後は次のリセットで再度通知できる状態に戻る |
| FR-5-9 | リセット検知時に実行する外部スクリプトを設定できる（post-reset hook）。スクリプトパスを環境変数 `RESET_HOOK` で指定し、存在すれば通知後に呼び出す。hook 内で何をするかはこのツールの関知しない範囲とする |

#### リセット判定ロジック（案）

```
前回キャッシュの利用率 >= NOTIFY_THRESHOLD（既定: 20%）
  かつ
今回取得した利用率 < NOTIFY_FLOOR（既定: 5%）
  → リセット通知を発火
```

- `NOTIFY_THRESHOLD` / `NOTIFY_FLOOR` は環境変数で上書き可能とする
- 「ゼロになった」ではなく「閾値以下に落ちた」で判定する理由: API の返す値が厳密に 0% にならないケースに対応するため

### FR-6: 高使用率しきい値通知

| ID | 要件 |
|---|---|
| FR-6-1 | 5時間枠・週枠の利用率が設定したしきい値を超えたとき、macOS 通知を発火する |
| FR-6-2 | Claude と Codex それぞれ独立して通知する |
| FR-6-3 | 通知にはサービス名・枠の種類・現在の利用率を含める（例: `Claude 5h枠 警告: 82%`） |
| FR-6-4 | しきい値は環境変数 `WARN_THRESHOLD`（既定: 80%）で設定可能とする |
| FR-6-5 | 一度通知したら利用率が閾値を下回るまで再通知しない（連打防止） |
| FR-6-6 | リセット通知（FR-5）と同じく `refresh.sh` の実行タイミングで判定する |

### FR-7: 週枠リセット通知

| ID | 要件 |
|---|---|
| FR-7-1 | 7日枠の利用率がリセットされて低水準に戻ったとき、macOS 通知を発火する |
| FR-7-2 | Claude と Codex それぞれ独立して通知する |
| FR-7-3 | 通知内容・判定ロジック・二重通知防止は FR-5（5時間枠リセット通知）に準じる |
| FR-7-4 | post-reset hook（FR-5-9）は週枠リセット時にも呼び出す |

### FR-8: スリープ復帰後の即時更新

| ID | 要件 |
|---|---|
| FR-8-1 | スリープ復帰後は launchd の coalesce 発火で `refresh.sh all` を起動し、通常の毎回 fetch により即時更新する |
| FR-8-2 | 復帰検知は launchd の `StartCalendarInterval` を使い、スリープ中に逃した実行を復帰後に1回まとめて動かす方式とする（bash のみ・追加インストール不要）。`IOKitPowerStateMonitor` 等の非公式キーは使わない |
| FR-8-3 | `refresh.sh` は単一エントリポイントとして起動のたびに fetch する。別閾値は持たず、`SLEEP_STALE_MINUTES` は廃止する |
| FR-8-4 | 更新完了まで tmux-usage.sh はキャッシュ鮮度表示（FR-2-7）で古い値であることを示す |

### FR-9: 設定ファイル

| ID | 要件 |
|---|---|
| FR-9-1 | ユーザー設定は `~/.config/claude-codex-usage/config.sh` に集約する（XDG準拠・リポジトリ外） |
| FR-9-2 | 設定ファイルはシェル変数形式（`KEY=value`）とし、各スクリプトが起動時に source する |
| FR-9-3 | 設定ファイルが存在しない場合はすべてデフォルト値で動作する（設定必須項目ゼロ） |
| FR-9-4 | `install.sh` がサンプル設定（`config.example.sh`）をリポジトリから設定ディレクトリへコピーする |
| FR-9-5 | 以下の全パラメーターを設定ファイルで変更できる |

#### 設定可能パラメーター一覧

| 変数名 | 既定値 | 説明 |
|---|---|---|
| `REFRESH_INTERVAL` | `60` | LaunchAgent の取得間隔（秒）。60の倍数。変更後は `install.sh` の再実行が必要 |
| `REQUEST_TIMEOUT` | `15` | 外部呼び出し1回あたりのタイムアウト（秒） |
| `RETRY_COUNT` | `2` | 追加リトライ回数（初回含む合計 `RETRY_COUNT + 1` 回、429 は追加リトライなし） |
| `WARN_THRESHOLD` | `80` | 高使用率通知のしきい値（%） |
| `NOTIFY_THRESHOLD` | `20` | リセット検知：前回利用率の下限（%、これ以上なら通知対象） |
| `NOTIFY_FLOOR` | `5` | リセット検知：今回利用率の上限（%、これ以下ならリセット判定） |
| `NOTIFY_SOUND` | `Ping` | 通知サウンド名（`osascript` に渡す macOS サウンド名） |
| `RESET_HOOK` | _(空)_ | リセット検知時に呼び出す外部スクリプトのパス（FR-5-9） |
| `HOOK_TIMEOUT` | `60` | `RESET_HOOK` 実行のタイムアウト（秒）。hook が重い処理をする場合に引き上げる |
| `USAGE_NARROW_BELOW` | `100` | tmux 幅がこの値未満でゲージバーを省略（列数） |
| `CELLS` | `8` | ゲージバーの幅（文字数） |
| `STALE_MINUTES` | `10` | キャッシュがこの分数を超えたら古さ表示（FR-2-7） |

`STALE_MINUTES` は表示上の stale マーカー閾値であり、取得可否の判定には使わない。FR-8 は毎回 fetch する `refresh.sh all` と launchd の wake coalesce 発火で満たすため、旧 `SLEEP_STALE_MINUTES` は廃止済み。

---

## 5. 非機能要件

| ID | 要件 |
|---|---|
| NFR-1 | tmux-usage.sh は 100ms 以内に完了する（毎秒呼ばれるため） |
| NFR-2 | キャッシュファイルは `~/.cache/claude-codex-usage/` に置く（リポジトリ外・XDG準拠） |
| NFR-3 | LaunchAgent の Label は `com.claude-codex-usage.refresh` に統一する |
| NFR-4 | シェルスクリプト（bash）のみで実装する（Python・Node.js 等の追加ランタイム不要） |
| NFR-5 | `refresh.sh` のロック機構は macOS 向けに `mkdir` ロックのみとしシンプルに保つ |
| NFR-6 | キャッシュファイルはリポジトリに含めない（`.gitignore` で除外） |
| NFR-7 | ログは `~/Library/Logs/claude-codex-usage/refresh.log` に出力する（macOS 常駐ツールの標準パス） |

---

## 6. ファイル構成

```
claude-codex-usage/
├── refresh.sh           # データ取得・キャッシュ書き込み・通知
├── tmux-usage.sh        # tmux セグメント描画（read-only）
├── install.sh           # セットアップ自動化
├── uninstall.sh         # クリーンアップ
├── config.example.sh    # 設定ファイルのサンプル（install.sh がコピー）
├── docs/
│   ├── requirements.md  （本ファイル）
│   └── design.md        （詳細設計・実装後に作成）
├── test/
│   └── test.sh          # 動作確認スクリプト
├── .gitignore
├── LICENSE
└── README.md
```

ユーザー設定・キャッシュ（リポジトリ外）:
```
~/.config/claude-codex-usage/
└── config.sh            # ユーザー設定（install.sh が config.example.sh からコピー）

~/.cache/claude-codex-usage/
├── claude-cache.json    # Claude 使用率キャッシュ
├── codex-cache.json     # Codex 使用率キャッシュ
└── notify-state.json    # 通知済みフラグ・前回値
```

LaunchAgent（`install.sh` により生成。手動編集不要）:
```
~/Library/LaunchAgents/com.claude-codex-usage.refresh.plist
```

---

## 7. 制約・前提条件

- **OS**: macOS のみ（launchd・keychain 依存）
- **必須コマンド**: `bash`・`jq`・`curl`・`codex`（PATH 上に存在すること）
- **Claude 認証**: Claude Code の OAuth トークンがログイン keychain に保存されていること
- **Codex 認証**: `codex` CLI が認証済みであること
- **tmux バージョン**: `#{client_width}` が使えるバージョン（2.3+）
- **Claude usage API**: 非公式エンドポイント（`api.anthropic.com/api/oauth/usage`）のため仕様変更リスクあり。公式の制限値は非公開。429 時は追加リトライせず次回更新まで待ち、デフォルト1分間隔が安全かは実運用で確認（U8）
- **Codex app-server**: `codex app-server` の JSON-RPC レスポンスの形式に依存

---

## 8. 未決事項（要確認）

| # | 事項 | 確認方法 |
|---|---|---|
| U1 | Codex の `app-server` の待機時間を `sleep 6` 以外にできるか（タイムアウト等） | 解決済み: JSON-RPC 応答監視とタイムアウトで実装 |
| U2 | エラー状態のキャッシュ構造（`error` フィールド追加 vs 別ファイル） | 解決済み: 各キャッシュの `last_error` に集約 |
| U3 | `install.sh` で PATH を自動検出するか、ユーザーに入力させるか | 解決済み: 自動検出 |
| U4 | テストの範囲（unit相当のシェルテスト vs 手動チェックリストのみ） | 解決済み: `test/test.sh` にシェルテストを集約 |
| U5 | `NOTIFY_THRESHOLD` / `NOTIFY_FLOOR` のデフォルト値（20% / 5%）が適切か | 実運用で確認 |
| U6 | 通知済みフラグは `notify-state.json` に分離することで確定（ファイル構成に反映済み）。内部スキーマは設計書で確定 |
| U7 | Handoff 経由で iPhone への通知が実際に届くか | 実装後に実機確認 |
| U8 | 1分間隔（1日1440回）で Claude usage API が 429 を返さないか | 実装後に1週間程度の実運用で確認。429 頻発なら `REFRESH_INTERVAL` を上げる |
| U9 | `notify-state.json` の内部スキーマ（フィールド名・型・前回値の持ち方） | 解決済み: 設計書 3.4 に記載 |
| U10 | macOS `/bin/bash` は 3.2系。連想配列など 4.0+ 機能は使わない前提を設計全体で守れるか | 解決済み: bash 3.2 互換で実装 |
