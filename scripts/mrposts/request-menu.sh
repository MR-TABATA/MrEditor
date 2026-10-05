#!/bin/sh
# MrPosts capture recipe: MrEditor's "Send a Request…" in the Help menu (v1.20.1), as a short mp4.
#
#   MRPOSTS_LOCALE=en    the app's own language for this run only (ja by default; -AppleLanguages "(en)",
#                        not saved).
#
# The recording is the main window plus the menu bar above it (the Help menu opens there). The window is
# moved to the top-left and narrowed first, so the menu bar's right side (status icons, clock) is outside
# the picture (and what is left of it is painted over). The two items are shown and the first is highlighted; it is NOT clicked, so no browser opens.
#
# What it does to your machine, and puts back:
#   - MrEditor's preferences are exported first and imported again at the end.
#   - It refuses to run while MrEditor is open. Your unsaved drafts are never written.
#   - The demo log lives in /tmp/mrposts-demo and is removed at the end.
# The sidebar below the first tab lists your unsaved tabs; it is painted over in the finished video.
#
# Needs Screen Recording and Accessibility permission for whatever runs it (the Terminal, or MrPosts).
set -eu

APP=${MRPOSTS_APP:-/Applications/MrEditor.app}
BID=com.aaedit.MrEditor
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${MRPOSTS_OUT:-$HERE/../../local/captures}
LOCALE=${MRPOSTS_LOCALE:-ja}
case "$LOCALE" in
  en) MENU_HELP="Help";     ITEM="Send a Request…"; SUFFIX="-en" ;;
  ja) MENU_HELP="ヘルプ";   ITEM="要望を送る…";    SUFFIX="" ;;
  *)  echo "MRPOSTS_LOCALE は ja か en です: $LOCALE" >&2; exit 1 ;;
esac
DEMO=/tmp/mrposts-demo
WIN_W=${MRPOSTS_WIN_W:-880}
WIN_H=${MRPOSTS_WIN_H:-520}
WIN_Y=${MRPOSTS_WIN_Y:-40}                 # the window's top, below the menu bar
SIDEBAR_PT=${MRPOSTS_SIDEBAR_PT:-200}
FIRST_TAB_END_PT=${MRPOSTS_FIRST_TAB_END_PT:-92}
STATUS_PT=${MRPOSTS_STATUS_PT:-30}
BAR_PAINT_FROM_PT=${MRPOSTS_BAR_PAINT_FROM_PT:-560}   # right of the Help menu: other apps' status icons, painted over

[ -d "$APP" ] || { echo "MrEditor.app が見つかりません: $APP" >&2; exit 1; }
if pgrep -x MrEditor >/dev/null; then
  echo "MrEditor が起動中です。作業中のウィンドウに触れないよう、終了してから実行してください。" >&2
  exit 1
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg が要ります: brew install ffmpeg" >&2; exit 1; }
command -v magick >/dev/null || { echo "ImageMagick（magick）が要ります: brew install imagemagick" >&2; exit 1; }

mkdir -p "$OUT"
WORK=$(mktemp -d /tmp/mrposts-mredit-XXXXXX)
BACKUP="$WORK/defaults.plist"
HAD_DEFAULTS=0
if defaults export "$BID" "$BACKUP" 2>/dev/null; then HAD_DEFAULTS=1; fi

restore() {
  osascript -e 'tell application "MrEditor" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -x MrEditor >/dev/null && [ $i -lt 40 ]; do sleep 0.5; i=$((i+1)); done
  if [ $HAD_DEFAULTS = 1 ]; then
    defaults import "$BID" "$BACKUP" 2>/dev/null || echo "警告: 環境設定を戻せませんでした（退避: $BACKUP）" >&2
  fi
  rm -rf "$WORK" /tmp/mrposts-demo
}
trap restore EXIT INT TERM

rm -rf "$DEMO"; mkdir -p "$DEMO"
awk 'BEGIN { for (i = 1; i <= 80; i++) printf "2026-10-05T09:%02d:%02d+09:00 [%s] request_id=%d status=%d path=/api/v1/%s latency=%dms\n", int(i/60), i%60, (i%9==0?"WARN ":"INFO "), i, (i%9==0?404:200), (i%3==0?"orders":"users"), 12+i%17 }' > "$DEMO/app.log"

windows() { osascript -l JavaScript "$HERE/window_id.js" MrEditor 2>/dev/null || true; }

echo "MrEditor を起動します"
if [ "$LOCALE" = en ]; then ARGS="--args -AppleLanguages (en)"; else ARGS=""; fi
# shellcheck disable=SC2086
open -a "$APP" "$DEMO/app.log" $ARGS
i=0
while [ -z "$(windows)" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
[ -n "$(windows)" ] || { echo "MrEditor のウィンドウが出ませんでした" >&2; exit 1; }
sleep 2.5
osascript -e 'tell application "MrEditor" to activate' >/dev/null 2>&1 || true
sleep 0.5

# Top-left, narrow: the menu bar's right side stays out of the recording.
osascript <<APPLESCRIPT >/dev/null 2>&1 || { echo "ウィンドウを動かせません（アクセシビリティの許可が要ります）" >&2; exit 1; }
tell application "System Events"
  tell process "MrEditor"
    set w to window 1
    set position of w to {0, $WIN_Y}
    set size of w to {$WIN_W, $WIN_H}
  end tell
end tell
APPLESCRIPT
sleep 1.0
set -- $(windows | head -1)
MW=$2; MH=$3; MX=$4; MY=$5
RH=$((MY + MH))                              # region height: from the top of the screen to the window's bottom

# Where the menu item is on screen (the menu must be open for it to exist).
open_help() {
  osascript <<APPLESCRIPT >/dev/null 2>"$WORK/menu.err" || { echo "メニューを開けません: $(cat "$WORK/menu.err")" >&2; exit 1; }
tell application "System Events"
  tell process "MrEditor"
    perform action "AXPress" of menu bar item "$MENU_HELP" of menu bar 1
  end tell
end tell
APPLESCRIPT
}
item_geo() {
  osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "MrEditor"
    set mi to menu item "$ITEM" of menu 1 of menu bar item "$MENU_HELP" of menu bar 1
    set p to position of mi
    set z to size of mi
    return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of z) as text) & " " & ((item 2 of z) as text)
  end tell
end tell
APPLESCRIPT
}
move_mouse() {
  osascript -l JavaScript >/dev/null 2>&1 <<JXA || true
ObjC.import('CoreGraphics');
const e = $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, $.CGPointMake($1, $2), $.kCGMouseButtonLeft);
$.CGEventPost($.kCGHIDEventTap, e);
JXA
}

SECS=${MRPOSTS_VIDEO_SECS:-12}
RAW="$WORK/raw.mov"
echo "録画します（約10秒・触らないこと）"
move_mouse $((MW + 200)) $((MY + MH / 2))      # the pointer out of the way, to the right of the window
screencapture -v -V "$SECS" -x -R"0,0,$MW,$RH" "$RAW" &
REC=$!
T0=$(date +%s)
sleep 2.0                                       # the window with the log, as it starts
open_help; sleep 1.6                            # the Help menu opens
GEO=$(item_geo)
[ -n "$GEO" ] || { echo "「$ITEM」が見つかりません" >&2; exit 1; }
set -- $GEO
move_mouse $(( ${1%%.*} + 40 )) $(( ${2%%.*} + ${4%%.*} / 2 )); sleep 3.5   # the item, highlighted
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true   # Escape: closes the menu, clicks nothing
sleep 1.4
DUR=$(( $(date +%s) - T0 + 1 ))
wait $REC 2>/dev/null || true
[ -s "$RAW" ] || { echo "録画できませんでした。システム設定の「画面収録」を許可してください" >&2; exit 1; }

# Finish: paint over the sidebar's other tabs, square off the window's rounded corners, scale, h264.
RW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$RAW")
SC=$((RW / MW))
ffmpeg -y -loglevel error -ss 0.6 -i "$RAW" -frames:v 1 "$WORK/frame.png"
px() { magick "$WORK/frame.png" -crop 1x1+"$1"+"$2" -format '%[hex:u]' info: | cut -c1-6; }
SBC=$(px $((100 * SC)) $(((RH - 70) * SC)))
TOPC=$(px $(((MW * 6 / 10) * SC)) $(((MY + 6) * SC)))
BOTC=$(px $(((MW * 6 / 10) * SC)) $(((RH - 6) * SC)))
C=$((16 * SC))
BARC=$(px $((BAR_PAINT_FROM_PT * SC - 8)) $((14 * SC)))
Y0=$((MY * SC))
VF="drawbox=x=0:y=$(((MY + FIRST_TAB_END_PT) * SC)):w=$((SIDEBAR_PT * SC)):h=$(((MH - STATUS_PT - FIRST_TAB_END_PT) * SC)):color=0x$SBC:t=fill"
VF="$VF,drawbox=x=0:y=$Y0:w=$C:h=$C:color=0x$TOPC:t=fill,drawbox=x=$((RW - C)):y=$Y0:w=$C:h=$C:color=0x$TOPC:t=fill"
VF="$VF,drawbox=x=0:y=$((RH * SC - C)):w=$C:h=$C:color=0x$BOTC:t=fill,drawbox=x=$((RW - C)):y=$((RH * SC - C)):w=$C:h=$C:color=0x$BOTC:t=fill"
VF="$VF,drawbox=x=$((BAR_PAINT_FROM_PT * SC)):y=0:w=$(((MW - BAR_PAINT_FROM_PT) * SC)):h=$((28 * SC)):color=0x$BARC:t=fill"
VF="$VF,scale=1280:-2"
ffmpeg -y -loglevel error -ss 0.6 -t "$DUR" -i "$RAW" -vf "$VF" -c:v libx264 -pix_fmt yuv420p -movflags +faststart -an "$OUT/mreditor-request-menu$SUFFIX.mp4"
echo "保存: $OUT/mreditor-request-menu$SUFFIX.mp4"
