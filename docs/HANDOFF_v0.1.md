# MrEditor v0.1 引継書

最終更新: 2026-06-26

## 1. これは何か

Mac ネイティブの巨大ファイルビューア（v0.1 はビューア専用、編集なし）。
**10GB のテキストを落ちずに表示する**のが目標。Swift / AppKit、SwiftUI 不使用。

- 構想: [AAEdit_concept.md](../AAEdit_concept.md)
- v0.1 指示書: [MrEdit_claude_code_prompt.md](../MrEdit_claude_code_prompt.md)
- アーキ設計: [ARCHITECTURE_v0.1.md](ARCHITECTURE_v0.1.md)

決定事項: 名称は **MrEditor**、目標サイズは **10GB**、ビルドは **SPM**（`.xcodeproj` は配布直前に用意）。

## 2. 現在の状態（要約）

**画面表示のブロックは解決。本文・行番号・日本語が画面に正しく表示される。**

| 項目 | 状態 |
|---|---|
| SPM ビルド | ✅ 通る（`swift build`） |
| mmap 読み込み (FileBuffer) | ✅ 実装済み |
| 疎な行インデックス (LineIndex) | ✅ 実装済み・行数正確（50MBで429,336行＝生成値と一致） |
| 文字コード判定 (EncodingDetector) | ✅ UTF-8 / Shift-JIS / EUC-JP を実ファイルで正しく判定（2026-06-26 実測） |
| 描画ロジック (DocumentView) | ✅ 完全に正しい |
| カスタムスクローラ/キー操作 | ✅ 実装済み（描画経路は実機表示で確認、合成キー送出は権限制約で未自動検証） |
| ステータスバー | ✅ 画面に表示され更新もされる |
| **ウィンドウへの画面表示** | ✅ **解決**（原因と修正は §3） |

## 3. 解決済み：本文が真っ白だった問題（原因と修正）

### 原因（2026-06-26 特定）
**`StatusBarView` が custom `draw(_:)` を持ち、かつ子に `NSTextField` を抱えていたこと**が、
同一ウィンドウ内の別のカスタム描画ビュー（`LargeFileViewer`/`DocumentView`）の
**画面合成を壊していた**（macOS 26 の不具合と思われる挙動）。

`DocumentView` の `draw(_:)` は正しく呼ばれ、バッキングレイヤにも正しい contents が入り、
レイヤツリーの frame/opacity/hidden もすべて正常だったが、画面には合成されなかった。
`cacheDisplay` では完璧に描けることから「描画は正しく、合成だけが効かない」状態だった。

### 切り分けの要点（再発時の指針）
最小分離テスト（環境変数で構成を切替えて1個ずつ検証）の結果:
- viewer **単体** → 正常表示 ✅
- viewer + 空 `NSView` / flipped 空ビュー / custom-draw だけの兄弟 / `NSTextField` だけの兄弟
  → いずれも正常表示 ✅
- viewer + **本物の `StatusBarView`（custom draw + NSTextField 同居）** → 本文が真っ白 ❌

→ 「custom `draw()` と子コントロールを**同居**させた兄弟ビュー」が唯一のトリガーだった。
`isFlipped`・ネスト深さ・ステータス更新による再レイアウトは**いずれも無罪**（個別に検証して除外）。

### 修正
`StatusBarView` から `draw(_:)` を撤去し、背景色と区切り線を
**レイヤ（`layer.backgroundColor` ＋ サブレイヤ）で描画**するように変更。
これで viewer 側の合成が復活する。[StatusBarView.swift](../Sources/MrEditor/UI/StatusBarView.swift)。

> 教訓: このプロジェクトでは「custom `draw()` を持つビューに AppKit コントロールを
> 子として持たせない」。表示要素はレイヤ描画かコントロールのどちらかに寄せる。

### 動作確認手順（重要：残存プロセスに注意）
```bash
swift build
# 旧インスタンスが残るとスクショが汚染される。必ず先に全停止し0を確認:
pkill -9 -f "MrEditor/.build"; sleep 1; pgrep -f "MrEditor/.build" | wc -l   # → 0
.build/debug/MrEditor "$(pwd)/testdata/test_50mb_jp.log" &
# 前面化してスクショ:
osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "MrEditor") to true'
screencapture -x -o out.png
```
- `open .build/MrEditor.app` はバンドルの既存インスタンスを使い回すため**ゾンビ化しやすい**。
  検証は raw バイナリ（`.build/debug/MrEditor`）で行うこと。
- 文字コード判定は `testdata/sample_{utf8,sjis,euc}.txt` を開いて確認（UTF-8/Shift-JIS/EUC-JP を実測済み）。

## 4. 環境について（やった変更・重要）

このマシンの `/usr/local/include` に、**SDK の `/usr/include` ほぼ全体（284個）が
古い CommandLineTools SDK へのシンボリックリンク**として張られており（2022年作成）、
Xcode 26.5 SDK と衝突して **C/Swift ビルドが全滅**していた。

- 対処: SDK を指すシンボリックリンク 284 個を削除（`find /usr/local/include -maxdepth 1 -type l -lname '*SDKs/MacOSX*' -delete`）。
- Homebrew の実体（ImageMagick 等）は対象外。**シンボリックリンクのみ削除なので可逆**。
- バックアップ・復元スクリプトは `scratchpad/usr_local_include_sdk_symlinks_backup.txt` と
  `scratchpad/restore_symlinks.sh`（※ scratchpad は消える可能性。再発時は同コマンドで再削除すればよい）。
- これは MrEditor だけでなくマシン全体のツールチェーン修復。

## 5. プロジェクト構成

```
MrEditor/
├── Package.swift                      # SPM, macOS 13+, executableTarget
├── Sources/MrEditor/
│   ├── main.swift                     # NSApplication 起動
│   ├── AppDelegate.swift              # メニュー(⌘O)・ウィンドウ生成・引数/Finderで開く
│   ├── MainWindowController.swift     # ウィンドウ＋ビューア＋ステータスバー配置
│   ├── Core/
│   │   ├── FileBuffer.swift           # mmap ラッパ（全文をメモリに乗せない）
│   │   ├── LineIndex.swift            # 疎な行頭オフセット索引・背景構築・行数推定
│   │   └── EncodingDetector.swift     # BOM→UTF-8厳密→SJIS/EUCスコアリング
│   ├── Viewer/
│   │   ├── LargeFileViewer.swift      # 統括。自前NSScroller(単位=行)・スクロール/キー
│   │   └── DocumentView.swift         # 可視行のみ描画（巨大NSViewを使わずfloat精度限界回避）
│   └── UI/
│       └── StatusBarView.swift        # 文字コード/行数/サイズ/索引進捗
├── scripts/
│   ├── gen_testdata.py                # テストデータ生成（後述）
│   └── make_app.sh                    # .app バンドル化
└── docs/
    ├── ARCHITECTURE_v0.1.md
    └── HANDOFF_v0.1.md（本書）
```

## 6. 設計の要点（なぜこの作りか）

- **NSTextView は使わない**。10GB を NSTextStorage に乗せると破綻するため。
- 巨大ログビューア(klogg等)と同じ：mmap＋行頭オフセットの疎索引＋可視行だけ描画。
- **巨大 documentView 高さを使わない**。10GB≒1億行×行高 ≈ 16億pt は float 精度限界を
  超えて表示が破綻する。よって固定サイズ描画ビュー＋自前 NSScroller（単位=行）で任意サイズへスケール。
- 行分割は **0x0A バイトのみ**。UTF-8/SJIS/EUC いずれもマルチバイト途中に 0x0A は来ないので安全。
- 文字コード不能時は **UTF-8 置換デコードにフォールバック**（化けても落ちない方針）。

## 7. テストデータ生成

```bash
# 文字コード判定用 3種（UTF-8 / Shift-JIS / EUC-JP）
python3 scripts/gen_testdata.py --encoding-set --out-dir testdata/

# 50MB 日本語ログ（動作確認に使用中）
python3 scripts/gen_testdata.py --size 50M --jp --out testdata/test_50mb_jp.log

# 本番テスト用 10GB（実機テスト時に生成。空き要確認、生成に時間がかかる）
python3 scripts/gen_testdata.py --size 10G --out testdata/test_10gb.log
```
`testdata/` は `.gitignore` 済み（巨大ファイルを含むため）。

## 8. 未着手（v0.1 完成までに残る検証）

完成定義（[指示書](../MrEdit_claude_code_prompt.md)）の達成状況:
- [x] **画面表示の修復**（§3 で解決済み）
- [x] Shift-JIS / EUC-JP / UTF-8 が化けず表示・正しく判定（2026-06-26 実測）
- [x] **10GB を開く → 3秒以内に表示開始**（2026-06-27 実測。下記）
- [x] クラッシュしない・メモリ常駐が一定（10GB 表示中の実フットプリント **44MB**、ピーク 119MB）
- [ ] スクロールがカクつかない（描画・シーク経路は確認済み。体感スクロールは未測定。
      合成キー送出はアクセシビリティ権限の制約で自動検証できず）
- [ ] ウィンドウリサイズで崩れない（未確認）

### 10GB 実測結果（2026-06-27, `testdata/test_10gb.log` = 10.00GB / 86,420,337 行 / 日本語 UTF-8）
| 項目 | 結果 |
|---|---|
| 表示開始まで（first-paint） | **約 210〜310 ms**（目標 3 秒を大きく下回る） |
| 全索引構築（背景・表示はブロックしない） | 約 20 秒で 86,420,337 行を確定 |
| 末尾（8642万行目）へのシーク | **0.1 ms**（疎索引が瞬時に解決、末尾の行番号・本文とも正確） |
| 実メモリフットプリント | **44MB**（peak 119MB）。`ps` の RSS 約 3.8GB はほぼ全て破棄可能な mmap ファイルキャッシュ |
| クラッシュ | なし |

> 計測は raw バイナリに一時の `PERF` ログ／`JUMPEND` シークを仕込んで実施（コミットには含めない・撤去済み）。
> 再計測時は `main.swift`（起動時刻）・`DocumentView.draw`（first-paint）・`LargeFileViewer` 完了コールバック（全索引/末尾シーク）に同様のログを再挿入する。
> フットプリントは `vmmap <pid> | grep "Physical footprint"` で確認。

## 9. v0.1 スコープ外（作らない）
編集・保存・検索/grep・シンタックスハイライト・サイドバー/タブ・設定画面・横スクロール・
文字コード手動切替。すべて v0.2 以降。
