#!/usr/bin/env python3
"""LP の唯一のソース web/lp.src.html から、公開用の site/ を生成する。

生成物:
    site/index.html      英語版（本文が静的に埋まっている）。公開URLの入口
    site/index.ja.html   日本語版（本文が静的に埋まっている）
    site/index.en.html   index.html と同じ中身の別名。古いリンクを生かすためだけに置く

なぜ生成するのか:
    日英を別ファイルで手管理すると必ずズレる（notes/draft-1.0 が実例）。
    ソースは `data-en` / `data-ja` を持つ要素を 1 組だけ持ち、ここから両方を作る。

なぜ `/` がリダイレクタでないのか:
    以前の `/` は navigator.language を見て言語版へ location.replace していた。
    これをやると着地の1ホップが計測されないうえ、飛んだ先の document.referrer が
    自サイトに書き換わる。つまり「X の告知から何人来たか」が原理的に取れなくなる。
    流入元を測れることのほうが、言語の自動振り分けより価値が高いと判断した。
    日本語ブラウザには、遷移せずに日本語版への導線（#jaHint）を出して補う。

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

BASE = "https://mr-tabata.github.io/MrEditor/"
# 各言語の正規URL（サイト内の相対リンクにも canonical にも、これを使う）
HREF = {"ja": "index.ja.html", "en": "./"}
# 生成するファイル → その中身の言語。index.en.html は古いリンク用の別名で、
# canonical は index.html を指すので検索エンジンからは重複と見なされない。
OUTPUTS = {"index.ja.html": "ja", "index.html": "en", "index.en.html": "en"}
# 言語切替リンクの表示名（自分の言語が `on`）
LABEL = {"ja": "日本語", "en": "EN"}
# HTML の void 要素（終了タグを持たない）
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"}

# 中身を持てないタグは、日英の文字列を「どの属性に入れるか」で受ける。
# ここに無いタグは通常どおり要素の中身を置き換える。
ATTR_TARGET = {"meta": "content", "img": "alt"}


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
        self.drop_depth = 0     # data-only で丸ごと落としている要素のネスト深さ

    # --- 出力ヘルパ -------------------------------------------------------
    def emit(self, s: str) -> None:
        if not self.strip and self.skip_depth == 0 and self.drop_depth == 0:
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

        # data-only="<lang>" は、その言語のページにだけ出す（中身ごと落とす）
        if self.drop_depth:
            if tag not in VOID:
                self.drop_depth += 1
            return
        only = d.get("data-only")
        if only is not None:
            if only != self.lang:
                if tag not in VOID:
                    self.drop_depth = 1
                return
            self.emit(self._render_starttag(tag, attrs, drop={"data-only"}))
            return

        if d.get("id") == "langSwitch":
            self.emit(self._render_starttag(tag, attrs, drop=set()))
            self.emit(self._lang_links())
            return

        text = self._localized(d)
        if text is None:
            self.emit(self.get_starttag_text())
            return

        # 中身を持てないタグは属性へ入れる:
        #   <meta …>  → content
        #   <img  …>  → alt（画像の説明も日英で切り替えたいため）
        if tag in ATTR_TARGET:
            key = ATTR_TARGET[tag]
            attrs2 = [(k, v) for k, v in attrs if not k.startswith("data-") and k != key]
            attrs2.append((key, text))
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
        if text is not None and tag in ATTR_TARGET:
            key = ATTR_TARGET[tag]
            attrs2 = [(k, v) for k, v in attrs if not k.startswith("data-") and k != key]
            attrs2.append((key, text))
            self.emit(self._render_starttag(tag, attrs2, drop=set()))
        else:
            self.emit(self.get_starttag_text())

    def handle_endtag(self, tag):
        if self.drop_depth:
            self.drop_depth -= 1
            return
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
        for lang, href in HREF.items():
            on = ' class="on"' if lang == self.lang else ""
            cur = ' aria-current="page"' if lang == self.lang else ""
            links.append(f'<a href="{href}" hreflang="{lang}"{on}{cur}>{LABEL[lang]}</a>')
        return "".join(links)


def abs_url(lang: str) -> str:
    """言語ごとの絶対URL。canonical と og:url に使う。"""
    href = HREF[lang]
    return BASE if href == "./" else BASE + href


def localize(src: str, lang: str) -> str:
    p = Localizer(lang)
    p.feed(src)
    out = "".join(p.out)
    # <html lang="en"> を実際の言語へ
    out = out.replace('<html lang="en">', f'<html lang="{lang}">', 1)
    # 正規URLと、検索エンジンに伝える対応関係。
    # index.en.html も canonical は index.html を指す（同じ中身の別名なので）。
    head = "\n".join([
        f'<link rel="canonical" href="{abs_url(lang)}">',
        f'<meta property="og:url" content="{abs_url(lang)}">',
        *(f'<link rel="alternate" hreflang="{l}" href="{abs_url(l)}">' for l in HREF),
        f'<link rel="alternate" hreflang="x-default" href="{abs_url("en")}">',
    ])
    out = out.replace("</head>", "\n" + head + "\n</head>", 1)
    return out


def main() -> int:
    if not SRC.exists():
        print(f"ソースが無い: {SRC}", file=sys.stderr)
        return 1
    src = SRC.read_text(encoding="utf-8")

    OUT.mkdir(exist_ok=True)
    # 同じ言語のページは中身が同じなので、言語ごとに1回だけ組み立てて使い回す
    pages = {lang: localize(src, lang) for lang in HREF}
    for fname, lang in OUTPUTS.items():
        (OUT / fname).write_text(pages[lang], encoding="utf-8")
        print(f"  生成: site/{fname}（{lang}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
