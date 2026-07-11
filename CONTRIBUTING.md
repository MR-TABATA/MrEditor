# コントリビューション / Contributing

MrEditor への関心をありがとうございます。Issue も Pull Request も歓迎します。
Thanks for your interest in MrEditor. Issues and pull requests are welcome.

ただし**コアに入れないと決めている領域**があります。良い実装であっても、そこに触れる PR はマージできません。時間を無駄にしていただかないよう、先に線を書いておきます。
There is, however, a set of areas that are **deliberately out of scope for the core**. A pull request that lands in one of them will not be merged, however good the code is. The line is written down here so that nobody spends a weekend on the wrong side of it.

## コアのスコープ / What the core is

MrEditor のコアは **手元のファイルを、大きさに関係なく、開いて・探して・直す** アプリです。開く（10GB でも）、描画する、編集する、atomic に保存する、置換する。開いている文書の中の検索・正規表現・フィルタ表示（live grep）・1ファイルの `tail -f`。構造化表示（CSV/TSV の桁揃え、NDJSON のフィールド投影）。文字コードの自動判定と変換保存、改行コードの扱い。外観（テーマ・フォント・表示設定）、i18n、未保存の下書きの保護とセッション復元、Finder 統合、印刷 / PDF 書き出し。
The core of MrEditor is an app for **opening, searching and fixing the file in front of you — at any size**: open it (even at 10 GB), render it, edit it, save it atomically, replace in it. Search, regex, filtered view (live grep) and `tail -f` within the documents you have open. Structured view (CSV/TSV column alignment, NDJSON field projection). Encoding detection and conversion on save, EOL handling. Appearance (themes, fonts, display settings), i18n, protection of unsaved drafts and session restore, Finder integration, print / PDF export.

これらはすべて MIT で、これからも MIT です。
All of that is MIT licensed, and stays MIT licensed.

## コアのスコープ外 / What the core is not

以下は **MrEditor Pro（別リポジトリ・別ライセンス）** に属します。**コアに対する PR は受け取れません。**
The following belong to **MrEditor Pro** — a separate repository under a separate license. **Pull requests adding them to the core cannot be accepted.**

- **束ねて効かせるもの** — 開いていないファイルまで含めてフォルダを丸ごと横断検索する、複数ファイルを同時に `tail -f` する、一致行を一括で抽出・書き出す、色ルールや検索を**プロファイルとして保存**して次回も勝手に当てる、ログ形式を自動解析する、条件に一致したら通知する。
  **Anything that reaches across everything** — grepping a whole folder including files you never opened, following several files with `tail -f` at once, bulk-exporting matching lines, **saving** colour rules or searches as a profile so they are applied for you next time, parsing log formats automatically, alerting on a match.
  （開いている文書の中の検索・置換、開いているタブを横断する検索は**コアの機能**です。線は「開いているもの」と「フォルダ全体」の間にあります。）
  (Find/replace inside a document, and search across the tabs you already have open, **are core features**. The line runs between "what you have open" and "the whole folder".)
- **認証の向こうにあるリモート** — SSH 越しに本番サーバのログを開く・追う・検索する、リモートの横断検索。
  **Remote behind an authentication boundary** — opening, following and searching logs on a production server over SSH; searching across a remote host.
  （手元のディスクにあるものは、それが何であれ**コアの機能**です。線は手元と、認証を越えた先の間にあります。）
  (Anything sitting on your own disk **is a core feature**, whatever it is. The line runs between local and everything you need credentials to reach.)

一行で言うと: **手元のものを見る・直す = コア / 束ねて効かせる・認証の向こう = Pro。**
In one line: **look at and fix what's in front of you = core; reach across everything, or cross an auth boundary = Pro.**

## なぜ open-core なのか / Why open-core

コアが本物の OSS であることが「open-core」の open です。MrEditor は MIT のままで、それを外すつもりはありません。フォークして自分で足す自由も残ります。
The "open" in open-core means the core is genuinely open source. MrEditor stays MIT, and that is not going to change — including the freedom to fork it and add whatever you want.

無料版を**わざと不便にはしません**。Pro は足すだけで、基本の使い勝手を人質に取りません。10GB を開いて編集して保存する — 看板の機能は無料コアにあり、これからも無料コアにあります。
The free version is **never made deliberately worse**. Pro only adds; it does not hold basic usability hostage. Opening, editing and saving a 10 GB file — the headline feature — is in the free core, and stays there.

守っているのはコードの秘匿性ではなく、Pro 機能の所在です。上の2領域が売り物であり、それがこのアプリの開発を続けられる理由です。
What is being protected is not the secrecy of any code, but where the Pro features live. Those two areas are what is sold, and selling them is what keeps this app being worked on.

## それ以外は歓迎します / Everything else is welcome

バグ修正、パフォーマンス、巨大ファイルの安定性、文字コードの正確さ、エディタの書き味、アクセシビリティ、i18n、外観、テスト、ドキュメント — どれも歓迎です。
Bug fixes, performance, stability at huge sizes, encoding correctness, editor ergonomics, accessibility, i18n, appearance, tests, documentation — all welcome.

大きめの変更を考えている場合は、**先に Issue を立ててください**。手を動かす前に、それがコア側かどうかを一緒に確認できます。
If you are planning something substantial, **open an issue first** — so we can check which side of the line it falls on before you write the code.

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
