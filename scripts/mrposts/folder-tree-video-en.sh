#!/bin/sh
# MrPosts capture recipe: the folder tree video with MrEditor in English (the Japanese one is folder-tree-video.sh).
HERE=$(cd "$(dirname "$0")" && pwd)
MRPOSTS_MODE=video MRPOSTS_LOCALE=en exec sh "$HERE/folder-tree.sh"
