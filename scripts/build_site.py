#!/usr/bin/env python3
"""LP の唯一のソース web/lp.src.html から、公開用の site/ を生成する。

生成物:
    site/index.html      navigator.language を見て振り分けるリダイレクタ（SyncVey と同方式）
    site/index.ja.html   日本語版（本文が静的に埋まっている）
    site/index.en.html   英語版

なぜ生成するのか:
    日英を別ファイルで手管理すると必ずズレる（notes/draft-1.0 が実例）。
    ソースは `data-en` / `data-ja` を持つ要素を 1 組だけ持ち、ここから両方を作る。

なぜ正規表現でなく HTML パーサなのか:
    属性値の中に `>` や `'` が入っている（例: data-en="… <span class='teal'>…"）。
    正規表現でタグを切ると壊れる。実際に一度それで誤検出を出した。
"""
from html.parser import HTMLParser
from pathlib import Path
import html
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "web" / "lp.src.html"
OUT = ROOT / "site"

LANGS = {"ja": "index.ja.html", "en": "index.en.html"}
# 言語切替リンクの表示名（自分の言語が `on`）
LABEL = {"ja": "日本語", "en": "EN"}
# HTML の void 要素（終了タグを持たない）
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"}


def restore_entities(text: str) -> str:
    """HTMLParser が属性値を読むとき実体参照を復元してしまうぶんを戻す。

    `&amp;` → `&` に化けたものを実体へ戻す（`&copy` のような並びで壊れるため）。
    `&nbsp;` → U+00A0 も、ソースと同じ見た目の HTML になるよう実体へ戻す。
    タグ（例: `<span class='teal'>`）は本文として意図されたものなので触らない。
    """
    text = re.sub(r"&(?!#?\w+;)", "&amp;", text)
    return text.replace(" ", "&nbsp;")


class Localizer(HTMLParser):
    """`data-en` / `data-ja` を持つ要素を、指定言語の文字列で埋めて出力する。

    元のソースではそれらの要素の中身は空（JS が innerHTML に入れていた）。
    生成物では中身を静的に埋め、`data-*` 属性は落とす。
    """

    def __init__(self, lang: str):
        super().__init__(convert_charrefs=False)
        self.lang = lang
        self.out: list[str] = []
        self.skip_depth = 0     # 中身を捨てている要素のネスト深さ
        self.strip = False      # BUILD:STRIP 区間の中か

    # --- 出力ヘルパ -------------------------------------------------------
    def emit(self, s: str) -> None:
        if not self.strip and self.skip_depth == 0:
            self.out.append(s)

    def _localized(self, attrs: dict) -> str | None:
        """この要素に言語別テキストがあれば返す。"""
        return attrs.get(f"data-{self.lang}")

    def _render_starttag(self, tag: str, attrs: list, drop: set) -> str:
        parts = [tag]
        for k, v in attrs:
            if k in drop:
                continue
            if v is None:
                parts.append(k)
            else:
                parts.append(f'{k}="{html.escape(v, quote=True)}"')
        return "<" + " ".join(parts) + ">"

    # --- パーサのコールバック ---------------------------------------------
    def handle_starttag(self, tag, attrs):
        d = dict(attrs)

        if d.get("id") == "langSwitch":
            self.emit(self._render_starttag(tag, attrs, drop=set()))
            self.emit(self._lang_links())
            return

        text = self._localized(d)
        if text is None:
            self.emit(self.get_starttag_text())
            return

        # <meta name="description" data-en=… data-ja=…> は content 属性に入れる
        if tag == "meta":
            attrs2 = [(k, v) for k, v in attrs if not k.startswith("data-")]
            attrs2.append(("content", text))
            self.emit(self._render_starttag(tag, attrs2, drop=set()))
            return

        # 通常の要素: 中身を言語テキストで置き換える（元の中身は捨てる）
        self.emit(self._render_starttag(tag, attrs, drop={"data-en", "data-ja"}))
        self.emit(restore_entities(text))
        if tag not in VOID:
            self.skip_depth = 1   # 元の（空の）中身を読み飛ばす

    def handle_startendtag(self, tag, attrs):
        d = dict(attrs)
        text = self._localized(d)
        if text is not None and tag == "meta":
            attrs2 = [(k, v) for k, v in attrs if not k.startswith("data-")]
            attrs2.append(("content", text))
            self.emit(self._render_starttag(tag, attrs2, drop=set()))
        else:
            self.emit(self.get_starttag_text())

    def handle_endtag(self, tag):
        if self.skip_depth:
            self.skip_depth = 0
            self.out.append(f"</{tag}>")   # 読み飛ばし中でも閉じタグは出す
            return
        self.emit(f"</{tag}>")

    def handle_data(self, data):
        if "BUILD:STRIP-START" in data:
            # <script> 内のコメントで囲まれた区間を丸ごと落とす
            head, _, rest = data.partition("/* BUILD:STRIP-START")
            self.emit(head)
            _, _, tail = rest.partition("BUILD:STRIP-END */")
            self.emit(tail)
            return
        self.emit(data)

    def handle_comment(self, data):
        # ソース専用の注記（生成物には出さない）
        if "唯一のソース" in data or "build_site.py" in data:
            return
        self.emit(f"<!--{data}-->")

    def handle_entityref(self, name):
        self.emit(f"&{name};")

    def handle_charref(self, name):
        self.emit(f"&#{name};")

    def handle_decl(self, decl):
        self.emit(f"<!{decl}>")

    # --- 言語切替リンク ---------------------------------------------------
    def _lang_links(self) -> str:
        links = []
        for lang, fname in LANGS.items():
            on = ' class="on"' if lang == self.lang else ""
            cur = ' aria-current="page"' if lang == self.lang else ""
            links.append(f'<a href="{fname}" hreflang="{lang}"{on}{cur}>{LABEL[lang]}</a>')
        return "".join(links)


def localize(src: str, lang: str) -> str:
    p = Localizer(lang)
    p.feed(src)
    out = "".join(p.out)
    # <html lang="en"> を実際の言語へ
    out = out.replace('<html lang="en">', f'<html lang="{lang}">', 1)
    # 検索エンジンに対応関係を伝える
    alt = ("\n" + "\n".join(
        f'<link rel="alternate" hreflang="{l}" href="{f}">' for l, f in LANGS.items()
    ) + '\n<link rel="alternate" hreflang="x-default" href="index.html">')
    out = out.replace("</head>", alt + "\n</head>", 1)
    return out


REDIRECT = """<!DOCTYPE html>
<!-- 自動生成: python3 scripts/build_site.py（編集しない。ソースは web/lp.src.html） -->
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MrEditor — Redirecting…</title>
<meta name="description" content="A Mac-native viewer and editor that opens 10 GB text files without choking.">
<link rel="canonical" href="index.en.html">
<link rel="alternate" hreflang="ja" href="index.ja.html">
<link rel="alternate" hreflang="en" href="index.en.html">
<link rel="alternate" hreflang="x-default" href="index.en.html">
<meta property="og:type" content="website">
<meta property="og:site_name" content="MrEditor">
<meta property="og:title" content="MrEditor — open and edit 10 GB text files on a Mac">
<meta property="og:description" content="Opens a 10 GB log (86 million lines) in about 80 ms, holding 0 bytes of it in memory, then lets you edit and save it with atomic writes.">
<meta property="og:url" content="https://mr-tabata.github.io/MrEditor/">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="MrEditor — open and edit 10 GB text files on a Mac">
<meta name="twitter:description" content="Opens a 10 GB log (86 million lines) in about 80 ms, holding 0 bytes of it in memory.">
__FAVICON__
<script>
  // ブラウザの言語で振り分ける。履歴を汚さないよう replace を使う。
  (function () {
    var lang = navigator.language || navigator.userLanguage || '';
    var target = lang.toLowerCase().indexOf('ja') === 0 ? 'index.ja.html' : 'index.en.html';
    window.location.replace(target);
  })();
</script>
</head>
<body style="background:#0A1416;color:#8FA8A6;font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif;
             display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
  <!-- JS が無効でも辿り着けるようにする（クローラ対策も兼ねる） -->
  <p>Redirecting… &nbsp;<a href="index.en.html" style="color:#14B8A6">English</a>
     &nbsp;/&nbsp; <a href="index.ja.html" style="color:#14B8A6">日本語</a></p>
</body>
</html>
"""


def main() -> int:
    if not SRC.exists():
        print(f"ソースが無い: {SRC}", file=sys.stderr)
        return 1
    src = SRC.read_text(encoding="utf-8")

    # favicon はソースと同じものを使い回す（重複定義を避ける）
    favicon = next((l for l in src.splitlines() if 'rel="icon"' in l), "")

    OUT.mkdir(exist_ok=True)
    for lang, fname in LANGS.items():
        (OUT / fname).write_text(localize(src, lang), encoding="utf-8")
        print(f"  生成: site/{fname}")

    (OUT / "index.html").write_text(REDIRECT.replace("__FAVICON__", favicon), encoding="utf-8")
    print("  生成: site/index.html（リダイレクタ）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
