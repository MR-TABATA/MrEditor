#!/bin/sh
# 「CSV を絞り込んで、直して、元の形式のまま保存できるのか」を端末で示す。
#
#   sh scripts/prove_csv_roundtrip.sh
#
# 2026-09-05 に Threads で聞かれた質問への答え。画面録画は要らない
# （権限も要らず、machine を占有しない）。そのまま貼れる出力を 1 本吐く。
#
# 題材は実物の法人全件 CSV（1.06GB・Shift-JIS・CRLF・引用符つき）。
# **原本は触らない。** 作業用のコピーを作り、そちらを開いて・直して・保存し、
# 原本と byte で突き合わせる。
#
# 見せたいのは「壊れない」ではなく **「触っていないところは 1 バイトも通り抜けている」**。
# piece table が原本を生バイトで持ち、保存がその断片をそのまま書き出すので、
# 直した行の外は変換を通らない。だから BOM も CRLF も引用符も「残す」実装が要らない。

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${MREDITOR_CSV_SRC:-$ROOT/testdata/houjin_zenken_sjis.csv}"
OUT="$ROOT/build/csvproof"
WORK="$OUT/work.csv"
TERM_="${MREDITOR_CSV_TERM:-東京都}"

[ -f "$SRC" ] || { echo "$SRC がない" >&2; exit 1; }
mkdir -p "$OUT"

echo "原本: $SRC"
ls -l "$SRC" | awk '{printf "      %s byte\n", $5}'
echo
echo "==> 作業用コピーを作る（原本は触らない）"
rm -f "$WORK"
cp "$SRC" "$WORK"

echo
echo "==> 開く → 絞り込む → 直す → 保存する（アプリと同じ経路）"
MREDITOR_CSV_WORK="$WORK" MREDITOR_CSV_TERM="$TERM_" \
    swift test --filter testRealHoujinCsvWhole 2>/dev/null \
    | grep -E "^  (開く|絞り込む|直す|保存する)"

echo
echo "==> 原本と突き合わせる"
echo
echo "--- 大きさ（足したぶんだけ増えている）---"
BEFORE=$(wc -c < "$SRC" | tr -d ' ')
AFTER=$(wc -c < "$WORK" | tr -d ' ')
echo "原本   : $BEFORE byte"
echo "保存後 : $AFTER byte  (+$((AFTER - BEFORE)))"

echo
echo "--- 最初に食い違う byte（= 直した 1 行だけ）---"
cmp "$SRC" "$WORK" || true

echo
echo "--- 直した行の前後が原本と同じか ---"
DIFF_AT=$(cmp "$SRC" "$WORK" 2>/dev/null | sed -E 's/.*byte ([0-9]+),.*/\1/' || true)
if [ -n "${DIFF_AT:-}" ]; then
    HEAD=$((DIFF_AT - 1))
    if cmp -n "$HEAD" "$SRC" "$WORK" >/dev/null 2>&1; then
        echo "前 ($HEAD byte): 一致"
    else
        echo "前 ($HEAD byte): 食い違う"; exit 1
    fi
    ADDED=$((AFTER - BEFORE))
    if cmp -i "$HEAD:$((HEAD + ADDED))" "$SRC" "$WORK" >/dev/null 2>&1; then
        echo "後 ($((BEFORE - HEAD)) byte): 一致"
    else
        echo "後: 食い違う"; exit 1
    fi
fi

echo
echo "--- 先頭 16 byte（無かった BOM が足されていない）---"
head -c 16 "$WORK" | xxd

echo
echo "--- CR の数（CRLF が LF に落ちていない）---"
printf "原本   : "; LC_ALL=C tr -dc '\r' < "$SRC"  | wc -c | tr -d ' '
printf "保存後 : "; LC_ALL=C tr -dc '\r' < "$WORK" | wc -c | tr -d ' '

echo
echo "--- 引用符の数（付け直されていない）---"
printf "原本   : "; LC_ALL=C tr -dc '"' < "$SRC"  | wc -c | tr -d ' '
printf "保存後 : "; LC_ALL=C tr -dc '"' < "$WORK" | wc -c | tr -d ' '

echo
echo "--- 直した行（Shift-JIS のまま読める）---"
sed -n "$(LC_ALL=C awk -v d="${DIFF_AT:-1}" 'BEGIN{print 1}')"p /dev/null 2>/dev/null || true
LC_ALL=C dd if="$WORK" bs=1 skip=$((${DIFF_AT:-1} - 260)) count=400 2>/dev/null \
    | iconv -f SHIFT_JIS -t UTF-8 2>/dev/null | sed -n '2p' | cut -c1-160

echo
echo "作業用コピーは大きい。要らなければ消す:"
echo "  rm -f $WORK"
