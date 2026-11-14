# コントリビューション / Contributing

MrEditor への関心をありがとうございます。Issue も Pull Request も歓迎します。
Thanks for your interest in MrEditor. Issues and pull requests are welcome.

## スコープ / Scope

MrEditor は **手元のファイルを、大きさに関係なく、開いて・探して・直す** アプリです。開く（10GB でも）、描画する、編集する、atomic に保存する、置換する。開いている文書の中の検索・正規表現・フィルタ表示（live grep）・1ファイルの `tail -f`。`ssh host:/path` で**リモートのファイルを1本開いて見る**こと。構造化表示（CSV/TSV の桁揃え、NDJSON のフィールド投影）。文字コードの自動判定と変換保存、改行コードの扱い。外観（テーマ・フォント・表示設定）、i18n、未保存の下書きの保護とセッション復元、Finder 統合、印刷 / PDF 書き出し。
MrEditor is an app for **opening, searching and fixing the file in front of you — at any size**: open it (even at 10 GB), render it, edit it, save it atomically, replace in it. Search, regex, filtered view (live grep) and `tail -f` within the documents you have open. Opening **a single remote file** with `ssh host:/path`. Structured view (CSV/TSV column alignment, NDJSON field projection). Encoding detection and conversion on save, EOL handling. Appearance (themes, fonts, display settings), i18n, protection of unsaved drafts and session restore, Finder integration, print / PDF export.

MIT で、**全機能が 1 つのリポジトリにあります。** 有償版も、機能の出し分けもありません。どの機能にも PR を歓迎します。
MIT licensed, and **every feature lives in this one repository.** There is no paid edition and no feature gating. Pull requests are welcome on any part of it.

## 歓迎するもの / What is welcome

バグ修正、パフォーマンス、巨大ファイルの安定性、文字コードの正確さ、エディタの書き味、アクセシビリティ、i18n、外観、テスト、ドキュメント — どれも歓迎です。
Bug fixes, performance, stability at huge sizes, encoding correctness, editor ergonomics, accessibility, i18n, appearance, tests, documentation — all welcome.

大きめの変更を考えている場合は、**先に Issue を立ててください**。手を動かす前に、方向が合っているかを一緒に確認できます。
If you are planning something substantial, **open an issue first** — so we can check the direction together before you write the code.

## 開発 / Development

セットアップとビルドは [README](README.md) を参照してください。PR の前に:
See the [README](README.md) for setup and build. Before opening a pull request:

```bash
swift build
swift test
sh scripts/make_app.sh debug     # .app を作って実機で確認 / build the .app and check it for real
```

巨大ファイルに触れる変更は、**実際に巨大なファイルで確認してください**。単体テストは通るのに 10GB で破綻する、はこのプロジェクトで最も起きやすい失敗です。
If your change touches how huge files are handled, **verify it on an actually huge file**. Passing the unit tests while falling over at 10 GB is the most likely way to be wrong in this project.
