# AGENTS.md — この repo での作業方法

> **この repository は git ではなく Sinfo (`sf`) でバージョン管理されています。**
> モジュールのコードを編集したら `sf vup <module> -c "..."` で記録してください。
> バージョン管理に `git commit` / `git push` は **使わないでください** — Sinfo のモジュールを追跡しません。

Sinfo はファイル単位ではなく **モジュール**（機能の単位）でコードをバージョン管理します。
マージコンフリクトは構造的に発生せず、AI エージェントがモジュールを並列に編集できます。

## git → sf 対応表

| git でやること | この repo (sf) | 意味 |
|---|---|---|
| `git commit` | `sf vup <module> -c "..."` | モジュールの新バージョンを記録 |
| ビルドの確定 | `sf snap create` | モジュールバージョンの組み合わせを確定 |
| `git tag` / release | `sf snap release vX.Y.Z` | スナップショットを tag / release |
| 追跡ファイル | **モジュール** | バージョン管理の単位 |
| import / 依存 | `dependsOn` | モジュールの宣言依存 |

## 黄金律

**モジュールを変えたら `sf vup`。** これが commit に相当します。

## コマンド早見表

- `sf status` — 全モジュールの変更を検知
- `sf vup <module> -c "..."` — モジュールをバージョンアップ（≈ commit）
- `sf module list` — このプロジェクトのモジュール一覧
- `sf snap create` — 現在のモジュールバージョンの組み合わせを確定
- `sf snap release vX.Y.Z` — スナップショットを tag / release
- `sf write snap <id> --dest <dir>` — スナップショットをディレクトリに展開
- `sf push` / `sf pull` — リモート hub と同期

## このプロジェクトのモジュール

固定のモジュール一覧を仮定しないでください。現在のモジュールは以下で確認します:

```
sf module list      # 存在するモジュール
sf status           # 未コミットの変更があるモジュール
```

## モジュールの割り方（粒度）

- **1 モジュール = 独立に version / 並列作業 / release したい単位。**
- 割る基準: ①2エージェントが同時に別部分を編集する ②独自の release ペースがある
  ③公開 API と内部の境界。
- **crate 単位・ファイル単位で割らない。** 小さい crate は 1 モジュール。**迷ったら少なく** —
  後で割るのは安い: `sf module paths move --from <a> --to <b> "<glob>"`。

## 追跡モデル（allowlist — 安全既定）

- file は **どれかのモジュールの paths にマッチした時だけ追跡**される。勝手に取り込まれない。
- paths は段階的に追加: `sf module paths add <module> "<glob>"`。
- **フォルダ = shallow。** `src` → `src/*`（直下のみ）。サブフォルダも含めるなら `src/**`。
- `sf status -c` で **orphan**（どのモジュールにも属さない file）を一覧＝「登録忘れ」検知。
  `sf module paths add` で登録。

## 例: 空から最初の version まで

```
sf status -c                          # 未追跡(orphan) file を一覧
sf module create web -p "app/**"      # app/ 全体を追跡するモジュール (recursive)
sf module create api -p "src/api"     # src/api/* だけ追跡 (shallow, 直下のみ)
sf module paths add api "src/lib.rs"  # api にパスを1本追加
# ...コード編集...
sf vup web -c "initial web"           # version を記録 (= commit)
sf status                             # 未 version の取りこぼしが無いか確認
```

## さらに詳しく

- `docs/ja/guide/ai-parallel.md` — AI 並列開発モデル
- `docs/ja/guide/daily-workflow.md` — 日常のワークフロー
- `docs/ja/reference/cli.md` — CLI リファレンス
