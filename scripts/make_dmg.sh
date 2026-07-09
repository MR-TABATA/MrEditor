#!/bin/sh
# release ビルド → .app → 配布用 .dmg を作る。
#
# 注意: コード署名・公証はしていない。ダウンロードした他環境では Gatekeeper に
# 弾かれる（右クリック→「開く」、または `xattr -dr com.apple.quarantine MrEditor.app`
# で回避可能）。正式配布には Apple Developer ID 証明書＋公証が必要。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-MrEditor}"
VERSION="${VERSION:-0.7}"
APP="$ROOT/.build/$APP_NAME.app"
DMG="$ROOT/.build/$APP_NAME-$VERSION.dmg"

echo ">> release ビルド"
swift build -c release

echo ">> .app バンドル作成"
APP_NAME="$APP_NAME" sh "$ROOT/scripts/make_app.sh" release >/dev/null

rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
    echo ">> create-dmg で .dmg 作成"
    create-dmg \
        --volname "$APP_NAME $VERSION" \
        --window-size 540 380 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 140 190 \
        --app-drop-link 400 190 \
        --no-internet-enable \
        "$DMG" \
        "$APP" >/dev/null
else
    echo ">> hdiutil で .dmg 作成（create-dmg 未導入のフォールバック）"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
        -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
fi

echo "$DMG"
