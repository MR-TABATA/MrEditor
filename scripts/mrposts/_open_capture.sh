#!/bin/sh
# MrPosts capture recipe, shared part: open one file in MrEditor and take a picture of the window.
#
#   _open_capture.sh <file> <output name>
#
# What it does to your machine, and puts back:
#   - MrEditor's preferences are exported first and imported again at the end (line wrap is
#     switched off while it runs — wrapped lines overlap while a huge file is still indexing).
#   - It refuses to run while MrEditor is open, so it never touches a live session. Unsaved drafts
#     (~/Library/Application Support/MrEditor/Drafts) are never written by this script.
# The picture is cropped to the editor pane and status bar: the sidebar lists your own unsaved
# tabs, and they have no business in a post.
#
# Optional third argument: a menu path to run before taking the picture, "Menu>Item" or
# "Menu>Item>Sub item", by the names in the menu bar ("表示>構造化表示>CSV"). Optional fourth: a
# search term, put into the search panel and run (the panel is opened by the menu path "編集>検索…").
# With a search term the picture is the window and the panel stitched together, each captured on
# its own, so nothing else on the desktop gets in.
# Driving the menu needs Accessibility permission as well.
#
# Needs Screen Recording permission for whatever runs it (the Terminal, or MrPosts).
set -eu

FILE=$1
NAME=$2
MENU=${3:-}
SEARCH=${4:-}
APP=${MRPOSTS_APP:-/Applications/MrEditor.app}
BID=com.aaedit.MrEditor
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${MRPOSTS_OUT:-$HERE/../../local/captures}
SETTLE=${MRPOSTS_SETTLE:-5}          # seconds after the window appears, so the status bar has something to say
SIDEBAR_PT=${MRPOSTS_SIDEBAR_PT:-200}  # the sidebar's width, in points
TITLEBAR_PT=${MRPOSTS_TITLEBAR_PT:-50}

[ -d "$APP" ] || { echo "MrEditor.app が見つかりません: $APP" >&2; exit 1; }
[ -f "$FILE" ] || { echo "ファイルがありません: $FILE" >&2; exit 1; }
if pgrep -x MrEditor >/dev/null; then
  echo "MrEditor が起動中です。作業中のウィンドウに触れないよう、終了してから実行してください。" >&2
  exit 1
fi

mkdir -p "$OUT"
WORK=$(mktemp -d /tmp/mrposts-mredit-XXXXXX)
BACKUP="$WORK/defaults.plist"
HAD_DEFAULTS=0
if defaults export "$BID" "$BACKUP" 2>/dev/null; then HAD_DEFAULTS=1; fi

restore() {
  # Quit politely and wait: the app writes its preferences on the way out, and importing
  # before it is gone would be overwritten.
  osascript -e 'tell application "MrEditor" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -x MrEditor >/dev/null && [ $i -lt 40 ]; do sleep 0.5; i=$((i+1)); done
  if [ $HAD_DEFAULTS = 1 ]; then
    defaults import "$BID" "$BACKUP" 2>/dev/null || echo "警告: 環境設定を戻せませんでした（退避: $BACKUP）" >&2
  fi
  rm -rf "$WORK"
}
trap restore EXIT INT TERM

defaults write "$BID" MrEditor.lineWrap -bool false

echo "開きます: $FILE"
open -a "$APP" "$FILE"

windows() { osascript -l JavaScript "$HERE/window_id.js" MrEditor 2>/dev/null || true; }
INFO=""
i=0
while [ -z "$INFO" ] && [ $i -lt 60 ]; do
  INFO=$(windows)
  [ -n "$INFO" ] || sleep 0.5
  i=$((i+1))
done
[ -n "$INFO" ] || { echo "MrEditor のウィンドウが出ませんでした" >&2; exit 1; }

sleep "$SETTLE"

if [ -n "$MENU" ]; then
  MENU_BAR=${MENU%%>*}
  REST=${MENU#*>}
  MENU_ITEM=${REST%%>*}
  MENU_SUB=""
  case "$REST" in *">"*) MENU_SUB=${REST#*>} ;; esac
  osascript -e 'tell application "MrEditor" to activate' >/dev/null 2>&1 || true
  sleep 0.5
  osascript <<APPLESCRIPT 2>"$WORK/menu.err" || { echo "メニューを操作できません（アクセシビリティの許可が要ります）: $(cat "$WORK/menu.err")" >&2; exit 1; }
tell application "System Events"
  tell process "MrEditor"
    set parentItem to menu item "$MENU_ITEM" of menu 1 of menu bar item "$MENU_BAR" of menu bar 1
    if "$MENU_SUB" is "" then
      click parentItem
    else
      click menu item "$MENU_SUB" of menu 1 of parentItem
    end if
  end tell
end tell
APPLESCRIPT
  sleep "${MRPOSTS_AFTER_MENU:-3}"
fi

if [ -n "$SEARCH" ]; then
  case "$SEARCH" in *'"'*|*'\\'*) echo "検索語に \" と \\ は使えません" >&2; exit 1 ;; esac
  # Typing would go through the Japanese input method ("status=500" came out as "st圧s＝500"), so
  # the term is put straight into the search field, then Return runs it.
  RES=$(osascript <<APPLESCRIPT 2>"$WORK/search.err" || true
tell application "System Events"
  tell process "MrEditor"
    repeat with w in windows
      try
        set f to (first text field of w whose description is "検索テキストフィールド")
        set value of f to "$SEARCH"
        set focused of f to true
        delay 0.4
        key code 36
        return "ok"
      end try
    end repeat
    return "nofield"
  end tell
end tell
APPLESCRIPT
)
  [ "$RES" = "ok" ] || { echo "検索パネルに入力できません（パネルが開かない、またはアクセシビリティの許可が要ります）: $RES $(cat "$WORK/search.err")" >&2; exit 1; }
  # Wait until the panel stops showing a progress percentage ("検索中… 14%", then "100,282 件 · 8%").
  i=0
  while [ $i -lt "${MRPOSTS_SEARCH_WAIT:-120}" ]; do
    BUSY=$(osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "MrEditor"
    repeat with w in windows
      try
        set f to (first text field of w whose description is "検索テキストフィールド")
        repeat with t in (static texts of w)
          if ((value of t) as text) contains "%" then return "busy"
        end repeat
        return "done"
      end try
    end repeat
    return "done"
  end tell
end tell
APPLESCRIPT
)
    [ "$BUSY" = "busy" ] || break
    sleep 2; i=$((i+2))
  done
  sleep 1.5
fi

RAW="$WORK/window.png"
INFO=$(windows)
MAIN=$(echo "$INFO" | head -1)
set -- $MAIN
WID=$1; WPT=$2; HPT=$3; WX=$4; WY=$5

if [ -n "$SEARCH" ] && [ "$(echo "$INFO" | wc -l)" -gt 1 ]; then
  command -v magick >/dev/null || { echo "ImageMagick（magick）が要ります: brew install imagemagick" >&2; exit 1; }
  # Each window on its own, then put back where it stood relative to the others.
  UX=$WX; UY=$WY; UR=$((WX + WPT)); UB=$((WY + HPT))
  for line in $(echo "$INFO" | tr ' ' ',' ); do
    IFS=, read -r id w h x y <<EOT
$line
EOT
    [ "$x" -lt "$UX" ] && UX=$x
    [ "$y" -lt "$UY" ] && UY=$y
    [ $((x + w)) -gt "$UR" ] && UR=$((x + w))
    [ $((y + h)) -gt "$UB" ] && UB=$((y + h))
  done
  n=0
  for line in $(echo "$INFO" | tr ' ' ','); do
    IFS=, read -r id w h x y <<EOT
$line
EOT
    screencapture -l"$id" -o -x "$WORK/w$n.png"
    n=$((n+1))
  done
  W0=$(sips -g pixelWidth "$WORK/w0.png" | awk '/pixelWidth/ {print $2}')
  SC=$((W0 / WPT))
  CW=$(( (UR - UX) * SC )); CH=$(( (UB - UY) * SC ))
  CMD="magick -size ${CW}x${CH} xc:#eef1f4"
  n=0
  for line in $(echo "$INFO" | tr ' ' ','); do
    IFS=, read -r id w h x y <<EOT
$line
EOT
    CMD="$CMD $WORK/w$n.png -geometry +$(( (x - UX) * SC ))+$(( (y - UY) * SC )) -composite"
    n=$((n+1))
  done
  # Drop the sidebar (your own unsaved tabs live there); keep the title bar and the panel.
  CUT=$(( (WX - UX + SIDEBAR_PT) * SC ))
  $CMD -crop $((CW - CUT))x${CH}+${CUT}+0 +repage "$OUT/$NAME"
  echo "保存: $OUT/$NAME"
  exit 0
fi

screencapture -l"$WID" -o -x "$RAW"
[ -s "$RAW" ] || { echo "撮影できませんでした。システム設定の「画面収録」を許可してください" >&2; exit 1; }

W=$(sips -g pixelWidth "$RAW" | awk '/pixelWidth/ {print $2}')
H=$(sips -g pixelHeight "$RAW" | awk '/pixelHeight/ {print $2}')
X=$((SIDEBAR_PT * W / WPT))
Y=$((TITLEBAR_PT * W / WPT))
sips -c $((H - Y)) $((W - X)) --cropOffset "$Y" "$X" "$RAW" --out "$OUT/$NAME" >/dev/null
echo "保存: $OUT/$NAME"
