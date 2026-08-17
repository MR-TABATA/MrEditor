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
  6. 公開したタグが 3 つの文書（README 日・英・リリース全史）に載っているか
  7. 公表値が文書間で食い違っていないか（測り直して 1 箇所だけ直す事故）
"""

import hashlib
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
        "AppInfo.fallbackVersion": re.search(r'fallbackVersion = "([\d.]+)"', read("Sources/MrEditorCore/AppInfo.swift")),
        "make_app.sh":             re.search(r'VERSION:-([\d.]+)', read("scripts/make_app.sh")),
        "make_dmg.sh":             re.search(r'VERSION:-([\d.]+)', read("scripts/make_dmg.sh")),
        "LP バッジ":               re.search(r'macOS 13\+ · v([\d.]+)', read("web/lp.src.html")),
        "LP の DL リンク":          re.search(r'MrEditor-([\d.]+)\.dmg', read("web/lp.src.html")),
        "README(en)":              re.search(r'MrEditor-([\d.]+)\.dmg', read("README.md")),
        "README(ja)":              re.search(r'MrEditor-([\d.]+)\.dmg', read("README.ja.md")),
        "リリース全史の DL リンク":   re.search(r'MrEditor-([\d.]+)\.dmg', read("web/releases.src.html")),
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
    """再生成して**中身が変わるか**で見る。

    git の差分で見てはいけない（リリースでバージョンを上げた直後は必ず差分が出るので、
    毎回誤検知する。実際に誤検知した）。
    """
    head("site/ が lp.src.html から再生成された状態か")

    def digest() -> dict[str, str]:
        out = {}
        for f in sorted((ROOT / "site").glob("*.html")):
            out[f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
        return out

    before = digest()
    subprocess.run([sys.executable, "scripts/build_site.py"], cwd=ROOT,
                   check=True, capture_output=True)
    after = digest()

    changed = [k for k in after if before.get(k) != after[k]]
    if changed:
        FAIL.append(f"site/ が古い（build_site.py を通していない）: {', '.join(changed)}")
    else:
        print("  ドリフト無し ✅")


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
    for src in ("web/lp.src.html", "web/releases.src.html"):
        c = LangCheck()
        c.feed(read(src))
        print(f"  {src}: 日英対を持つ要素 {c.pairs}")
        if c.bad:
            FAIL.extend(f"{src}: {b}" for b in c.bad)
    if not FAIL:
        print("  片落ち無し ✅")


# 4-5. i18n ------------------------------------------------------------------

def strings(lang: str) -> dict[str, str]:
    s = read(f"Sources/MrEditorCore/Resources/{lang}.lproj/Localizable.strings")
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


# 5. 課金境界 ----------------------------------------------------------------

def check_pro_gate() -> None:
    """**無料版に未ゲートの Pro 機能が載っていないか。**

    2026-08-04、時刻マージが `Pro v1:` というコミットメッセージだけを根拠に
    無料リポへ入り、翌日そのまま無料版として出荷された。「Pro のつもり」が
    コードのどこにも書かれていなかったのが原因なので、機械で見る。

    見るもの:
      a. `ProFeature` の各ケースを参照するファイルは、必ず `Pro.allows(.ケース)` を通すこと
      b. 無料版の実行ファイル（Sources/MrEditor/）が Pro を差し込んでいないこと
    """
    head("課金境界（Pro ゲート）")

    seam = read("Sources/MrEditorCore/Pro/Pro.swift")
    # ProFeature の宣言ブロックだけを見る（同じファイルの ProEntitlement を拾わないため）
    block = re.search(r'enum ProFeature[^{]*\{(.*?)\n\}', seam, re.S)
    cases = re.findall(r'^\s*case (\w+)$', block.group(1), re.M) if block else []
    if not cases:
        FAIL.append("ProFeature のケースが 1 つも読み取れない（Pro.swift の形が変わった？）")
        return
    print(f"  Pro 機能として宣言済み: {len(cases)} 件 — {', '.join(cases)}")

    seam_dir = ROOT / "Sources" / "MrEditorCore" / "Pro"
    ungated: list[str] = []
    for f in (ROOT / "Sources").rglob("*.swift"):
        if seam_dir in f.parents:
            continue                      # 継ぎ目そのものは対象外
        src = f.read_text()
        rel = f.relative_to(ROOT)
        for c in cases:
            if re.search(rf'\.{c}\b', src) and f"Pro.allows(.{c})" not in src:
                ungated.append(f"{rel}: .{c} を使っているのに Pro.allows(.{c}) を通していない")
    for u in ungated:
        FAIL.append(f"未ゲートの Pro 機能: {u}")

    free_main = read("Sources/MrEditor/main.swift")
    if "MrEditorApp.main()" not in free_main.replace(" ", ""):
        FAIL.append("無料版の main.swift が Pro を差し込んでいる（無料版は必ず引数なしで起動する）")

    if not ungated:
        print("  無料版に未ゲートの Pro 機能なし ✅")


# 6. 出したものが 3 つの文書に載っているか ------------------------------------

def published_versions() -> list[str]:
    """公開済みのタグ（gh が使えないときは空＝この検査を飛ばす）。"""
    try:
        out = subprocess.run(["gh", "release", "list", "--limit", "100", "--json", "tagName",
                              "--jq", ".[].tagName"],
                             capture_output=True, text=True, timeout=30)
    except Exception:
        return []
    if out.returncode != 0:
        return []
    return [t.strip().lstrip("v") for t in out.stdout.splitlines() if t.strip()]


def check_release_coverage() -> None:
    """**出したのに書いていない版**を見つける。

    リリースのたびに 3 箇所（README 日・英・リリース全史）へ手で足しており、
    どれか 1 つを忘れても誰も気づかない。タグを正として突き合わせる。
    """
    head("公開した版が文書に載っているか")
    tags = published_versions()
    if not tags:
        print("  gh が使えないため飛ばす")
        return

    history = set(re.findall(r'class="v">([\d.]+)<', read("web/releases.src.html")))
    ja = set(re.findall(r'^- \*\*([\d]+\.[\d.]*[\d])', read("README.ja.md"), re.M))
    en = set(re.findall(r'^- \*\*([\d]+\.[\d.]*[\d])', read("README.md"), re.M))

    missing_history = [t for t in tags if t not in history]
    # README のロードマップは 1.0 以降だけを載せる方針（0.x は全史が持つ）。
    one_plus = [t for t in tags if not t.startswith("0.")]
    missing_ja = [t for t in one_plus if t not in ja]
    missing_en = [t for t in one_plus if t not in en]

    print(f"  公開タグ {len(tags)} / 全史 {len(history)} / README(ja) {len(ja)} / README(en) {len(en)}")
    for label, missing in (("リリース全史", missing_history),
                           ("README(ja)", missing_ja), ("README(en)", missing_en)):
        if missing:
            FAIL.append(f"{label} に載っていない版: {', '.join(sorted(missing))}")
    if not (missing_history or missing_ja or missing_en):
        print("  全部載っている ✅")


# 7. 公表値が文書間で食い違っていないか ---------------------------------------

# 同じ指標に**違う数字**が書かれていないかを見る。数字は測り直したときに
# 1 箇所だけ直して忘れる（実際に 4 つ間違ったまま配った）。
MEASURED = {
    # 法人番号 CSV は**全行 5,816,535／データ行 5,816,534**（ヘッダ 1 行）。どちらも正しいので
    # 両方を正とし、それ以外の桁違い（測り直しの書き忘れ）だけを弾く。
    "法人番号 CSV の行数": (r"5,816,53[45]|581 万 653[45]|581万653[45]",
                            r"5,816,5[0-9]{2}|581 ?万 ?65[0-9]{2}"),
    "Excel が止まる行数": (r"1,048,576|104 万 8576|104万8576",
                            r"1,048,[0-9]{3}|104 ?万 ?8[0-9]{3}"),
    # 索引の途中に出る**概算**（約 89,292,800）は別の数字なので拾わない。
    "10GB ログの行数":    (r"86,420,337", r"86,4[0-9]{2},[0-9]{3}"),
}


def check_measured_numbers() -> None:
    """**測り直した数字の書き忘れ**を見つける（同じ指標に別の値が残っていないか）。"""
    head("公表値の食い違い")
    docs = {name: read(path) for name, path in (
        ("README(ja)", "README.ja.md"), ("README(en)", "README.md"),
        ("LP", "web/lp.src.html"), ("リリース全史", "web/releases.src.html"))}
    for label, (canonical, family) in MEASURED.items():
        bad: list[str] = []
        for doc, text in docs.items():
            for hit in set(re.findall(family, text)):
                if not re.fullmatch(canonical, hit):
                    bad.append(f"{doc}:{hit}")
        if bad:
            FAIL.append(f"{label} に別の値がある: {', '.join(sorted(bad))}")
        else:
            print(f"  {label} ✅")


def main() -> int:
    check_versions()
    check_site_drift()
    check_lp_parity()
    check_i18n()
    check_pro_gate()
    check_release_coverage()
    check_measured_numbers()

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
