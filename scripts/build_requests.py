#!/usr/bin/env python3
"""公開の要望一覧（site/requests.html = 英語、site/requests.ja.html = 日本語）を作る。

    python3 scripts/build_requests.py                 # GitHub から取って書く（gh と GH_TOKEN が要る）
    python3 scripts/build_requests.py --fixture f.json  # 取らずに、JSON の写しから書く（確認用）

`request` ラベルの付いた Issue を、状況（status:* のラベル）ごとに並べる。「やらない」には、持ち主が
書いた理由を添える。題名・理由は他人の入力なので、**必ずエスケープして出す**（リンク先は、番号から
作る。入力からは作らない）。`.github/workflows/pages.yml` が、状況が変わるたびと毎日、呼ぶ。
"""
import datetime as dt
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
REPO = os.environ.get("GITHUB_REPOSITORY", "MR-TABATA/MrEditor")
DEADLINE_DAYS = 7
MIN_REASON = 12

# (status label, key, {lang: heading})
STATUSES = [
    ("status:received", "received", {"ja": "受付（7日以内に返事します）", "en": "Received (reply within 7 days)"}),
    ("status:considering", "considering", {"ja": "検討中", "en": "Considering"}),
    ("status:adopted", "adopted", {"ja": "採用（これから作る）", "en": "Adopted (to be built)"}),
    ("status:in-progress", "in-progress", {"ja": "実装中", "en": "In progress"}),
    ("status:done", "done", {"ja": "完了（リリース済み）", "en": "Done (released)"}),
    ("status:declined", "declined", {"ja": "やらない（理由つき）", "en": "Not doing (with the reason)"}),
]

TEXT = {
    "ja": {
        "title": "MrEditor — 要望と、その状況",
        "h1": "要望と、その状況",
        "lead": "いただいた要望を、すべて公開しています。**7日以内に、このリストと各ページで返事をします。**"
                "返事は、採用・検討中・やらない のどれかで、**「やらない」場合も、理由を必ず書きます。**"
                "採用した要望は、リリースの更新履歴に「この要望を採用した」と書きます。",
        "how": "送るには: アプリのヘルプメニューの「要望を送る…」から。または",
        "how_link": "GitHub で新しい要望を書く",
        "empty": "まだ要望はありません。最初の1件を、お待ちしています。",
        "by": "提案", "opened": "受付", "closed": "完了", "reason": "理由",
        "updated": "更新", "other": "状況の確認中", "switch": "English", "switch_href": "requests.html",
        "overdue": "期限超過", "count": "件",
    },
    "en": {
        "title": "MrEditor — Requests and their status",
        "h1": "Requests and their status",
        "lead": "Every request we receive is listed here. **We reply within 7 days, on this list and on each page** — "
                "adopted, considering, or not doing, and **when it is \"not doing\", the reason is always written.** "
                "A request we adopt is named in the release notes.",
        "how": "To send one: Help menu in the app → \"Send a Request…\", or",
        "how_link": "write a new request on GitHub",
        "empty": "No requests yet. We would be glad to get the first one.",
        "by": "by", "opened": "opened", "closed": "closed", "reason": "Reason",
        "updated": "Updated", "other": "Being sorted", "switch": "日本語", "switch_href": "requests.ja.html",
        "overdue": "overdue", "count": "",
    },
}


def gh_json(path):
    out = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"gh api {path}: {out.stderr.strip()[:200]}")
    text = out.stdout.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:                      # --paginate prints one array per page
        merged = []
        for chunk in re.split(r"(?<=\])\s*(?=\[)", text):
            merged.extend(json.loads(chunk))
        return merged


def fetch():
    issues = [i for i in gh_json(f"repos/{REPO}/issues?state=all&labels=request&per_page=100") if "pull_request" not in i]
    for i in issues:
        i["_comments"] = gh_json(f"repos/{REPO}/issues/{i['number']}/comments?per_page=100") if i.get("state_reason") == "not_planned" or any(l["name"] == "status:declined" for l in i["labels"]) else []
    return issues


def status_of(issue):
    names = {l["name"] for l in issue["labels"]}
    for label, key, _ in STATUSES:
        if label in names:
            return key
    if issue.get("state") == "closed":
        return "declined" if issue.get("state_reason") == "not_planned" else "done"
    return "received"


def reason_of(issue):
    """持ち主が書いた、最後の理由（短すぎるものは理由と認めない）。"""
    for c in reversed(issue.get("_comments", [])):
        body = (c.get("body") or "").strip()
        if c.get("user", {}).get("type") != "Bot" and c.get("author_association") in ("OWNER", "MEMBER", "COLLABORATOR") and len(body) >= MIN_REASON:
            return re.sub(r"\s+", " ", body)[:300] + ("…" if len(body) > 300 else "")
    return None


def esc(s):
    return html.escape(str(s), quote=True)


def md_bold(s):
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", esc(s))


def day(s):
    return (s or "")[:10]


def is_overdue(issue, now):
    return status_of(issue) == "received" and issue.get("state") == "open" and \
        (now - dt.datetime.fromisoformat(issue["created_at"].replace("Z", "+00:00"))).days >= DEADLINE_DAYS


def style_block():
    """サイトの他のページと同じ見た目（releases.ja.html の <style> を借りる）。"""
    try:
        m = re.search(r"<style>(.*?)</style>", (SITE / "releases.ja.html").read_text(encoding="utf-8"), re.S)
        base = m.group(1) if m else ""
    except OSError:
        base = ""
    return base + """
  .req-wrap{max-width:860px;margin:0 auto;padding:40px 22px 80px}
  .req-wrap h1{font-size:30px;margin-bottom:14px}
  .req-wrap h2{font-size:18px;margin:34px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--line)}
  .req-wrap p.lead{color:var(--fg);line-height:1.8;margin-bottom:12px}
  .req-wrap p.how{color:var(--mut);margin-bottom:6px}
  .req-wrap a{color:var(--teal)}
  .req-list{list-style:none;margin:0;padding:0}
  .req-list li{padding:11px 0;border-bottom:1px solid var(--line)}
  .req-list .t{font-weight:600}
  .req-list .m{color:var(--mut);font-size:13px;margin-top:3px}
  .req-list .r{margin-top:6px;padding:8px 12px;border-left:3px solid var(--amber);background:var(--card);font-size:14px;line-height:1.6}
  .req-badge{display:inline-block;font-size:12px;padding:1px 8px;border-radius:999px;background:var(--amber);color:#1b1200;margin-left:8px}
  .req-top{display:flex;justify-content:space-between;color:var(--mut);font-size:14px;margin-bottom:22px}
"""


def render(issues, lang, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    T = TEXT[lang]
    groups = {key: [] for _, key, _ in STATUSES}
    for i in sorted(issues, key=lambda x: x["created_at"], reverse=True):
        groups[status_of(i)].append(i)
    parts = []
    for label, key, heads in STATUSES:
        items = groups[key]
        if not items:
            continue
        lis = []
        for i in items:
            who = i.get("user", {}).get("login", "")
            overdue = f'<span class="req-badge">{esc(T["overdue"])}</span>' if is_overdue(i, now) else ""
            meta = f'#{int(i["number"])} · {esc(T["by"])} @{esc(who)} · {esc(T["opened"])} {esc(day(i["created_at"]))}'
            if key in ("done", "declined") and i.get("closed_at"):
                meta += f' · {esc(T["closed"])} {esc(day(i["closed_at"]))}'
            reason = reason_of(i) if key == "declined" else None
            rhtml = f'<div class="r"><b>{esc(T["reason"])}:</b> {esc(reason)}</div>' if reason else ""
            href = f"https://github.com/{REPO}/issues/{int(i['number'])}"      # built from the number, never from user text
            lis.append(f'<li><div class="t"><a href="{href}">{esc(i["title"])}</a>{overdue}</div><div class="m">{meta}</div>{rhtml}</li>')
        parts.append(f'<h2>{esc(heads[lang])} <span style="color:var(--mut);font-weight:400">({len(items)}{esc(T["count"])})</span></h2><ul class="req-list">{"".join(lis)}</ul>')
    body = "\n".join(parts) if parts else f'<p class="how">{esc(T["empty"])}</p>'
    new_issue = f"https://github.com/{REPO}/issues/new?template=request.yml"
    stamp = now.strftime("%Y-%m-%d %H:%M UTC")
    return f"""<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{esc(T["title"])}</title>
<style>{style_block()}</style>
</head>
<body>
<div class="req-wrap">
  <div class="req-top"><a href="index{'.ja' if lang == 'ja' else '.en'}.html">MrEditor</a><a href="{esc(T["switch_href"])}">{esc(T["switch"])}</a></div>
  <h1>{esc(T["h1"])}</h1>
  <p class="lead">{md_bold(T["lead"])}</p>
  <p class="how">{esc(T["how"])} <a href="{new_issue}">{esc(T["how_link"])}</a></p>
  {body}
  <p class="how" style="margin-top:40px">{esc(T["updated"])}: {esc(stamp)}</p>
</div>
</body>
</html>
"""


def main(argv):
    if "--fixture" in argv:
        issues = json.loads(Path(argv[argv.index("--fixture") + 1]).read_text(encoding="utf-8"))
    else:
        issues = fetch()
    SITE.mkdir(exist_ok=True)
    for lang, name in (("en", "requests.html"), ("ja", "requests.ja.html")):
        (SITE / name).write_text(render(issues, lang), encoding="utf-8")
    print(f"wrote site/requests.html and site/requests.ja.html ({len(issues)} requests)")


if __name__ == "__main__":
    main(sys.argv[1:])
