#!/bin/sh
# GitHub Traffic API（views/clones）を、直近14日ローリング集計のスナップショットとして記録する。
#
# downloads.csv（metrics_snapshot.sh）と違い、views/clones は「今の累計」ではなく
# 「直近14日間の集計」なので、前回より減っても異常ではない。よって減少チェックはしない。
# 撮り続けること自体に意味がある（撮り漏らした日は API 側にも残らず復元できない）。
#
# 正はブランチ `metrics`（main には無い。理由は metrics_snapshot.sh 参照）。
#
# 使い方:
#   sh scripts/traffic_snapshot.sh
#   DRY_RUN=1 sh scripts/traffic_snapshot.sh  # CSV に書かずに値だけ見る
#   OUT=/tmp/x.csv sh scripts/traffic_snapshot.sh
#
# Traffic API は Administration:read 権限が要る。既定の GITHUB_TOKEN では取れないことが
# ある（MrkAppRelease で実際に token_required が発生した実績あり）ため、呼び出し側の
# ワークフローで secrets.TRAFFIC_TOKEN を優先し、無ければ GITHUB_TOKEN にフォールバックする。
#
# 壊れた値を書かないための約束:
#   - gh api が失敗したら書かない（パイプで握り潰さない）。
set -eu

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
DATA_BRANCH="${DATA_BRANCH:-metrics}"
OUT="${OUT:-}"
DRY_RUN="${DRY_RUN:-}"

# OUT が指定されていなければ、正（ブランチ metrics）を作業コピーへ引いてくる。
if [ -z "$OUT" ]; then
	OUT=".metrics/traffic.csv"
	mkdir -p "$(dirname "$OUT")"
	if git rev-parse --git-dir >/dev/null 2>&1; then
		git fetch -q origin "$DATA_BRANCH" 2>/dev/null || true
		if git cat-file -e "FETCH_HEAD:traffic.csv" 2>/dev/null; then
			git show "FETCH_HEAD:traffic.csv" > "$OUT"
			echo "ブランチ $DATA_BRANCH から $OUT へ引いた（手元の結果は push しない）"
		fi
	fi
fi
AT="${AT:-$(date -u +%Y-%m-%dT%H:%MZ)}"

mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || printf 'taken_at,views_14d,unique_views_14d,clones_14d,unique_clones_14d\n' > "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! views_json="$(gh api "repos/$REPO/traffic/views" 2>"$WORK/err")"; then
	echo "views の取得に失敗した。CSV は変更していない。" >&2
	cat "$WORK/err" >&2
	exit 1
fi
if ! clones_json="$(gh api "repos/$REPO/traffic/clones" 2>"$WORK/err")"; then
	echo "clones の取得に失敗した。CSV は変更していない。" >&2
	cat "$WORK/err" >&2
	exit 1
fi

views="$(printf '%s' "$views_json" | jq -r '.count')"
unique_views="$(printf '%s' "$views_json" | jq -r '.uniques')"
clones="$(printf '%s' "$clones_json" | jq -r '.count')"
unique_clones="$(printf '%s' "$clones_json" | jq -r '.uniques')"

if [ -z "$DRY_RUN" ]; then
	grep -v "^\"$AT\"," "$OUT" > "$WORK/out" 2>/dev/null || true
	printf '"%s",%s,%s,%s,%s\n' "$AT" "$views" "$unique_views" "$clones" "$unique_clones" >> "$WORK/out"
	mv "$WORK/out" "$OUT"
fi

printf '%s  views=%s(uniq %s)  clones=%s(uniq %s)' "$AT" "$views" "$unique_views" "$clones" "$unique_clones"
if [ -n "$DRY_RUN" ]; then
	printf '  [DRY_RUN: CSV は書いていない]'
fi
printf '\n'
