#!/bin/sh
# LP 用のデモ録画を撮り直す。カットなし・等倍の一発撮り（約33秒）。
#
#   sh scripts/record_demo.sh
#
# 出力: build/demo/raw.mov（無加工）, build/demo/demo.mp4（LP 用）, build/demo/poster.jpg
# 台本は scripts/demo_driver.swift。画は CGEvent で自動操作するので、撮り直しは再実行するだけ。
#
# 必要な権限:
#   - アクセシビリティ（CGEvent と AX でウィンドウを置く）
#   - 画面収録（screencapture -v）
# どちらもターミナル側に付与すること。
#
# 注意: 撮影中はキーを触らないこと。CGEvent は前面アプリに飛ぶ。

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/.build/MrEditor.app"
OUT="$ROOT/build/demo"
BID=com.aaedit.MrEditor
SHOT=0,29,1280,748          # メニューバーを除いた可視領域（= 1280x748）
SECS=45                     # 多めに回して、切り出しは台本が吐く実時刻に従わせる
WARMUP=1.5                  # 録画開始から台本開始までの間

[ -d "$APP" ] || { echo "先に .app をビルドすること: sh scripts/make_app.sh" >&2; exit 1; }
[ -f "$ROOT/testdata/test_10gb.log" ] || { echo "testdata/test_10gb.log がない" >&2; exit 1; }

mkdir -p "$OUT"

echo "==> ドライバをビルド"
swiftc -O "$ROOT/scripts/demo_driver.swift" -o "$OUT/demo_driver"

echo "==> 環境設定を退避（撮影後に戻す）"
BACKUP="$OUT/defaults.backup.plist"
defaults export "$BID" "$BACKUP" 2>/dev/null || echo "(設定なし)"
restore() {
    echo "==> 環境設定を復元"
    [ -f "$BACKUP" ] && defaults import "$BID" "$BACKUP" 2>/dev/null || true
}
trap restore EXIT INT TERM

echo "==> 空のエディタから始めるため、セッションを空にする"
defaults delete "$BID" MrEditor.session 2>/dev/null || true

echo "==> アプリを起動"
pkill -x MrEditor 2>/dev/null || true
sleep 1
open -a "$APP"
sleep 2.5

echo "==> ウィンドウを録画枠に設置"
"$OUT/demo_driver" place
sleep 1

echo "==> 録画開始（${SECS}秒・触らないこと）"
rm -f "$OUT/raw.mov"
screencapture -v -V "$SECS" -R "$SHOT" -D 1 "$OUT/raw.mov" &
REC=$!
sleep "$WARMUP"              # 録画の立ち上がりを待つ

echo "==> 台本を演じる"
"$OUT/demo_driver" act | tee "$OUT/timing.txt"

# 中断すると末尾が書き出されずに落ちる。-V の秒数まで回し切らせ、余りは切り出しで捨てる。
echo "==> 録画の終了を待つ（残り約 $(echo "$SECS - 32" | bc) 秒）"
wait $REC 2>/dev/null || true
echo "==> 録画終了: $OUT/raw.mov"

# 尺は台本が吐いた実時刻から決める。勘で決めると、前回のように着地が切れる。
JUMP=$(awk '/^JUMP_AT/ {print $2}' "$OUT/timing.txt")
[ -n "$JUMP" ] || { echo "着地の時刻が取れていない（台本が途中で失敗した）" >&2; exit 1; }
START=$(echo "$WARMUP + 0.6" | bc)          # 空のエディタを 0.8 秒だけ見せる
END=$(echo "$WARMUP + $JUMP + 2.2" | bc)    # 着地を 2.2 秒見せて終わる
DUR=$(echo "$END - $START" | bc)
echo "==> 切り出し: ${START}s から ${DUR}s（着地は台本開始から ${JUMP}s）"

echo "==> LP 用に書き出し"
# raw は Retina 2x（2560x1496）。1280x748 に落として h264。音声なし・Web 先頭最適化。
ffmpeg -y -loglevel error -ss "$START" -t "$DUR" -i "$OUT/raw.mov" \
    -vf "scale=1280:748:flags=lanczos" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p \
    -crf 30 -preset slow -tune stillimage \
    -movflags +faststart -an \
    "$OUT/demo.mp4"

# ポスターは「10GB が描画された直後」の1枚。切り出し後の時間軸で約 6 秒。
ffmpeg -y -loglevel error -ss 6 -i "$OUT/demo.mp4" -frames:v 1 -q:v 3 "$OUT/poster.jpg"

echo
echo "できた:"
ls -la "$OUT/demo.mp4" "$OUT/poster.jpg"
echo
echo "確認してよければ site へ:"
echo "  cp $OUT/demo.mp4    site/media/mreditor-10gb.mp4"
echo "  cp $OUT/poster.jpg  site/media/poster.jpg"
