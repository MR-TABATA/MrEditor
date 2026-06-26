# MrEditor v0.1 アーキテクチャ設計

> 目標: **10GB のテキストファイルを落ちずに表示する**ビューア。
> Swift / AppKit のみ。SwiftUI は使わない。編集・検索・ハイライトは v0.2 以降。

---

## 0. 結論（採用方式）

**NSTextView は使わない。** 自前の `NSView` 描画 + `mmap` + 疎な行インデックスで実装する。

理由:
- `NSTextView` / `NSLayoutManager` / `NSTextStorage` は全文の長さ・レイアウトを前提とし、
  10GB を渡すと `NSTextStorage` がメモリに乗らず破綻する。
- 巨大ログビューア（klogg / glogg / lnav）の定石は
  「ファイルは mmap、行頭オフセットだけ索引化、見えている行だけ描画」。
  これをそのまま採る。

```
┌───────────────────────────────────────────────┐
│ NSScrollView                                   │
│  └─ DocumentView (自前 NSView, flipped)        │
│       高さ = 行数 × 行高                         │
│       draw(_:) で「見えている行」だけ描画        │
└───────────────────────────────────────────────┘
        ▲ 行番号→バイトオフセット
        │
┌───────┴───────────┐   ┌──────────────────────┐
│ LineIndex (疎索引)  │   │ FileBuffer (mmap)     │
│ N行ごとのオフセット  │   │ 10GBを仮想マップ       │
└───────────────────┘   └──────────────────────┘
                                 ▲
                        ┌────────┴─────────┐
                        │ EncodingDetector  │
                        │ 先頭64KBで判定     │
                        └──────────────────┘
```

---

## 1. メモリ戦略（最重要）

- **全文をメモリに乗せない。** `mmap(2)` でファイルを仮想アドレス空間に写像し、
  OS のページング任せで必要な箇所だけ物理メモリに載せる。
  - 10GB の mmap は 64bit macOS で問題なし（仮想空間に乗るだけ）。
  - Swift では `Data(contentsOf:options:.mappedIfSafe)` でも mmap されるが、
    挙動を確実にするため `mmap` を直接呼ぶ（`FileBuffer` でラップ）。
- **描画は可視領域のみ。** スクロール位置から可視行レンジを計算し、
  その行のバイト範囲だけ decode して Core Text で描く。
- decode 結果は小さな LRU キャッシュ（数百行分）に持つ。スクロールで破棄。

---

## 2. 行インデックス（LineIndex）

10GB ≒ 約 1 億行。行頭オフセットを全部持つと `8B × 1億 = 800MB` で重い。
→ **疎索引（sparse index）**: `STRIDE`（例 1000）行ごとに `UInt64` オフセットを保存。

- メモリ: `1億 / 1000 × 8B = 800KB`。十分軽い。
- 行 `n` の位置 = `index[n / STRIDE]` から `n % STRIDE` 個だけ `0x0A` を前方スキャン。
  STRIDE 行ぶんの線形スキャンは数十KB程度で一瞬。

### 改行スキャンの安全性
行分割は **バイト 0x0A (`\n`) のみ**で行う。
UTF-8 / Shift-JIS / EUC-JP のいずれも、マルチバイト文字の途中に 0x0A は現れない
（SJIS 2バイト目: 0x40–0x7E, 0x80–0xFC / EUC: 0xA1–0xFE）。
→ エンコーディングに依らず 0x0A 検索で正しく行頭を取れる。CR(0x0D) は表示時に除去。

### 索引構築のタイミング
1. **即時表示（< 1s）**: open 時に先頭 ~2MB だけスキャンして先頭画面分の行を確定 → すぐ描画。
   この時点の行数は「推定値」（`ファイルサイズ / 平均行長`）でスクロールバーを仮置き。
2. **バックグラウンド全索引**: 別スレッドで全体を `memchr` 相当で走査し疎索引を構築。
   完了後に「確定行数」へ差し替え、スクロール範囲を正す。ステータスバーに進捗表示。

> 10GB の全走査は mmap + memchr で概ね数秒〜十数秒（ディスク速度依存）。
> 表示開始はそれを待たない。

---

## 3. 描画（DocumentView）

- `NSView` サブクラス（`isFlipped = true`）を `NSScrollView` に入れる。
- `intrinsicContentSize` / frame 高さ = `lineCount × lineHeight`（等幅・固定行高）。
  - v0.1 は **行の折り返しなし（no wrap）**。横スクロール可。固定行高でレイアウト計算を O(1) に。
- `draw(_ dirtyRect:)`:
  1. `dirtyRect` から可視行レンジ `[first, last]` を算出（`y / lineHeight`）。
  2. 各行: `LineIndex` でバイト範囲取得 → `FileBuffer` から slice → decode → Core Text で 1 行描画。
  3. 行番号ガター（左）も同時に描画。
- フォント: 等幅（SF Mono → なければ Menlo）。固定行高 = フォントの line height。

### スクロール快適性
- 固定行高なので可視行計算は割り算のみ → スクロール量に依らず一定コスト。
- decode は可視行だけ（数十行）+ LRU。重い処理が無いのでカクつかない。

---

## 4. 文字コード判定（EncodingDetector）

先頭 64KB を読み、次の順で判定:

1. **BOM 判定**: UTF-8 BOM / UTF-16 LE/BE BOM。
2. **UTF-8 厳密デコード**: 不正バイト列が無ければ UTF-8 確定。
3. **Shift-JIS / EUC-JP スコアリング**: それぞれの 2バイト範囲規則に
   どれだけ適合するかでスコア付けし、高い方を採用。
4. **判定不能**: UTF-8 (置換文字 `errors=replace` 相当) でフォールバック。
   → **化けても落ちない**を優先（指示書の方針）。

判定結果はステータスバーに表示。将来は手動切替を付ける（v0.2+）。

---

## 5. クラス構成

```
MrEditor/
├── MrEditor.xcodeproj
└── MrEditor/
    ├── AppDelegate.swift
    ├── MainWindowController.swift     # ウィンドウ + ⌘O + ドラッグ&ドロップ受け
    ├── Core/
    │   ├── FileBuffer.swift           # mmap ラッパ。バイト範囲アクセス
    │   ├── LineIndex.swift            # 疎な行頭オフセット索引（背景構築）
    │   └── EncodingDetector.swift     # 文字コード判定
    ├── Viewer/
    │   ├── LargeFileViewer.swift      # NSScrollView + DocumentView の統括
    │   └── DocumentView.swift         # 可視行のみ Core Text 描画
    └── UI/
        └── StatusBarView.swift        # エンコーディング / 行数 / サイズ / 索引進捗
```

責務:
- **FileBuffer**: `open`/`mmap`/`munmap`、`bytes(in: Range<Int>) -> UnsafeRawBufferPointer`、`count`。
- **LineIndex**: `STRIDE`、`offset(forLine:)`、`byteRange(ofLine:)`、`lineCount`、
  `buildInBackground(progress:)`、確定/推定フラグ。
- **EncodingDetector**: `detect(prefix: Data) -> String.Encoding`。
- **DocumentView**: 描画と可視行レンジ計算のみ。状態は持たない（Viewer から供給）。
- **LargeFileViewer**: ファイルを束ね、索引完了でスクロール範囲更新、再描画指示。

---

## 6. v0.1 完成の定義（指示書準拠）

- [ ] 10GB ログをドラッグ → **3秒以内に表示開始**
- [ ] スクロールがカクつかない
- [ ] Shift-JIS が化けずに表示できる（UTF-8 / EUC-JP も）
- [ ] ウィンドウリサイズで崩れない
- [ ] クラッシュしない（メモリ常駐を一定に保つ）

## 7. v0.1 で割り切ること
- 行の折り返しなし（横スクロール）。
- 選択・コピーは最小（できれば可視範囲の選択。難しければ v0.2）。
- 編集・保存・検索・grep・ハイライト・サイドバー・設定は **作らない**。
- 文字コード手動切替なし（自動のみ）。
