#!/bin/sh
# MrPosts capture recipe: the same, with MrEditor in English for this run only.
HERE=$(cd "$(dirname "$0")" && pwd)
MRPOSTS_LOCALE=en exec sh "$HERE/request-menu.sh"
