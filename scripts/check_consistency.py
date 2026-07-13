#!/usr/bin/env python3
"""LP・リリース・i18n の整合性を機械的に確かめる。

人の目では必ず漏れる（実際、公表値が 4 つ間違ったまま配られ、
LP の OG タグには古い数字がハードコードされたまま残っていた）。
**リリースの前に必ず通す。**

    python3 scripts/check_consistency.py

見るもの:
  1. バージョン文字列が全部そろっているか（AppInfo / make_app / make_dmg / LP / README）
  2. site/ が web/lp.src.html から再生成された状態か（生成物の置き去り）
  3. LP の全要素が日英そろっているか（data-en / data-ja の片落ち）
  4. i18n のキーが日英でそろい、書式指定子の数も一致するか（実行時クラッシュの元）
  5. コードが使うキーが定義されているか（画面にキー名がそのまま出るのを防ぐ）
"""

import re
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAIL: list[str] = []
WARN: list[str] = []


def read(p: str) -> str:
    return (ROOT / p).read_text()


def head(title: str) -> None:
    print(f"\n──── {title}")


# 1. バージョン --------------------------------------------------------------

def check_versions() -> None:
    head("バージョン文字列")
    found = {
        "AppInfo.fallbackVersion": re.search(r'fallbackVersion = "([\d.]+)"', read("Sources/MrEditor/AppInfo.swift")),
        "make_app.sh":             re.search(r'VERSION:-([\d.]+)', read("scripts/make_app.sh")),
        "make_dmg.sh":             re.search(r'VERSION:-([\d.]+)', read("scripts/make_dmg.sh")),
        "LP バッジ":               re.search(r'macOS 13\+ · v([\d.]+)', read("web/lp.src.html")),
        "LP の DL リンク":          re.search(r'MrEditor-([\d.]+)\.dmg', read("web/lp.src.html")),
        "README(en)":              re.search(r'MrEditor-([\d.]+)\.dmg', read("README.md")),
        "README(ja)":              re.search(r'MrEditor-([\d.]+)\.dmg', read("README.ja.md")),
    }
    versions = {}
    for name, m in found.items():
        if not m:
            FAIL.append(f"バージョンが見つからない: {name}")
            continue
        versions[name] = m.group(1)
        print(f"  {name:24s} {m.group(1)}")

    uniq = set(versions.values())
    if len(uniq) > 1:
        FAIL.append(f"バージョンが食い違っている: {versions}")
    else:
        print(f"  → すべて一致 ✅")


# 2. 生成物のドリフト ---------------------------------------------------------

def check_site_drift() -> None:
    head("site/ が lp.src.html から再生成された状態か")
    subprocess.run([sys.executable, "scripts/build_site.py"], cwd=ROOT,
                   check=True, capture_output=True)
    r = subprocess.run(["git", "diff", "--quiet", "--", "site/"], cwd=ROOT)
    if r.returncode == 0:
        print("  ドリフト無し ✅")
    else:
        FAIL.append("site/ が古い（build_site.py を通していない。生成物を直接編集した可能性）")


# 3. LP の日英パリティ --------------------------------------------------------

class LangCheck(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=False)
        self.pairs = 0
        self.bad: list[str] = []

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        en, ja = "data-en" in d, "data-ja" in d
        if en or ja:
            self.pairs += 1
            if not (en and ja):
                missing = "data-ja" if en else "data-en"
                text = (d.get("data-en") or d.get("data-ja") or "")[:40]
                self.bad.append(f"<{tag}> に {missing} が無い: {text}")

    handle_startendtag = handle_starttag


def check_lp_parity() -> None:
    head("LP の日英パリティ")
    c = LangCheck()
    c.feed(read("web/lp.src.html"))
    print(f"  日英対を持つ要素: {c.pairs}")
    if c.bad:
        FAIL.extend(c.bad)
    else:
        print("  片落ち無し ✅")


# 4-5. i18n ------------------------------------------------------------------

def strings(lang: str) -> dict[str, str]:
    s = read(f"Sources/MrEditor/Resources/{lang}.lproj/Localizable.strings")
    return {m.group(1): m.group(2) for m in re.finditer(r'^"([^"]+)"\s*=\s*"(.*)";', s, re.M)}


def check_i18n() -> None:
    head("i18n のキー")
    ja, en = strings("ja"), strings("en")
    print(f"  ja: {len(ja)} / en: {len(en)}")

    for miss in sorted(set(ja) - set(en)):
        FAIL.append(f"en に無いキー: {miss}")
    for miss in sorted(set(en) - set(ja)):
        FAIL.append(f"ja に無いキー: {miss}")

    # 書式指定子の数が食い違うと、実行時に落ちる
    for k in sorted(set(ja) & set(en)):
        fj = re.findall(r'%[@dfs]|%\d\$[@dfs]', ja[k])
        fe = re.findall(r'%[@dfs]|%\d\$[@dfs]', en[k])
        if len(fj) != len(fe):
            FAIL.append(f"書式指定子の数が違う（実行時に落ちる）: {k}  ja={fj} en={fe}")

    # コードが使うキーが実在するか。動的キー（L("a.\(x)")）は補間を含むので除外する。
    used: set[str] = set()
    for f in (ROOT / "Sources").rglob("*.swift"):
        used |= set(re.findall(r'L\("([^"]+)"', f.read_text()))
    static_used = {k for k in used if "\\(" not in k}
    for k in sorted(static_used - set(ja)):
        FAIL.append(f"未定義のキーを使っている（画面にキー名が出る）: {k}")

    # 未使用の疑い（変数経由 L(key) で使う分は検出できないので警告どまり）
    literal_unused = set(ja) - static_used
    dynamic_prefixes = {k.split("\\(")[0] for k in used if "\\(" in k}
    suspicious = {k for k in literal_unused
                  if not any(k.startswith(p) for p in dynamic_prefixes)}
    if suspicious:
        WARN.append(f"未使用の疑いがあるキー {len(suspicious)} 件（変数経由なら問題なし）")

    if not FAIL:
        print("  キー・書式指定子とも一致 ✅")


def main() -> int:
    check_versions()
    check_site_drift()
    check_lp_parity()
    check_i18n()

    print()
    for w in WARN:
        print(f"  ⚠️  {w}")
    if FAIL:
        print(f"\n❌ {len(FAIL)} 件の不整合:")
        for f in FAIL:
            print(f"   - {f}")
        return 1
    print("\n✅ 整合性 OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
