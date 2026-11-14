#!/bin/sh
# dmg の自動更新用の署名（Sparkle の EdDSA）を、標準出力に 1 行で出す。
#
#   sh scripts/sparkle_sign.sh .build/MrEditor-1.29.0.dmg
#
# 秘密鍵は、キーチェーン（generate_keys が作ったもの）。署名を取り出せなければ、非 0 で終わる。
# 試験では、SIGN_UPDATE に偽のコマンドを渡す。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:?usage: sparkle_sign.sh <dmg>}"
SIGN_UPDATE="${SIGN_UPDATE:-$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update}"

[ -x "$SIGN_UPDATE" ] || { echo "sign_update が無い: ${SIGN_UPDATE}（先に swift build）" >&2; exit 1; }
[ -f "$DMG" ] || { echo "dmg が無い: $DMG" >&2; exit 1; }
LINE="$("$SIGN_UPDATE" "$DMG")" || { echo "sign_update が失敗した" >&2; exit 1; }
SIG="$(printf '%s' "$LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$SIG" ] || { echo "署名を取り出せなかった（sign_update の出力が想定と違う）: $LINE" >&2; exit 1; }
printf '%s\n' "$SIG"
