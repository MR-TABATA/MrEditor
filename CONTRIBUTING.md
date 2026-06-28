# Contributing to MrEditor

Thanks for your interest — contributions are welcome. MrEditor is a small, focused project,
so a quick read of the scope below will save everyone time.

## What MrEditor is

A **fast, read-only viewer for very large text files** on macOS. The whole design — `mmap`,
a sparse line index, drawing only the visible lines — exists to open 10 GB without choking.
Its mission is simple: **open one file of any size, and search it, instantly.**

## Contributions that fit the core

These are very welcome:

- Bug fixes and performance improvements.
- Viewing, scrolling, encoding detection (UTF-8 / Shift-JIS / EUC-JP / more).
- Search, regex, filtered view (live grep), and `tail -f` improvements.
- Accessibility, localization (the UI ships in English and Japanese), small UX polish.
- Documentation and tests.

For anything non-trivial, please **open an issue first** so we can agree on the approach
before you spend time on it.

## Out of the core's scope

To keep the core small and fast, some areas are **intentionally out of scope** for this
repository, and PRs implementing them won't be merged here:

- **Editing / saving** — MrEditor is read-only by design.
- **Persistence of state** — session save/restore, saved searches, saved highlight profiles.
- **Working across many files** — multi-file / folder search, multiple simultaneous `tail -f`.
- **Automation** — automatic log-format parsing, alerting, rule-based coloring.

This isn't a judgment on those features; they're good ideas, just not part of *this* core's
mission ("open and search one file, fast"). MrEditor follows an **open-core** model: the core
in this repository stays **MIT-licensed and free**, and those out-of-scope areas may be
offered separately later.

**It's MIT-licensed — so fork freely.** If you want any of the above, forking MrEditor and
building it yourself is completely fine and encouraged. We just won't carry it here.

## Building

See the [README](README.md): `swift build`, then `sh scripts/make_app.sh debug`.

---

### 日本語

MrEditor は **巨大テキストの読み取り専用・高速ビューア**です。バグ修正・性能・表示・
文字コード・検索/フィルタ/`tail -f` の改善・i18n・ドキュメントは歓迎します（大きめの変更は
先に Issue を立ててください）。

一方で **編集/保存・状態の永続化（セッション/検索/プロファイルの保存）・複数ファイル横断・
自動化（ログ形式の自動解析・通知・ルール色分け）** は**コアの射程外**で、本リポジトリには
取り込みません。良し悪しの話ではなく、このコアの使命（「1ファイルを速く開いて探す」）の外、
というだけです。MrEditor は**オープンコア**で、コアは **MIT・無料**のまま続きます。

**MIT なので fork して自分で足すのは自由**です。上記が欲しい場合は遠慮なくどうぞ。ただ本
リポジトリには載せません。
