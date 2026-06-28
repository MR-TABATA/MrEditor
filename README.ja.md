# MrEditor

[English](README.md) | **日本語**

**10GB のテキストを、落ちずに開く Mac ネイティブのビューア。**

10GB のログ ―― **86,420,337 行** ―― を開いても、表示が始まるまで **約 210ms**、
実メモリのフットプリントは **44MB**。末尾の行へのジャンプは **0.1ms** です。

> **読み取り専用**のビューアですが、中身は本格的: 全文検索・フィルタ表示（live grep）・
> `tail -f` 付き。編集はしません（名前は野望。理由は末尾に）。

## なぜ作るのか

macOS でテキストを表示する定番は `NSTextView` ですが、内部の `NSTextStorage` に
**全文を保持**します。10GB を渡すと破綻する。そこで MrEditor は巨大ログビューア
（klogg / glogg / lnav）の定石を採ります。

- ファイルは **mmap**。全文をメモリに乗せない。
- **疎な行インデックス**を持つ（2,000 行ごとに 1 つのバイトオフセット → 1 億行でも約 400KB）。
- **見えている行だけ** Core Text で描く。スクロールは「行」単位の自前 `NSScroller` で表現し、
  16 億ポイントの巨大ビュー（float 精度の崖）を作らない。

設計の詳細は [docs/ARCHITECTURE_v0.1.md](docs/ARCHITECTURE_v0.1.md) を参照してください。

## 機能（v0.2）

**表示**
- 任意サイズの巨大テキストを開ける（10GB で検証済み）。表示開始はほぼ一瞬。
- 文字コードの自動判定：**UTF-8 / Shift-JIS / EUC-JP**（実ファイルで確認済み）。
- 行単位の自前スクローラとキーボード操作（矢印・ページ・Home/End）。
- **末尾追従（`tail -f`・⌥⌘F）** — ファイルが伸びると自動スクロール。索引は増分拡張。
- 可視範囲のコピー（⌘C）。ステータスバー：文字コード・行数・サイズ・索引進捗。

**検索**（⌘F）— mmap をストリーム走査。ファイルを読み込まない
- 可視行の即時ハイライト＋背景の全文走査で正確な件数（一致行は上限100万）。
- **複数語 AND**（スペース区切り）と**正規表現**（`.*` トグル）。
- 次/前へ移動して各一致行へジャンプ。
- **フィルタ表示 / live grep** — 一致行だけ表示（実行番号は保持）。

UI は **日本語と英語にローカライズ**（システム言語に追従）。

## インストール

[Releases](../../releases) から `MrEditor-<バージョン>.dmg` をダウンロードして開き、
**MrEditor** を Applications にドラッグします。

このアプリは **コード署名・公証をしていません**（Apple Developer ID 未取得）。そのため
初回起動時に Gatekeeper に弾かれます。開くには次のいずれか:

- MrEditor を右クリック →「**開く**」→ ダイアログで「**開く**」、または
- `xattr -dr com.apple.quarantine /Applications/MrEditor.app`

あるいは下記のソースからのビルドでも動きます。

## ビルドと実行

macOS 13 以降と Swift ツールチェーン（Xcode 15+）が必要です。

```sh
swift build
sh scripts/make_app.sh debug          # バイナリを MrEditor.app に包む
open .build/MrEditor.app --args "/path/to/big.log"
```

テストデータの生成（`testdata/` は git 管理外）：

```sh
python3 scripts/gen_testdata.py --encoding-set --out-dir testdata/   # UTF-8 / SJIS / EUC サンプル
python3 scripts/gen_testdata.py --size 10G --jp --out testdata/test_10gb.log
```

配布用ディスクイメージ（`.build/MrEditor-0.2.dmg`）の作成:

```sh
sh scripts/make_dmg.sh
```

## 性能（2026-06-27 実測 / 10.00GB・86,420,337 行・日本語 UTF-8）

| 指標 | 結果 |
|---|---|
| 表示開始まで（first paint） | 約 210ms |
| 全索引の構築（背景・表示はブロックしない） | 約 20 秒 |
| 末尾行へのシーク | 0.1ms |
| 実メモリフットプリント | 44MB（ピーク 119MB） |

索引構築中の `ps` の RSS は約 3.8GB まで増えますが、これは破棄可能な
ファイルバックドの mmap キャッシュであり、アプリの常駐メモリではありません。
本当に効く数字（`Physical footprint`）は 44MB のままです。

## ロードマップ

- **v0.1 — ビューア** ✅
- **v0.2 — 検索・複数語AND・正規表現・フィルタ表示（live grep）・`tail -f`・コピー** ✅（このリリース）
- **以降** — シンタックス/ログのハイライト、その他の分析ツール

## まだ「作らない」もの（意図的に）

編集・保存。読み取り専用の mmap 設計がビューアを速くしている一方で、それは 10GB の編集を
別の（もっと難しい）問題にします。MrEditor は根っこが**速いリーダー**です。

## ライセンス

[MIT](LICENSE) © 2026 TABATA Hitoshi
