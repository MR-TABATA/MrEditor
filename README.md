# MrEditor

**English** | [日本語](README.ja.md)

**A Mac-native viewer — and editor — for 10 GB text files.**

Open a 10 GB log — **86,420,337 lines** — and it starts displaying in **~80 ms**. The file is
mapped, never copied: with all 10 GB open, `vmmap` reports **0 bytes dirty** for it. Jumping to
the last line takes **0.1 ms**. As of **v0.4** you can also **edit and save** — at any size,
with atomic writes.

> It started life as a fast **read-only** viewer (full-file search, filtered view / live grep,
> `tail -f`). **v0.4 makes the name literal**: it edits and saves too.

And it can **`tail -f` a growing 10 GB log (⌥⌘F) while you edit it in place** — without reloading.
The mmap index extends by the new bytes only, so it holds up even while the file is still being
written at 10 GB. Editors that tail (BBEdit, Sakura) reload the whole file; log viewers that scale
to 10 GB (klogg, lnav) are read-only. **Following a multi-GB log incrementally while staying
editable — we couldn't find that combination anywhere else.**

![Opening a 10 GB, 86,420,337-line log in MrEditor — it paints immediately, and the line index keeps building in the background](docs/img/10gb-open.gif)

*The first 10 seconds of a single uncut take, at real speed: the 10.00 GB file opens, and we scroll it while the line index is still building. Watch the status bar — the line count is an estimate until the index lands (9.1 s), then it settles at the exact **86,420,337**. The view never blocks; you can read, search and edit throughout. [The whole 27-second take, uncut, ending with ⌘L to the last line.](docs/media/mreditor-10gb.mp4)*

<p align="center">
  <img src="docs/img/structured-dark.png" width="49%" alt="CSV aligned into monospaced columns (structured view)">
  <img src="docs/img/search-10gb-dark.png" width="49%" alt="Full-file search across a 10 GB log">
</p>

## Why

The usual answer on macOS is `NSTextView`, but it keeps the whole document in
`NSTextStorage`. Hand it 10 GB and it falls over. MrEditor takes the large-log-viewer
approach (klogg / glogg / lnav):

- **mmap** the file — never load the whole thing into memory.
- Keep a **sparse line index** (line number + byte offset every 2,000 lines → 670 KB for this file, ~800 KB for 100 M lines).
- **Draw only the visible lines** with Core Text, on a fixed-size view driven by a custom
  line-unit `NSScroller` (so we never build a 1.6-billion-point document view that would
  blow past float precision).

See [docs/ARCHITECTURE_v0.1.md](docs/ARCHITECTURE_v0.1.md) for the full design.

## Features (1.2)

**Viewing**
- Opens arbitrarily large text files (validated at 10 GB) with near-instant first paint.
- Automatic encoding detection: **UTF-8 / Shift-JIS / EUC-JP** (verified on real files).
- Custom line-unit scroller and keyboard navigation (arrows, page, home/end).
- **Go to line (⌘L)** and **adjustable font size (⌘+ / ⌘- / ⌘0)** — persisted across launches.
- **Follow mode (`tail -f`, ⌥⌘F)** — auto-scrolls as the file grows. It **extends the index
  incrementally instead of reloading**, so it holds up on a 10 GB log that's still being written
  (following pauses while you have unsaved edits, and resumes on save).
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
- **Finder integration (new in v0.8)** — MrEditor appears in Finder's *Open With* for `.log`,
  `.txt`, `.csv`, `.json` and friends. It never steals the default app.
- **Print & PDF export (new in v0.8)** — File ▸ Print… (⌘P). The print dialog's
  *PDF ▸ Save as PDF* gives you a PDF. Disabled for huge files (millions of pages).
- **Update check (new in v0.8)** — tells you when a newer version ships (on launch, once a day).
  It never replaces anything; it just opens the download page. Turn it off in Preferences ▸ General.

**Customization (new in v0.5)**
- **Fonts** — pick any monospaced family and size (Preferences ▸ Display), persisted across launches.
- **Display** — tab width (2/4/8), line spacing, current-line highlight, caret shape (bar / block / underline), and soft-wrap.
- **Color themes** — System (auto light/dark), Solarized Dark / Light, Monokai, Dracula, Nord, Grass, Red Sands, or fully custom colors — applied to
  the text **and** the surrounding UI (sidebar, gutter, status bar, title bar).
- **Background opacity** — make the whole window translucent so the desktop shows through (iTerm-style; Preferences ▸ Colors).
- **ANSI colors** — colorize ANSI escapes (`ESC[…m`) in logs while viewing (the escape sequences are stripped automatically).

**Search** (⌘F) — streams over the mmap, never loads the file
- Instant highlight of matches in the visible lines, plus a background full-file scan
  with an exact match count (capped at 1,000,000 matching lines).
- **Multi-term AND** (space-separated), **regular expressions** (`.*` toggle — including **lookahead / lookbehind** assertions), and a **case-sensitive** toggle.
- Find next / previous, jumping to each matching line.
- **Filtered view / live grep** — show only matching lines, keeping their real line numbers.

**Compare / diff (new in v1.1)** — View ▸ Compare (Diff)
- Four ways in: **two files** (⇧⌘D), **two open documents** (unsaved text included — it compares what you see), **against the clipboard**, or **against a URL** (https — paste a link and it diffs what the web returns against what you have open).
- Side by side, with additions, deletions and changes colored. **Changed lines get a character-level diff**, so a single `status=200` → `500` stands out.
- **⇧⌘] / ⇧⌘[** for next / previous difference. The **scrollbar shows where the differences are**, so you can see at a glance which parts of a million-line file moved.
- Select within a column and **⌘C** to copy (rows that exist only on the other side are never mixed in).
- **Merge (new in v1.2)** — **click the → beside a difference** and the left side's version lands in the right, immediately (click again to undo; ⌥→ / ⌥← also work).
  The arrow means what it says: **the right side is what changes**. Write that result out with **View ▸ Compare (Diff) ▸ Save Merged Result As…**.
  **The two original files are never touched.** Push nothing across, and you get the right file back byte for byte.
- Diffing needs a 16-byte index per line — unlike viewing, that is real memory. Files too large for
  your machine are **refused with a reason**, never silently killed. Measured: 1 GB × 2 (8.7 M lines) in 5.4 s, 1.7 GB.

**Structured view (new in v0.6)** — read-only, toggled from View ▸ Structured View
- **CSV / TSV** aligned into monospaced columns; **NDJSON** projected into columns by key.
- **JSON** pretty-printed with indentation (new in 1.4) — key order and number formatting preserved,
  since it re-indents the original text rather than re-serializing.
- Column widths are fixed from a sample of the file, so **millions of rows format instantly** and
  don't jitter while scrolling. **East-Asian-width aware** — full-width Japanese columns line up.
- Purely a display transform: it never modifies the file (saving keeps the original CSV/JSON), and a
  banner with a **Back to raw text** button is shown while it's on.

**JSON query (new in 1.4)** — View ▸ JSON Query… (⌥⌘J), on a JSON document
- Type a **jmespath-style expression** and the view is replaced by the result, live: fields and dotted
  paths (`a.b.c`), array indexes (`items[0]`, `items[-1]`), wildcard projection (`items[*].name`,
  `m.*`), and filters (`items[?age >= 30].name`, comparators `== != < <= > >=`).
- **Volatile and read-only**: the result is never saved; close the bar (Esc) to return to the original.
  Best for config and API-response JSON (small files); large logs use NDJSON above.

**Text toolbox (new in 1.5)** — the **Format** menu, acting on the current selection (one undo each)
- **Case**: UPPER / lower / Title Case / tOGGLE cASE.
- **Encode / decode**: URL, Base64, and HTML entities (decoders leave invalid input untouched).
- **Line ops**: sort (ascending / descending), remove duplicate lines (keeps first-seen order),
  reverse, and number lines.
- **Filter Through Command… (⌥⌘R)**: pipe the selection through any shell command — `jq .`,
  `sort`, `sed 's/a/b/g'` — and replace it with the output. Runs off the main thread with a timeout.
- Works in **both panes**, so line ops and filters run on a selection inside a 10 GB file too.

**Appearance & sharing (new in 1.6)** — Preferences ▸ Colors
- **Preset themes**: System, Solarized Dark/Light, Monokai, **Dracula, Nord, Grass, Red Sands** —
  the body colors and the surrounding chrome (sidebar, gutter, status bar) move together.
- **Share your look**: export the whole appearance (theme, colors, font, layout) to a
  `.mreditortheme` file, or **Copy Link** — a self-contained `mreditor://` link that anyone with
  MrEditor can open to apply it in one click. Applying always asks first. No account, no server.

UI **localized in English and Japanese**.

## Install

Download `MrEditor-<version>.dmg` from [Releases](../../releases), open it, and drag
**MrEditor** to Applications.

**Runs on both Apple Silicon and Intel** (universal build).

**As of v0.9 the app is signed with an Apple Developer ID and notarized by Apple.**
No right-click, no `xattr` — just double-click it.

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

Build a distributable disk image (`.build/MrEditor-1.7.dmg`):

```sh
sh scripts/make_dmg.sh
```

## Performance (measured 2026-07-15, 10.00 GB / 86,420,337 lines, Japanese UTF-8)

Re-measured 2026-07-19 on the shipping 1.7 build (`swift build -c release`), Apple Silicon.

| Metric | Result |
|---|---|
| Time to first paint | 45–80 ms (varies run to run) |
| Full background index | ~10 s (does not block display) |
| Seek to last line | 0.1 ms |
| The file's own pages | 3–6 GB resident (varies run to run), **0 bytes dirty** |
| App physical footprint | ~145 MB — about the same with nothing open (~143 MB empty) |

The last two rows are the honest picture, so read them together. The 10 GB you opened costs
nothing: it is mapped, not copied, and `vmmap` attributes **0 dirty bytes** to it — the resident
pages are file-backed and the OS can drop them whenever it likes. The app's own ~145 MB is window
backing store and the kernel page tables for a 10 GB mapping; it barely moves whether the file is
open or not, and none of it is your log. `ps` RSS reads several GB during indexing for the same
reason, and means just as little.

Reproduce it yourself:

```sh
MREDITOR_TIMING=1 .build/MrEditor.app/Contents/MacOS/MrEditor testdata/test_10gb.log
# → first paint: 61.2 ms
# → index complete: 10.24 s (86420337 lines)

vmmap $(pgrep -x MrEditor) | grep test_10gb.log     # → 10.0G  2.8G  0K  (vsize resident dirty; resident varies, dirty stays 0)
```

## Roadmap

- **v0.1 — viewer** ✅
- **v0.2 — search, multi-term AND, regex, filtered view (live grep), `tail -f`, copy** ✅
- **v0.3 — multiple documents + sidebar, go to line, font zoom, recent files, case-sensitive search** ✅
- **v0.4 — editing & saving (any size), atomic writes, encoding conversion, EOL handling, new/save/save-as/revert** ✅
- **v0.5 — customization: font selection, display settings, color themes (editor + UI), sidebar close & unsaved markers** ✅
- **v0.6 — structured view: CSV/TSV column alignment & NDJSON field projection (read-only, any size)** ✅
- **v0.7 — session restore (unsaved drafts included), About panel fix** ✅
- **v0.8 — Finder integration, print/PDF export, update check, new icon, universal build, and a critical distribution fix (below)** ✅
- **v0.9 — signed with an Apple Developer ID and notarized by Apple; opens with a plain double-click** ✅
- **1.0 — the milestone: open and edit 10 GB files on a Mac, signed and notarized, opens with a double-click** ✅
- **1.0.1 — fixes data loss: an unsaved new document vanished when the app was launched by opening a file** ✅
- **1.0.2 — unsaved text is kept as its own draft file, written as you type: it survives a crash or force quit** ✅
- **1.0.3 — Go to line (⌘L) no longer fails silently when a Japanese IME is active** ✅
- **1.1 — Compare (diff): two files, two open documents, or against the clipboard — side by side, down to the characters that changed** ✅
- **1.1.1 — Compare Two Files now asks for one file, then the other. Before, it silently did nothing unless you ⌘-clicked both at once** ✅
- **1.2 — Merge: click the arrow next to a difference to pull it across, then save the result under a new name. The two originals are never touched** ✅
- **1.2.1 — Merge now follows the arrow: → pushes the left side into the right, and the right pane changes as you click. Before, it only remembered your choice and nothing moved on screen** ✅
- **1.3 — Compare with a URL (https): paste a link and it diffs what the web returns against the document you have open — a fourth way in, alongside two files, two open documents and the clipboard** ✅
- **1.4 — JSON: pretty-print a document from Structured View, and query it in place with a jmespath-style expression (⌥⌘J) — filter and project without touching the file** ✅
- **1.5 — Text toolbox (Format menu): case conversion, URL/Base64/HTML encode-decode, sort/dedupe/reverse/number lines, and Filter Through Command (⌥⌘R) to pipe a selection through any shell command — in both panes, so it works inside a 10 GB file too** ✅
- **1.6 — Appearance & sharing: preset themes (Dracula, Nord, Grass, Red Sands, …), plus export/import of your whole look and a self-contained `mreditor://` share link that applies it in one click** ✅
- **1.7 — Regex lookahead/lookbehind in search & replace, ANSI colors in logs (escape sequences colorized while viewing, stripped from the text), and window-wide background opacity (iTerm-style translucency)** ✅ (this release)
- **later** — syntax/log highlighting, and more analysis tooling

> **⚠️ Builds up to v0.7 do not launch on a Mac that downloaded them.**
> The `.app` bundle was never code-signed, so its signature seal was inconsistent and
> macOS killed the quarantined app on launch ("quit unexpectedly").
> **Fixed in v0.8.** The build is now **universal (Apple Silicon & Intel)** as well —
> previously it was arm64-only.
>
> **v0.8 launches, but needs a right-click → Open on the first run** (it is only ad-hoc signed).
> **v0.9 and later are signed and notarized, so even that is unnecessary.**

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
