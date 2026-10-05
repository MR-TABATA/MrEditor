#!/bin/sh
# MrPosts capture recipe: MrEditor's folder tree as a short mp4 (open, expand, filter).
HERE=$(cd "$(dirname "$0")" && pwd)
MRPOSTS_MODE=video exec sh "$HERE/folder-tree.sh"
