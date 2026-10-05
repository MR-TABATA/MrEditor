#!/bin/sh
# MrPosts capture recipe: a full-file search across a 10 GB log in MrEditor.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
exec sh "$HERE/_open_capture.sh" "$ROOT/testdata/test_10gb_time.log" mreditor-search-10gb.png "編集>検索…" "status=500"
