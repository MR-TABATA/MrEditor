# MrEditor

**English** | [日本語](README.ja.md)

**A Mac-native viewer — and editor — for 10 GB text files.**

Open a 10 GB log — **86,420,337 lines** — and it starts displaying in **~210 ms** with a
real memory footprint of **44 MB**. Jumping to the last line takes **0.1 ms**. As of **v0.4**
you can also **edit and save** — at any size, with atomic writes.

> It started life as a fast **read-only** viewer (full-file search, filtered view / live grep,
> `tail -f`). **v0.4 makes the name literal**: it edits and saves too.

## Why

The usual answer on macOS is `NSTextView`, but it keeps the whole document in
`NSTextStorage`. Hand it 10 GB and it falls over. MrEditor takes the large-log-viewer
approach (klogg / glogg / lnav):

- **mmap** the file — never load the whole thing into memory.
- Keep a **sparse line index** (one byte offset every 2,000 lines → ~400 KB for 100 M lines).
- **Draw only the visible lines** with Core Text, on a fixed-size view driven by a custom
  line-unit `NSScroller` (so we never build a 1.6-billion-point document view that would
  blow past float precision).

See [docs/ARCHITECTURE_v0.1.md](docs/ARCHITECTURE_v0.1.md) for the full design.

## Features (v0.7)

**Viewing**
- Opens arbitrarily large text files (validated at 10 GB) with near-instant first paint.
- Automatic encoding detection: **UTF-8 / Shift-JIS / EUC-JP** (verified on real files).
- Custom line-unit scroller and keyboard navigation (arrows, page, home/end).
- **Go to line (⌘L)** and **adjustable font size (⌘+ / ⌘- / ⌘0)** — persisted across launches.
- **Follow mode (`tail -f`, ⌥⌘F)** — auto-scrolls as the file grows; the index extends incrementally.
- Copy the visible range (⌘C). Status bar: encoding, line count, file size, indexing progress.

**Editing (new in v0.4)**
- **Edit and save files of any size** — small files load into an `NSTextView`; large files edit
  through a **piece table** over the mmap, so even a huge log stays responsive while you type.
- **Atomic save** — writes to a temporary file and swaps it in, so the original is never left half-written.
- **Choose the save encoding** — convert between **UTF-8 / Shift-JIS / EUC-JP**; line endings are
  normalized to the file's own EOL (LF / CRLF).
- New (⌘N), Save (⌘S), Save As (⌘⇧S), and Revert to saved.

**Workspace**
- Open **multiple files at once** and switch between them from a **sidebar** list.
- **Close from the sidebar** — each row has a close (×) button; **unsaved documents are color-coded**.
- **Session restore (new in v0.7)** — your sidebar comes back on launch (order and active tab
  included; files that vanished are skipped). **Unsaved new documents are restored with their text**,
  so quitting never nags you to save a scratch tab (unsaved edits to *saved* files are still confirmed).
- **Recent files** (File ▸ Open Recent).
- Drag a file onto the window to open it.

**Customization (new in v0.5)**
- **Fonts** — pick any monospaced family and size (Preferences ▸ Display), persisted across launches.
- **Display** — tab width (2/4/8), line spacing, current-line highlight, caret shape (bar / block / underline), and soft-wrap.
- **Color themes** — System (auto light/dark), Solarized Dark / Light, Monokai, or fully custom colors — applied to
  the text **and** the surrounding UI (sidebar, gutter, status bar, title bar).

**Search** (⌘F) — streams over the mmap, never loads the file
- Instant highlight of matches in the visible lines, plus a background full-file scan
  with an exact match count (capped at 1,000,000 matching lines).
- **Multi-term AND** (space-separated), **regular expressions** (`.*` toggle), and a **case-sensitive** toggle.
- Find next / previous, jumping to each matching line.
- **Filtered view / live grep** — show only matching lines, keeping their real line numbers.

**Structured view (new in v0.6)** — read-only, toggled from View ▸ Structured View
- **CSV / TSV** aligned into monospaced columns; **NDJSON** projected into columns by key.
- Column widths are fixed from a sample of the file, so **millions of rows format instantly** and
  don't jitter while scrolling. **East-Asian-width aware** — full-width Japanese columns line up.
- Purely a display transform: it never modifies the file (saving keeps the original CSV/JSON), and a
  banner with a **Back to raw text** button is shown while it's on.

UI **localized in English and Japanese**.

## Install

Download `MrEditor-<version>.dmg` from [Releases](../../releases), open it, and drag
**MrEditor** to Applications.

The app is **not code-signed or notarized** (no Apple Developer ID), so Gatekeeper blocks
it on first launch. To open it anyway, either:

- Right-click MrEditor → **Open** → **Open** in the dialog, or
- `xattr -dr com.apple.quarantine /Applications/MrEditor.app`

Or just build from source (below).

## Build & run

Requires macOS 13+ and a Swift toolchain (Xcode 15+).

```sh
swift build
sh scripts/make_app.sh debug          # wrap the binary into MrEditor.app
open .build/MrEditor.app --args "/path/to/big.log"
```

Generate test data (the `testdata/` dir is git-ignored):

```sh
python3 scripts/gen_testdata.py --encoding-set --out-dir testdata/   # UTF-8 / SJIS / EUC samples
python3 scripts/gen_testdata.py --size 10G --jp --out testdata/test_10gb.log
```

Build a distributable disk image (`.build/MrEditor-0.7.dmg`):

```sh
sh scripts/make_dmg.sh
```

## Performance (measured 2026-06-27, 10.00 GB / 86,420,337 lines, Japanese UTF-8)

| Metric | Result |
|---|---|
| Time to first paint | ~210 ms |
| Full background index | ~20 s (does not block display) |
| Seek to last line | 0.1 ms |
| Physical memory footprint | 44 MB (peak 119 MB) |

`ps` RSS reads ~3.8 GB during indexing — that is reclaimable, file-backed mmap cache, not
resident app memory. The number that matters (`Physical footprint`) stays at 44 MB.

## Roadmap

- **v0.1 — viewer** ✅
- **v0.2 — search, multi-term AND, regex, filtered view (live grep), `tail -f`, copy** ✅
- **v0.3 — multiple documents + sidebar, go to line, font zoom, recent files, case-sensitive search** ✅
- **v0.4 — editing & saving (any size), atomic writes, encoding conversion, EOL handling, new/save/save-as/revert** ✅
- **v0.5 — customization: font selection, display settings, color themes (editor + UI), sidebar close & unsaved markers** ✅
- **v0.6 — structured view: CSV/TSV column alignment & NDJSON field projection (read-only, any size)** ✅
- **v0.7 — session restore (unsaved drafts included), About panel fix** ✅ (this release)
- **later** — syntax/log highlighting, and more analysis tooling

## Not yet

Syntax / log highlighting and deeper analysis tooling. Editing landed in **v0.4** — the piece-table
design keeps even a 10 GB file editable without giving up the fast, low-memory open that MrEditor
is built around.

## Contributing

Bug fixes, performance, viewing/editing/search improvements, and translations are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). The core is a fast viewer/editor for huge files; heavier
automation and analysis tooling are out of scope (it's open-core — fork freely).

## License

[MIT](LICENSE) © 2026 TABATA Hitoshi

---

🇯🇵 日本語の README は **[README.ja.md](README.ja.md)** にあります。
