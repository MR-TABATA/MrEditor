#!/bin/sh
# MrPosts capture recipe: a 1.2 GB / 5.8 million-row CSV opened in MrEditor.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
exec sh "$HERE/_open_capture.sh" "$ROOT/testdata/houjin_zenken_utf8.csv" mreditor-open-big-csv.png
