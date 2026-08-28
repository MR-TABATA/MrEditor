#!/bin/sh
# `mreditor` コマンドを入れる（パイプで渡すための入口）。
#
#   sh scripts/install-cli.sh              # /usr/local/bin/mreditor へ
#   PREFIX=~/bin sh scripts/install-cli.sh # 置き場所を変える
#
# アプリ本体への symlink を張るだけ。アプリを更新しても張り直しは要らない。
#
#   kubectl logs -f pod/api | mreditor     # パイプで渡す
#   mreditor app.log.gz                    # gzip はそのまま開く
#   mreditor < app.log                     # リダイレクトも同じ
#
# 外すとき: rm <PREFIX>/mreditor
set -eu

APP="${APP:-/Applications/MrEditor.app}"
PREFIX="${PREFIX:-/usr/local/bin}"
BIN="$APP/Contents/MacOS/MrEditor"

[ -x "$BIN" ] || { echo "MrEditor.app が $APP に見つからない。APP=... で場所を渡す。" >&2; exit 1; }
mkdir -p "$PREFIX"
ln -sf "$BIN" "$PREFIX/mreditor"

echo "ok    $PREFIX/mreditor → $BIN"
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "警告  $PREFIX が PATH に無い。シェルの設定に足すこと。" ;;
esac
