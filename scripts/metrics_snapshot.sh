#!/bin/sh
# GitHub Releases の dmg ダウンロード数を CSV に1行1レコードで記録する。
#
# GitHub API は「今の累計」しか返さず履歴を持たない。定期的に撮ったスナップショット
# の差分だけが「この週に何件増えたか」を答えられる唯一の材料なので、値そのものより
# 撮り続けることに意味がある。
#
# 使い方:
#   sh scripts/metrics_snapshot.sh            # 追記して差分を表示
#   DRY_RUN=1 sh scripts/metrics_snapshot.sh  # CSV に書かずに差分だけ見る
#   OUT=/tmp/x.csv sh scripts/metrics_snapshot.sh
#   FORCE=1 sh scripts/metrics_snapshot.sh    # 整合性チェックを承知の上で無視する
#
# CSV の正はブランチ `metrics`（main には無い）。OUT を指定しなければ、そこから
# .metrics/downloads.csv へ引いてきて、その上に撮る。手元の結果は push しない
# ＝見るためのもの。記録するのは Actions。
#
# なぜ main に置かないのか: main のルールセットは required_status_checks を要求し、
# ボットの直 push には PR が無いので `test` が走らない。構造上どうやっても通らない
# （2026-08-24 の撮影がこれで落ちた）。
#
# 1 行目は日付でなく UTC の時刻（分まで）。リリース公開の瞬間と、その日の定時撮影は
# 別の意味を持つ ── 前者は「告知前の基準値」で、日付で丸めると後から来た方に
# 上書きされて消える。だから同じ日に何度撮っても全部残す。
#
# 壊れた値を書かないための約束（どれかに触れたら CSV を変更せずに終了する）:
#   - gh api が失敗したら書かない。パイプで握り潰さない。
#   - 0 行しか返らなかったら書かない。
#   - 前回より資産の数が減っていたら書かない（ページング取りこぼしの兆候）。
#   - 個々の版のダウンロード数が前回より減っていたら書かない（資産の貼り直しか誤取得）。
#
# 注意: download_count はユニークな人数ではない。クローラも、更新チェッカ経由で
# 新版を取り直した既存利用者も 1 件として乗る。人数として引用しないこと。
set -eu

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
DATA_BRANCH="${DATA_BRANCH:-metrics}"
OUT="${OUT:-}"

# OUT が指定されていなければ、正（ブランチ metrics）を作業コピーへ引いてくる。
# 毎回引き直すのは、古い作業コピーの上に撮ると前回差分が嘘になるため。
if [ -z "$OUT" ]; then
	OUT=".metrics/downloads.csv"
	mkdir -p "$(dirname "$OUT")"
	if git rev-parse --git-dir >/dev/null 2>&1; then
		git fetch -q origin "$DATA_BRANCH" 2>/dev/null || true
		if git cat-file -e "FETCH_HEAD:downloads.csv" 2>/dev/null; then
			git show "FETCH_HEAD:downloads.csv" > "$OUT"
			echo "ブランチ $DATA_BRANCH から $OUT へ引いた（手元の結果は push しない）"
		fi
	fi
fi
AT="${AT:-$(date -u +%Y-%m-%dT%H:%MZ)}"
DRY_RUN="${DRY_RUN:-}"
FORCE="${FORCE:-}"

mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || printf 'taken_at,tag,asset,downloads\n' > "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1) 取得。パイプに繋ぐと gh の失敗が sed の成功に化けるので、いったんファイルに落とす。
if ! gh api "repos/$REPO/releases" --paginate \
	-q '.[] | .tag_name as $t | .assets[] | select(.name|endswith(".dmg")) | [$t, .name, .download_count] | @csv' \
	> "$WORK/raw" 2>"$WORK/err"; then
	echo "取得に失敗した。CSV は変更していない。" >&2
	cat "$WORK/err" >&2
	exit 1
fi

ROWS="$(grep -c . "$WORK/raw" || true)"
if [ "$ROWS" -eq 0 ]; then
	echo "dmg が 1 件も返ってこなかった。CSV は変更していない。" >&2
	exit 1
fi

# 2) 前回のスナップショット（＝今日を除いた最後の日付）を取り出して突き合わせる。
PREV_AT="$(awk -F, -v t="\"$AT\"" '$1!=t && NR>1 {gsub(/"/,"",$1); d=$1} END {print d}' "$OUT")"
if [ -n "$PREV_AT" ]; then
	awk -F, -v d="$PREV_AT" 'NR>1 {gsub(/"/,"",$1); if ($1==d) {gsub(/"/,"",$3); print $3"\t"$4}}' "$OUT" \
		| sort > "$WORK/prev"
	awk -F, '{gsub(/"/,"",$2); print $2"\t"$3}' "$WORK/raw" | sort > "$WORK/now"

	# 資産が消えた／数が減った＝取りこぼしか貼り直し。どちらも「今の累計」として信用できない。
	join -t"$(printf '\t')" -a1 -e '' -o 0,1.2,2.2 "$WORK/prev" "$WORK/now" \
		| awk -F"$(printf '\t')" '$3=="" {printf "  %s: 前回 %s → 今回は返ってこなかった\n", $1, $2}
		                          $3!="" && $3+0 < $2+0 {printf "  %s: 前回 %s → 今回 %s（減っている）\n", $1, $2, $3}' \
		> "$WORK/bad"

	if [ -s "$WORK/bad" ]; then
		echo "前回 ($PREV_AT) と矛盾する値が返ってきた:" >&2
		cat "$WORK/bad" >&2
		if [ -z "$FORCE" ]; then
			echo "CSV は変更していない。意図した変化なら FORCE=1 を付けて撮り直す。" >&2
			exit 1
		fi
		echo "FORCE=1 なのでこのまま記録する。" >&2
	fi
	PREV_TOTAL="$(awk -F"$(printf '\t')" '{s+=$2} END {print s+0}' "$WORK/prev")"
else
	PREV_TOTAL=0
fi

TOTAL="$(awk -F, '{s+=$3} END {print s+0}' "$WORK/raw")"

# 3) ここまで通ってはじめて CSV に触る。同じ分に二度走った場合だけ古い方を捨てる。
if [ -z "$DRY_RUN" ]; then
	grep -v "^\"$AT\"," "$OUT" > "$WORK/out" || true
	sed "s|^|\"$AT\",|" "$WORK/raw" >> "$WORK/out"
	mv "$WORK/out" "$OUT"
fi

# 4) 報告。合計だけでなく、どの版が動いたかまで出す（告知の効き目はここにしか出ない）。
printf '%s  合計 %s 件 / %s 版' "$AT" "$TOTAL" "$ROWS"
if [ -n "$DRY_RUN" ]; then
	printf '  [DRY_RUN: CSV は書いていない]'
fi
if [ -n "$PREV_AT" ]; then
	printf '  (%s から %+d)\n' "$PREV_AT" "$((TOTAL - PREV_TOTAL))"
	# 伸びた順に並べる。sort に "+9" を数として渡すと BSD 版が読まないので、
	# 数値だけで並べてから整形する。
	join -t"$(printf '\t')" -a2 -e 0 -o 0,1.2,2.2 "$WORK/prev" "$WORK/now" \
		| awk -F"$(printf '\t')" '$3+0 > $2+0 {printf "%d\t%s\t%s\n", $3-$2, $1, $3}' \
		| sort -nr \
		| awk -F"$(printf '\t')" '{printf "  %-28s %+d  (累計 %s)\n", $2, $1, $3}'
else
	printf '\n'
fi
