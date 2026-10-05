#!/bin/sh
# MrPosts capture recipe: a 10 GB log opened in MrEditor.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
exec sh "$HERE/_open_capture.sh" "$ROOT/testdata/test_10gb_time.log" mreditor-open-10gb.png
