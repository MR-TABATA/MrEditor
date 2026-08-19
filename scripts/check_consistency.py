#!/usr/bin/env python3
"""LP・README・リリース・i18n の整合性を機械的に確かめる。

人の目では必ず漏れる（実際、公表値が 4 つ間違ったまま配られ、LP の OG タグには
古い数字がハードコードされたまま残っていた）。**リリースの前に必ず通す。**

    python3 scripts/check_consistency.py

**製品ごとの事情は `.consistency.json` に全部出してある。** このファイルは 4 製品
（MrEditor / MrkEditor / MR Down / MrkDown）へそのままコピーして使う。設定に無い節は
検査ごと飛ばすので、LP を持たない製品でも「版だけ」「i18n だけ」で回せる。

見るもの（設定にある節だけ走る）:
  1. versions       … バージョン文字列が全部そろっているか
  2. generated_site … 生成物が src から作り直された状態か（置き去りの検出）
  3. lang_parity    … 日英の片落ち（data-en / data-ja）
  4. i18n           … キーと書式指定子の一致・未定義キーの使用
  5. release_docs   … 公開したタグが文書に載っているか
  6. measured       … 公表値が文書間で食い違っていないか
  7. pro_gate       … 無料版に未ゲートの有償機能が載っていないか
"""

import hashlib
import json
import re
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / ".consistency.json"
FAIL: list[str] = []
WARN: list[str] = []


def read(p: str) -> str:
    return (ROOT / p).read_text(encoding="utf-8")


def head(title: str) -> None:
    print(f"\n──── {title}")


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        print(f"設定が無い: {CONFIG_PATH.name}", file=sys.stderr)
        sys.exit(2)
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


# 1. バージョン文字列 ---------------------------------------------------------

def check_versions(sources: list[dict]) -> None:
    head("バージョン文字列")
    versions = {}
    for src in sources:
        m = re.search(src["pattern"], read(src["path"]))
        if not m:
            FAIL.append(f"バージョンが見つからない: {src['name']}（{src['path']}）")
            continue
        versions[src["name"]] = m.group(1)
        print(f"  {src['name']:24s} {m.group(1)}")

    if len(set(versions.values())) > 1:
        FAIL.append(f"バージョンが食い違っている: {versions}")
    elif versions:
        print("  → すべて一致 ✅")


# 2. 生成物のドリフト ---------------------------------------------------------

def check_site_drift(cfg: dict) -> None:
    """再生成して**中身が変わるか**で見る。

    git の差分で見てはいけない（リリースでバージョンを上げた直後は必ず差分が出るので、
    毎回誤検知する。実際に誤検知した）。
    """
    out_dir, glob, builder = cfg["dir"], cfg.get("glob", "*.html"), cfg["builder"]
    head(f"{out_dir}/ が {Path(builder).name} から再生成された状態か")

    def digest() -> dict[str, str]:
        return {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
                for f in sorted((ROOT / out_dir).glob(glob))}

    before = digest()
    subprocess.run([sys.executable, builder], cwd=ROOT, check=True, capture_output=True)
    after = digest()

    changed = [k for k in after if before.get(k) != after[k]]
    if changed:
        FAIL.append(f"{out_dir}/ が古い（{builder} を通していない）: {', '.join(changed)}")
    else:
        print("  ドリフト無し ✅")


# 3. 日英パリティ -------------------------------------------------------------

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


def check_lp_parity(sources: list[str]) -> None:
    head("日英パリティ")
    before = len(FAIL)
    for src in sources:
        c = LangCheck()
        c.feed(read(src))
        print(f"  {src}: 日英対を持つ要素 {c.pairs}")
        FAIL.extend(f"{src}: {b}" for b in c.bad)
    if len(FAIL) == before:
        print("  片落ち無し ✅")


# 4. i18n --------------------------------------------------------------------

def check_i18n(cfg: dict) -> None:
    head("i18n のキー")
    langs = cfg.get("langs", ["ja", "en"])
    tables = {lang: {m.group(1): m.group(2)
                     for m in re.finditer(r'^"([^"]+)"\s*=\s*"(.*)";',
                                          read(cfg["table"].format(lang=lang)), re.M)}
              for lang in langs}
    print("  " + " / ".join(f"{lang}: {len(t)}" for lang, t in tables.items()))

    base = langs[0]
    for lang in langs[1:]:
        for miss in sorted(set(tables[base]) - set(tables[lang])):
            FAIL.append(f"{lang} に無いキー: {miss}")
        for miss in sorted(set(tables[lang]) - set(tables[base])):
            FAIL.append(f"{base} に無いキー: {miss}")

        # 書式指定子の数が食い違うと、実行時に落ちる
        for k in sorted(set(tables[base]) & set(tables[lang])):
            fb = re.findall(r'%[@dfs]|%\d\$[@dfs]', tables[base][k])
            fl = re.findall(r'%[@dfs]|%\d\$[@dfs]', tables[lang][k])
            if len(fb) != len(fl):
                FAIL.append(f"書式指定子の数が違う（実行時に落ちる）: {k}  {base}={fb} {lang}={fl}")

    # コードが使うキーが実在するか。動的キー（L("a.\(x)")）は補間を含むので除外する。
    used: set[str] = set()
    for f in (ROOT / cfg["code_dir"]).rglob(cfg.get("code_glob", "*.swift")):
        used |= set(re.findall(cfg["call"], f.read_text()))
    static_used = {k for k in used if "\\(" not in k}
    for k in sorted(static_used - set(tables[base])):
        FAIL.append(f"未定義のキーを使っている（画面にキー名が出る）: {k}")

    # 未使用の疑い（変数経由 L(key) で使う分は検出できないので警告どまり）
    dynamic_prefixes = {k.split("\\(")[0] for k in used if "\\(" in k}
    suspicious = {k for k in set(tables[base]) - static_used
                  if not any(k.startswith(p) for p in dynamic_prefixes)}
    if suspicious:
        WARN.append(f"未使用の疑いがあるキー {len(suspicious)} 件（変数経由なら問題なし）")

    print("  キー・書式指定子とも一致 ✅")


# 5. 出したものが文書に載っているか --------------------------------------------

def published_versions(prefix: str) -> list[str]:
    """公開済みのタグ（gh が使えないときは空＝この検査を飛ばす）。"""
    try:
        out = subprocess.run(["gh", "release", "list", "--limit", "100", "--json", "tagName",
                              "--jq", ".[].tagName"], capture_output=True, text=True, timeout=30)
    except Exception:
        return []
    if out.returncode != 0:
        return []
    return [t.strip().removeprefix(prefix) for t in out.stdout.splitlines() if t.strip()]


def check_release_coverage(cfg: dict) -> None:
    """**出したのに書いていない版**を見つける。

    リリースのたびに複数の文書へ手で足しており、どれか 1 つを忘れても誰も気づかない。
    タグを正として突き合わせる。
    """
    head("公開した版が文書に載っているか")
    tags = published_versions(cfg.get("tag_prefix", "v"))
    if not tags:
        print("  gh が使えないため飛ばす")
        return

    targets: list[tuple[str, dict, str | None]] = []
    if "history" in cfg:
        targets.append(("リリース全史", cfg["history"], cfg["history"].get("skip_prefix")))
    targets += [(r["path"], r, r.get("skip_prefix")) for r in cfg.get("roadmaps", [])]

    ok = True
    for label, spec, skip in targets:
        listed = set(re.findall(spec["pattern"], read(spec["path"]), re.M))
        want = [t for t in tags if not (skip and t.startswith(skip))]
        missing = [t for t in want if t not in listed]
        print(f"  {label}: {len(listed)} 件（対象タグ {len(want)}）")
        if missing:
            FAIL.append(f"{label} に載っていない版: {', '.join(sorted(missing))}")
            ok = False
    if ok:
        print("  全部載っている ✅")


# 6. 公表値の食い違い ---------------------------------------------------------

def check_measured_numbers(measured: dict, docs: list[str]) -> None:
    """**測り直した数字の書き忘れ**を見つける（同じ指標に別の値が残っていないか）。"""
    head("公表値の食い違い")
    texts = {d: read(d) for d in docs}
    for label, spec in measured.items():
        if label.startswith("_"):
            continue                        # 設定ファイル内のコメント行
        bad: list[str] = []
        for doc, text in texts.items():
            for hit in set(re.findall(spec["family"], text)):
                if not re.fullmatch(spec["canonical"], hit):
                    bad.append(f"{doc}:{hit}")
        if bad:
            FAIL.append(f"{label} に別の値がある: {', '.join(sorted(bad))}")
        else:
            print(f"  {label} ✅")


# 7. 課金境界 ----------------------------------------------------------------

def check_pro_gate(cfg: dict) -> None:
    """**無料版に未ゲートの有償機能が載っていないか。**

    2026-08-04、時刻マージが `Pro v1:` というコミットメッセージだけを根拠に無料リポへ入り、
    翌日そのまま無料版として出荷された。「Pro のつもり」がコードのどこにも書かれていなかった
    のが原因なので、機械で見る。

    見るもの:
      a. 機能フラグの各ケースを参照するファイルは、必ず許可の口を通すこと
      b. 無料版の実行ファイルが有償層を差し込んでいないこと
    """
    head("課金境界（Pro ゲート）")

    block = re.search(rf'enum {cfg["enum"]}[^{{]*\{{(.*?)\n\}}', read(cfg["seam"]), re.S)
    cases = re.findall(r'^\s*case (\w+)$', block.group(1), re.M) if block else []
    if not cases:
        FAIL.append(f"{cfg['enum']} のケースが 1 つも読み取れない（{cfg['seam']} の形が変わった？）")
        return
    print(f"  有償機能として宣言済み: {len(cases)} 件 — {', '.join(cases)}")

    seam_dir = ROOT / cfg["seam_dir"]
    ungated: list[str] = []
    for f in (ROOT / cfg["code_dir"]).rglob("*.swift"):
        if seam_dir in f.parents:
            continue                      # 継ぎ目そのものは対象外
        src = f.read_text()
        rel = f.relative_to(ROOT)
        for c in cases:
            if re.search(rf'\.{c}\b', src) and f"Pro.allows(.{c})" not in src:
                ungated.append(f"{rel}: .{c} を使っているのに Pro.allows(.{c}) を通していない")
    for u in ungated:
        FAIL.append(f"未ゲートの有償機能: {u}")

    if "free_main" in cfg:
        must = cfg["free_main_must_contain"].replace(" ", "")
        if must not in read(cfg["free_main"]).replace(" ", ""):
            FAIL.append("無料版の main が有償層を差し込んでいる（無料版は必ず引数なしで起動する）")

    if not ungated:
        print("  無料版に未ゲートの有償機能なし ✅")


def main() -> int:
    cfg = load_config()
    print(f"整合性チェック: {cfg.get('product', ROOT.name)}")

    if cfg.get("versions"):       check_versions(cfg["versions"])
    if cfg.get("generated_site"): check_site_drift(cfg["generated_site"])
    if cfg.get("lang_parity"):    check_lp_parity(cfg["lang_parity"])
    if cfg.get("i18n"):           check_i18n(cfg["i18n"])
    if cfg.get("release_docs"):   check_release_coverage(cfg["release_docs"])
    if cfg.get("measured"):       check_measured_numbers(cfg["measured"], cfg.get("docs", []))
    if cfg.get("pro_gate"):       check_pro_gate(cfg["pro_gate"])

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
