#!/usr/bin/env python3
"""更新履歴（リリースノート）に貼る「採用した要望」の節を、Issue から作る。

    python3 scripts/adopted_requests.py --since v1.20.0       # この版の公開以降に完了した要望
    python3 scripts/adopted_requests.py --since-date 2026-10-01

`request` ラベルの付いた Issue のうち、完了（status:done。閉じるとボットが付ける）または採用
（status:adopted）で、基準の日より後に閉じたものを、提案者つきで並べる。出力は日本語と英語の2節。
リリースノートに貼るのは、あなた（持ち主）。題名は他人の入力なので、Markdown の記号は無害化する。
"""
import json
import re
import subprocess
import sys
import os

REPO = os.environ.get("GITHUB_REPOSITORY", "MR-TABATA/MrEditor")
COUNTED = ("status:done", "status:adopted")


def gh_json(path):
    out = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"gh api {path}: {out.stderr.strip()[:200]}")
    text = out.stdout.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        merged = []
        for chunk in re.split(r"(?<=\])\s*(?=\[)", text):
            merged.extend(json.loads(chunk))
        return merged


def md_escape(s):
    return re.sub(r"([\\`*_{}\[\]<>#|])", r"\\\1", re.sub(r"\s+", " ", s).strip())


def since_date_of_tag(tag):
    rel = gh_json(f"repos/{REPO}/releases/tags/{tag}")
    return (rel.get("published_at") or rel.get("created_at") or "")[:10]


def adopted(issues, since_date):
    """基準の日（その日を含まない）より後に閉じた、採用・完了の要望。古い順。"""
    out = []
    for i in issues:
        if "pull_request" in i or i.get("state") != "closed" or i.get("state_reason") == "not_planned":
            continue
        names = {l["name"] for l in i.get("labels", [])}
        if "request" in names and names & set(COUNTED) and (i.get("closed_at") or "")[:10] > since_date:
            out.append(i)
    return sorted(out, key=lambda x: x["closed_at"])


def render(issues):
    if not issues:
        return "（この期間に、採用・完了した要望はありません / No requests adopted in this period）\n"
    line = lambda i, ja: (f"- #{i['number']} {md_escape(i['title'])} — "
                          + (f"提案: @{i['user']['login']}（ありがとうございます）" if ja else f"requested by @{i['user']['login']} — thank you"))
    ja = "### 採用した要望\n\nこの版で、次の要望を採用しました。\n\n" + "\n".join(line(i, True) for i in issues)
    en = "### Requests adopted\n\nThis release adopts these requests.\n\n" + "\n".join(line(i, False) for i in issues)
    return ja + "\n\n" + en + "\n"


def main(argv):
    if "--since" in argv:
        since = since_date_of_tag(argv[argv.index("--since") + 1])
    elif "--since-date" in argv:
        since = argv[argv.index("--since-date") + 1]
    else:
        raise SystemExit(__doc__)
    issues = gh_json(f"repos/{REPO}/issues?state=closed&labels=request&per_page=100")
    sys.stdout.write(render(adopted(issues, since)))


if __name__ == "__main__":
    main(sys.argv[1:])
