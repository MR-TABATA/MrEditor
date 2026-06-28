# MrEditor

[English](README.md) | **日本語**

**10GB のテキストを、落ちずに開く Mac ネイティブのビューア。**

10GB のログ ―― **86,420,337 行** ―― を開いても、表示が始まるまで **約 210ms**、
実メモリのフットプリントは **44MB**。末尾の行へのジャンプは **0.1ms** です。

> v0.1 は **ビューア**（読み取り専用）です。編集・検索・ハイライトは v0.2 以降。
> 名前（MrEditor）は野望です。

## なぜ作るのか

macOS でテキストを表示する定番は `NSTextView` ですが、内部の `NSTextStorage` に
**全文を保持**します。10GB を渡すと破綻する。そこで MrEditor は巨大ログビューア
（klogg / glogg / lnav）の定石を採ります。

- ファイルは **mmap**。全文をメモリに乗せない。
- **疎な行インデックス**を持つ（2,000 行ごとに 1 つのバイトオフセット → 1 億行でも約 400KB）。
- **見えている行だけ** Core Text で描く。スクロールは「行」単位の自前 `NSScroller` で表現し、
  16 億ポイントの巨大ビュー（float 精度の崖）を作らない。

設計の詳細は [docs/ARCHITECTURE_v0.1.md](docs/ARCHITECTURE_v0.1.md) を参照してください。

## 機能（v0.1）

- 任意サイズの巨大テキストを開ける（10GB で検証済み）。表示開始はほぼ一瞬。
- 文字コードの自動判定：**UTF-8 / Shift-JIS / EUC-JP**（実ファイルで確認済み）。
- 行単位の自前スクローラとキーボード操作（矢印・ページ・Home/End）。
- ステータスバー：文字コード・行数・ファイルサイズ・背景索引の進捗。
- UI は **日本語と英語にローカライズ**（システム言語に追従）。

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

- **v0.1 — ビューア** ✅（このリリース）
- **v0.2 以降** — 検索 / grep、編集、シンタックスハイライト、文字コード手動切替、横スクロール

## v0.1 で「作らない」と決めたこと

編集・保存・検索・ハイライト・サイドバー/タブ・設定・行の折り返し。
読み取り専用の mmap 設計がビューアを速くしている一方で、それは 10GB の編集を
別の（もっと難しい）問題にします。そこは後で正面から取り組みます。

## ライセンス

[MIT](LICENSE) © 2026 TABATA Hitoshi
