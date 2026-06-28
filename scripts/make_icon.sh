#!/bin/sh
# art/icon.svg（密・大サイズ用）と art/icon-small.svg（簡略・小サイズ用）から
# art/AppIcon.icns を生成する。要 rsvg-convert（librsvg）と iconutil（macOS 標準）。
#
# 2 本立ての理由: 密なデザインは 128px 以上では「巨大ファイル感」が出るが、
# 16/32px では潰れる。小サイズだけ太い数本線の簡略版に差し替える。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/art"
ISET="$ART/AppIcon.iconset"
S="$ART/icon-small.svg"   # 16 / 32px（簡略）
B="$ART/icon.svg"         # 64px 以上（密）

rm -rf "$ISET"; mkdir -p "$ISET"
rsvg-convert -w 16   -h 16   "$S" -o "$ISET/icon_16x16.png"
rsvg-convert -w 32   -h 32   "$S" -o "$ISET/icon_16x16@2x.png"
rsvg-convert -w 32   -h 32   "$S" -o "$ISET/icon_32x32.png"
rsvg-convert -w 64   -h 64   "$B" -o "$ISET/icon_32x32@2x.png"
rsvg-convert -w 128  -h 128  "$B" -o "$ISET/icon_128x128.png"
rsvg-convert -w 256  -h 256  "$B" -o "$ISET/icon_128x128@2x.png"
rsvg-convert -w 256  -h 256  "$B" -o "$ISET/icon_256x256.png"
rsvg-convert -w 512  -h 512  "$B" -o "$ISET/icon_256x256@2x.png"
rsvg-convert -w 512  -h 512  "$B" -o "$ISET/icon_512x512.png"
rsvg-convert -w 1024 -h 1024 "$B" -o "$ISET/icon_512x512@2x.png"

iconutil -c icns "$ISET" -o "$ART/AppIcon.icns"
rm -rf "$ISET"
echo "$ART/AppIcon.icns"
