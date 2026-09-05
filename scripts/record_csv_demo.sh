#!/bin/sh
# 「絞り込んで、直して、元の形式のまま保存」を録る。カットなし・等倍の一発撮り。
#
#   sh scripts/record_csv_demo.sh
#
# 出力: build/csvdemo/raw.mov（無加工）, build/csvdemo/demo.mp4, build/csvdemo/proof.txt
# 台本は scripts/csv_demo_driver.swift。
#
# 題材は実物の法人全件 CSV（1.06GB・Shift-JIS・CRLF・引用符つき）。
# **原本は触らない。** 作業用のコピーを作り、そのコピーを開いて保存する。
# 撮ったあと、コピーと原本を byte で突き合わせて「直した行の外は 1 バイトも
# 変わっていない」ことを proof.txt に出す ── 画面では見えない部分がそこなので。
#
# 必要な権限（どちらもターミナル側に付与すること）:
#   - アクセシビリティ（CGEvent と AX でウィンドウを置く）
#   - 画面収録（screencapture -v）
#
# 注意: 撮影中はキーを触らないこと。CGEvent は前面アプリに飛ぶ。

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/.build/MrEditor.app"
OUT="$ROOT/build/csvdemo"
BID=com.aaedit.MrEditor
SRC="$ROOT/testdata/houjin_zenken_sjis.csv"     # 原本（読むだけ）
WORK="$OUT/houjin_demo.csv"                     # 作業用コピー（これを開いて保存する）
SHOT=0,29,1280,748
SECS=45
WARMUP=1.5

[ -d "$APP" ] || { echo "先に .app をビルドすること: sh scripts/make_app.sh" >&2; exit 1; }
[ -f "$SRC" ] || { echo "$SRC がない" >&2; exit 1; }

mkdir -p "$OUT"

echo "==> ドライバをビルド"
swiftc -O "$ROOT/scripts/csv_demo_driver.swift" -o "$OUT/csv_demo_driver"

echo "==> 作業用コピーを作る（原本は触らない）"
rm -f "$WORK"
cp "$SRC" "$WORK"
BEFORE="$OUT/before.csv"
rm -f "$BEFORE"
cp "$SRC" "$BEFORE"          # 突き合わせ用の控え
ls -l "$WORK" | awk '{print "    "$5" bytes"}'

echo "==> 環境設定を退避（撮影後に戻す）"
BACKUP="$OUT/defaults.backup.plist"
defaults export "$BID" "$BACKUP" 2>/dev/null || echo "(設定なし)"
restore() {
    echo "==> 環境設定を復元"
    [ -f "$BACKUP" ] && defaults import "$BID" "$BACKUP" 2>/dev/null || true
}
trap restore EXIT INT TERM

echo "==> 空のエディタから始める＋検索は絞り込み ON で開くようにする"
defaults delete "$BID" MrEditor.session 2>/dev/null || true
defaults write "$BID" MrEditor.searchFilterOn -bool YES

echo "==> アプリを起動"
pkill -x MrEditor 2>/dev/null || true
sleep 1
open -a "$APP"
sleep 2.5

echo "==> ウィンドウを録画枠に設置"
"$OUT/csv_demo_driver" place "$WORK"
sleep 1

echo "==> 録画開始（${SECS}秒・触らないこと）"
rm -f "$OUT/raw.mov"
screencapture -v -V "$SECS" -R "$SHOT" -D 1 "$OUT/raw.mov" &
REC=$!
sleep "$WARMUP"

echo "==> 台本を演じる"
"$OUT/csv_demo_driver" act "$WORK" | tee "$OUT/timing.txt"

echo "==> 録画の終了を待つ"
wait $REC 2>/dev/null || true

# 尺は台本が吐いた実時刻から決める（勘で決めると着地が切れる）。
END_AT=$(awk '/^END_AT/ {print $2}' "$OUT/timing.txt")
[ -n "$END_AT" ] || { echo "台本が途中で失敗している" >&2; exit 1; }
START=$(echo "$WARMUP + 0.4" | bc)
DUR=$(echo "$END_AT + 0.6" | bc)

echo "==> 書き出し: ${START}s から ${DUR}s"
ffmpeg -y -loglevel error -ss "$START" -t "$DUR" -i "$OUT/raw.mov" \
    -vf "scale=1280:748:flags=lanczos" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p \
    -crf 30 -preset slow -tune stillimage \
    -movflags +faststart -an \
    "$OUT/demo.mp4"

# ── 画面では見えないところを byte で示す ────────────────────────────────
echo "==> 突き合わせ"
{
    echo "原本      : $SRC"
    echo "保存後    : $WORK"
    echo
    echo "--- 大きさ ---"
    ls -l "$BEFORE" "$WORK" | awk '{print $5"\t"$NF}'
    echo
    echo "--- 最初に食い違う byte（= 直した行だけ）---"
    cmp "$BEFORE" "$WORK" || true
    echo
    echo "--- 先頭 16 byte（BOM が足されていない）---"
    head -c 16 "$WORK" | xxd
    echo
    echo "--- CR の数（CRLF が LF に落ちていない）---"
    printf "原本   : "; LC_ALL=C tr -dc '\r' < "$BEFORE" | wc -c
    printf "保存後 : "; LC_ALL=C tr -dc '\r' < "$WORK"   | wc -c
    echo
    echo "--- 引用符の数（付け直されていない）---"
    printf "原本   : "; LC_ALL=C tr -dc '\"' < "$BEFORE" | wc -c
    printf "保存後 : "; LC_ALL=C tr -dc '\"' < "$WORK"   | wc -c
    echo
    echo "--- 文字コード（Shift-JIS のまま）---"
    file "$WORK"
} | tee "$OUT/proof.txt"

echo
echo "できた:"
ls -la "$OUT/demo.mp4" "$OUT/proof.txt"
echo
echo "作業用コピーは大きい。要らなければ消す:"
echo "  rm -f $WORK $BEFORE $OUT/raw.mov"
