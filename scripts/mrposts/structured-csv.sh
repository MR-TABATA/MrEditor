#!/bin/sh
# MrPosts capture recipe: a 1.2 GB CSV in MrEditor's structured view (columns lined up).
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
exec sh "$HERE/_open_capture.sh" "$ROOT/testdata/houjin_zenken_utf8.csv" mreditor-structured-csv.png "表示>構造化表示>CSV"
