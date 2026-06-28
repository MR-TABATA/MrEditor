# MrEditor

**English** | [日本語](README.ja.md)

**A Mac-native viewer that opens 10 GB text files without choking.**

Open a 10 GB log — **86,420,337 lines** — and it starts displaying in **~210 ms** with a
real memory footprint of **44 MB**. Jumping to the last line takes **0.1 ms**.

> A **read-only** viewer — but a capable one: full-file search, filtered view (live grep),
> and `tail -f`. No editing (the name is aspirational; see the bottom for why).

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

## Features (v0.2)

**Viewing**
- Opens arbitrarily large text files (validated at 10 GB) with near-instant first paint.
- Automatic encoding detection: **UTF-8 / Shift-JIS / EUC-JP** (verified on real files).
- Custom line-unit scroller and keyboard navigation (arrows, page, home/end).
- **Follow mode (`tail -f`, ⌥⌘F)** — auto-scrolls as the file grows; the index extends incrementally.
- Copy the visible range (⌘C). Status bar: encoding, line count, file size, indexing progress.

**Search** (⌘F) — streams over the mmap, never loads the file
- Instant highlight of matches in the visible lines, plus a background full-file scan
  with an exact match count (capped at 1,000,000 matching lines).
- **Multi-term AND** (space-separated) and **regular expressions** (`.*` toggle).
- Find next / previous, jumping to each matching line.
- **Filtered view / live grep** — show only matching lines, keeping their real line numbers.

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

Build a distributable disk image (`.build/MrEditor-0.2.dmg`):

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
- **v0.2 — search, multi-term AND, regex, filtered view (live grep), `tail -f`, copy** ✅ (this release)
- **later** — syntax/log highlighting, and more analysis tooling

## Not yet (on purpose)

Editing and saving. The read-only mmap design that makes the viewer fast is exactly what
makes editing a 10 GB file a different, harder problem. MrEditor is a fast *reader* at heart.

## Contributing

Bug fixes, performance, viewing/search improvements, and translations are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). The core is a fast read-only viewer; persistence,
multi-file workflows, and automation are out of its scope (it's open-core — fork freely).

## License

[MIT](LICENSE) © 2026 TABATA Hitoshi

---

🇯🇵 日本語の README は **[README.ja.md](README.ja.md)** にあります。
