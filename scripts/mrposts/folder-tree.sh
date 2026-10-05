#!/bin/sh
# MrPosts capture recipe: MrEditor's folder tree (v1.20.0).
#
#   (default)            two pictures of the tree window: expanded, and narrowed by the file-name filter.
#   MRPOSTS_LOCALE=en    the app's own language for this run only (ja by default): it is started with
#                        -AppleLanguages "(en)", which is not saved. The menu and dialog are named by
#                        the app's own strings in each language (MrEditor_MrEditorCore.bundle).
#   MRPOSTS_MODE=video   one mp4 of the whole thing, MrEditor's own window included — "Open by path…",
#                        the tree opening, folders expanding, the filter, and a file opening in the
#                        window behind (folder-tree-video.sh sets it). The tree alone says nothing.
#
# What it does to your machine, and puts back:
#   - MrEditor's preferences are exported first and imported again at the end.
#   - It refuses to run while MrEditor is open. Your unsaved drafts are never written.
#   - The demo folder lives in /tmp/mrposts-demo and is removed at the end.
#
# The video is of the main window's own rectangle (so nothing else on the desktop is in it), with the
# window opened on a demo log (so none of your documents is). The sidebar below the first tab lists
# your unsaved tabs; it is painted over in the finished video.
#
# Needs Screen Recording and Accessibility permission for whatever runs it (the Terminal, or MrPosts).
set -eu

APP=${MRPOSTS_APP:-/Applications/MrEditor.app}
BID=com.aaedit.MrEditor
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${MRPOSTS_OUT:-$HERE/../../local/captures}
MODE=${MRPOSTS_MODE:-image}
LOCALE=${MRPOSTS_LOCALE:-ja}
case "$LOCALE" in
  en) MENU_FILE="File";     MENU_OPEN_PATH="Open by Path…";       DIALOG_TITLE="Open by Path";     SUFFIX="-en" ;;
  ja) MENU_FILE="ファイル"; MENU_OPEN_PATH="パスを指定して開く…"; DIALOG_TITLE="パスを指定して開く"; SUFFIX="" ;;
  *)  echo "MRPOSTS_LOCALE は ja か en です: $LOCALE" >&2; exit 1 ;;
esac
DEMO=/tmp/mrposts-demo/myapp
TREE_H_PT=${MRPOSTS_TREE_HEIGHT:-400}
SIDEBAR_PT=${MRPOSTS_SIDEBAR_PT:-200}     # the sidebar's width, in points
FIRST_TAB_END_PT=${MRPOSTS_FIRST_TAB_END_PT:-92}   # below this the sidebar lists other tabs
STATUS_PT=${MRPOSTS_STATUS_PT:-30}        # the status bar's height

[ -d "$APP" ] || { echo "MrEditor.app が見つかりません: $APP" >&2; exit 1; }
if pgrep -x MrEditor >/dev/null; then
  echo "MrEditor が起動中です。作業中のウィンドウに触れないよう、終了してから実行してください。" >&2
  exit 1
fi
if [ "$MODE" = video ]; then
  command -v ffmpeg >/dev/null || { echo "ffmpeg が要ります: brew install ffmpeg" >&2; exit 1; }
  command -v magick >/dev/null || { echo "ImageMagick（magick）が要ります: brew install imagemagick" >&2; exit 1; }
fi

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

# A small project-shaped folder to show.
rm -rf /tmp/mrposts-demo
mkdir -p "$DEMO/logs" "$DEMO/config" "$DEMO/data" "$DEMO/scripts"
for f in logs/app.log logs/error.log logs/access.log config/prod.conf config/staging.conf data/export.csv data/users.json scripts/deploy.sh README.txt; do
  printf 'sample %s\n' "$f" > "$DEMO/$f"
done
if [ "$MODE" = video ]; then
  # What is open in the window behind (a log that looks like one) and what opens at the end (the first
  # match of the filter, access.log).
  awk 'BEGIN { for (i = 1; i <= 80; i++) printf "2026-10-05T09:%02d:%02d+09:00 [%s] request_id=%d status=%d path=/api/v1/%s latency=%dms\n", int(i/60), i%60, (i%9==0?"WARN ":"INFO "), i, (i%9==0?404:200), (i%3==0?"orders":"users"), 12+i%17 }' > "$DEMO/logs/app.log"
  awk 'BEGIN { for (i = 1; i <= 80; i++) printf "2026-10-05T09:%02d:%02d+09:00 [ERROR] request_id=%d status=500 path=/api/v1/orders msg=upstream timeout\n", int(i/60), i%60, i }' > "$DEMO/logs/error.log"
  awk 'BEGIN { for (i = 1; i <= 80; i++) printf "10.0.%d.%d - - [05/Oct/2026:09:%02d:%02d +0900] \"GET /api/v1/%s HTTP/1.1\" %d %d\n", i%4, 10+i%50, int(i/60), i%60, (i%3==0?"orders":"users"), (i%9==0?404:200), 300+i*7 }' > "$DEMO/logs/access.log"
fi

windows() { osascript -l JavaScript "$HERE/window_id.js" MrEditor 2>/dev/null || true; }

echo "MrEditor を起動します"
# -AppleLanguages goes to this run only; it is not written to the preferences.
if [ "$LOCALE" = en ]; then ARGS="--args -AppleLanguages (en)"; else ARGS=""; fi
if [ "$MODE" = video ]; then
  # shellcheck disable=SC2086
  open -a "$APP" "$DEMO/logs/app.log" $ARGS
else
  # shellcheck disable=SC2086
  open -a "$APP" $ARGS
fi
i=0
while [ -z "$(windows)" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
[ -n "$(windows)" ] || { echo "MrEditor のウィンドウが出ませんでした" >&2; exit 1; }
sleep 2.5
osascript -e 'tell application "MrEditor" to activate' >/dev/null 2>&1 || true
sleep 0.5
# The main window's rectangle, before any other window exists.
set -- $(windows | head -1)
MW=$2; MH=$3; MX=$4; MY=$5

# ---- steps -----------------------------------------------------------------------------------

# File > Open by path…
menu_open_path() {
  osascript <<APPLESCRIPT 2>"$WORK/open.err" || { echo "メニューを操作できません（アクセシビリティの許可が要ります）: $(cat "$WORK/open.err")" >&2; exit 1; }
tell application "System Events"
  tell process "MrEditor"
    click menu item "$MENU_OPEN_PATH" of menu 1 of menu bar item "$MENU_FILE" of menu bar 1
  end tell
end tell
APPLESCRIPT
}

# Put the folder in the dialog's field (typing would go through the input method), then Return.
submit_path() {
  RES=$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "MrEditor"
    repeat with w in windows
      try
        if (name of w) is "$DIALOG_TITLE" then
          set f to first text field of w
          set value of f to "$DEMO"
          set focused of f to true
          delay 0.4
          key code 36
          return "ok"
        end if
      end try
    end repeat
    return "nodialog"
  end tell
end tell
APPLESCRIPT
)
  [ "$RES" = "ok" ] || { echo "「$DIALOG_TITLE」の入力欄が見つかりません: $RES" >&2; exit 1; }
}

# The tree window's id (its title is the folder's path).
tree_id() {
  windows | while IFS= read -r line; do
    case "$line" in *"$DEMO"*) echo "${line%% *}"; break ;; esac
  done
}
wait_tree() {
  TID=""
  i=0
  while [ -z "$TID" ] && [ $i -lt 100 ]; do TID=$(tree_id); [ -n "$TID" ] || sleep 0.1; i=$((i+1)); done
  [ -n "$TID" ] || { echo "フォルダのツリーが開きませんでした" >&2; exit 1; }
}

# Size the tree window (and, if x and y are given, put it there).
place_tree() {
  if [ -n "${2:-}" ]; then POS="set position of w to {$1, $2}"; else POS=""; fi
  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  tell process "MrEditor"
    repeat with w in windows
      if (name of w) starts with "$DEMO" then
        set size of w to {360, $3}
        $POS
      end if
    end repeat
  end tell
end tell
APPLESCRIPT
}

# Expand a row of the outline. Bottom first, so the row numbers hold.
expand_row() {
  osascript <<APPLESCRIPT >/dev/null 2>&1 || { echo "フォルダを展開できませんでした" >&2; exit 1; }
tell application "System Events"
  tell process "MrEditor"
    repeat with w in windows
      if (name of w) starts with "$DEMO" then
        set ol to outline 1 of scroll area 1 of w
        set value of attribute "AXDisclosing" of row $1 of ol to true
      end if
    end repeat
  end tell
end tell
APPLESCRIPT
}

# The file-name filter. (The value is set directly, not typed.)
set_filter() {
  osascript <<APPLESCRIPT >/dev/null 2>&1 || { echo "絞り込み欄に入力できませんでした" >&2; exit 1; }
tell application "System Events"
  tell process "MrEditor"
    repeat with w in windows
      if (name of w) starts with "$DEMO" then
        set f to first text field of w
        set value of f to "$1"
        set focused of f to true
      end if
    end repeat
  end tell
end tell
APPLESCRIPT
}

# Open the first row of the list in the main window by double-clicking it, as a person would.
# (Selecting it through the accessibility API, or Down + Return, does not open it.) The row's place on
# the screen comes from the accessibility API; the click is a real mouse event.
open_first_row() {
  GEO=$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "MrEditor"
    repeat with w in windows
      if (name of w) starts with "$DEMO" then
        perform action "AXRaise" of w
        set r to row 1 of (outline 1 of scroll area 1 of w)
        set p to position of r
        set z to size of r
        return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of z) as text) & " " & ((item 2 of z) as text)
      end if
    end repeat
  end tell
end tell
APPLESCRIPT
)
  [ -n "$GEO" ] || { echo "（ファイルを開く操作は省きました）" >&2; return 0; }
  set -- $GEO
  CX=$(( ${1%%.*} + 90 )); CY=$(( ${2%%.*} + ${4%%.*} / 2 ))
  sleep 0.4
  osascript -l JavaScript >/dev/null 2>&1 <<JXA || echo "（ファイルを開く操作は省きました）" >&2
ObjC.import('CoreGraphics');
const pt = $.CGPointMake($CX, $CY);
function post(type, state) {
  const e = $.CGEventCreateMouseEvent(null, type, pt, $.kCGMouseButtonLeft);
  $.CGEventSetIntegerValueField(e, $.kCGMouseEventClickState, state);
  $.CGEventPost($.kCGHIDEventTap, e);
  delay(0.05);
}
post($.kCGEventMouseMoved, 0);
delay(0.3);
for (const n of [1, 2]) { post($.kCGEventLeftMouseDown, n); post($.kCGEventLeftMouseUp, n); }
JXA
}

# ---- video -----------------------------------------------------------------------------------
if [ "$MODE" = video ]; then
  SECS=${MRPOSTS_VIDEO_SECS:-26}
  RAW="$WORK/raw.mov"
  echo "録画します（約20秒・触らないこと）"
  # The main window's own rectangle: nothing else is in it. The tree is put inside it.
  screencapture -v -V "$SECS" -x -R"$MX,$MY,$MW,$MH" "$RAW" &
  REC=$!
  T0=$(date +%s)
  sleep 2.2                                          # the window with the log, as it starts
  menu_open_path; sleep 2.0                          # "Open by path…" and its dialog
  submit_path; wait_tree
  place_tree $((MX + MW - 360 - 60)) $((MY + 80)) "$TREE_H_PT"
  sleep 1.6                                          # the tree, collapsed
  expand_row 3; sleep 1.0
  expand_row 1; sleep 2.0
  set_filter "l";   sleep 0.6
  set_filter "lo";  sleep 0.6
  set_filter "log"; sleep 1.8
  open_first_row;   sleep 3.0                        # the file opens in the window behind
  DUR=$(( $(date +%s) - T0 + 1 ))
  wait $REC 2>/dev/null || true
  [ -s "$RAW" ] || { echo "録画できませんでした。システム設定の「画面収録」を許可してください" >&2; exit 1; }

  # Finish: paint over the sidebar's other tabs, square off the window's rounded corners (they show
  # whatever is behind the window), scale for the web, h264.
  RW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$RAW")
  SC=$((RW / MW))
  ffmpeg -y -loglevel error -ss 0.6 -i "$RAW" -frames:v 1 "$WORK/frame.png"
  px() { magick "$WORK/frame.png" -crop 1x1+"$1"+"$2" -format '%[hex:u]' info: | cut -c1-6; }
  SBC=$(px $((100 * SC)) $(((MH - 70) * SC)))        # an empty stretch of the sidebar
  TOPC=$(px $(((MW * 6 / 10) * SC)) $((6 * SC)))     # the title bar, away from its text
  BOTC=$(px $(((MW * 6 / 10) * SC)) $(((MH - 6) * SC)))  # the status bar, away from its text
  C=$((16 * SC))
  VF="drawbox=x=0:y=$((FIRST_TAB_END_PT * SC)):w=$((SIDEBAR_PT * SC)):h=$(((MH - STATUS_PT - FIRST_TAB_END_PT) * SC)):color=0x$SBC:t=fill"
  VF="$VF,drawbox=x=0:y=0:w=$C:h=$C:color=0x$TOPC:t=fill,drawbox=x=$((RW - C)):y=0:w=$C:h=$C:color=0x$TOPC:t=fill"
  VF="$VF,drawbox=x=0:y=$(((MH * SC) - C)):w=$C:h=$C:color=0x$BOTC:t=fill,drawbox=x=$((RW - C)):y=$(((MH * SC) - C)):w=$C:h=$C:color=0x$BOTC:t=fill"
  VF="$VF,scale=1280:-2"
  ffmpeg -y -loglevel error -ss 0.6 -t "$DUR" -i "$RAW" -vf "$VF" -c:v libx264 -pix_fmt yuv420p -movflags +faststart -an "$OUT/mreditor-folder-tree$SUFFIX.mp4"
  echo "保存: $OUT/mreditor-folder-tree.mp4"
  exit 0
fi

# ---- pictures --------------------------------------------------------------------------------
menu_open_path; sleep 1.5
submit_path; wait_tree; sleep 1.5
place_tree "" "" "$TREE_H_PT"; sleep 1

expand_row 3; sleep 0.6
expand_row 1; sleep 1.6
screencapture -l"$TID" -o -x "$OUT/mreditor-folder-tree$SUFFIX.png"
[ -s "$OUT/mreditor-folder-tree$SUFFIX.png" ] || { echo "撮影できませんでした。システム設定の「画面収録」を許可してください" >&2; exit 1; }
echo "保存: $OUT/mreditor-folder-tree.png"

set_filter "log"; sleep 2.5
screencapture -l"$TID" -o -x "$OUT/mreditor-folder-filter$SUFFIX.png"
echo "保存: $OUT/mreditor-folder-filter.png"
