#!/bin/sh
# GitHub Releases の dmg ダウンロード数を CSV に1行1レコードで記録する。
#
# GitHub API は「今の累計」しか返さず履歴を持たない。定期的に撮ったスナップショット
# の差分だけが「この週に何件増えたか」を答えられる唯一の材料なので、値そのものより
# 撮り続けることに意味がある。
#
# 使い方:
#   sh scripts/metrics_snapshot.sh          # 追記して差分を表示
#   OUT=/tmp/x.csv sh scripts/metrics_snapshot.sh
#
# 注意: download_count はユニークな人数ではない。クローラも、更新チェッカ経由で
# 新版を取り直した既存利用者も 1 件として乗る。人数として引用しないこと。
set -eu

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
OUT="${OUT:-docs/metrics/downloads.csv}"
TODAY="$(date -u +%Y-%m-%d)"

mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || printf 'date,tag,asset,downloads\n' > "$OUT"

# 直前の合計（差分表示用。ファイルの最終行の日付を「前回」とみなす）
PREV_DATE="$(awk -F, 'NR>1 {gsub(/"/,"",$1); d=$1} END {print d}' "$OUT")"
PREV_TOTAL="$(awk -F, -v d="$PREV_DATE" 'NR>1 {gsub(/"/,"",$1); if ($1==d) s+=$4} END {print s+0}' "$OUT")"

# 同じ日を撮り直したら古い方を捨てる（cron と手動実行が同日に重なった場合）
if grep -q "^\"$TODAY\"," "$OUT" 2>/dev/null; then
	grep -v "^\"$TODAY\"," "$OUT" > "$OUT.tmp"
	mv "$OUT.tmp" "$OUT"
fi

gh api "repos/$REPO/releases" --paginate \
	-q '.[] | .tag_name as $t | .assets[] | select(.name|endswith(".dmg")) | [$t, .name, .download_count] | @csv' \
	| sed "s|^|\"$TODAY\",|" >> "$OUT"

TOTAL="$(awk -F, -v d="$TODAY" 'NR>1 {gsub(/"/,"",$1); if ($1==d) s+=$4} END {print s+0}' "$OUT")"

printf '%s  合計 %s' "$TODAY" "$TOTAL"
if [ -n "$PREV_DATE" ] && [ "$PREV_DATE" != "$TODAY" ]; then
	printf '  (%s から %+d)' "$PREV_DATE" "$((TOTAL - PREV_TOTAL))"
fi
printf '\n'
