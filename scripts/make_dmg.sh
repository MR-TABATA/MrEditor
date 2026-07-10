#!/bin/sh
# release ビルド（universal: arm64 + x86_64） → .app → 配布用 .dmg を作る。
#
# 署名: 既定は ad-hoc。バンドルは必ず署名される（make_app.sh 側）。
#   ad-hoc でもクラッシュはしないが、Gatekeeper には「開発元を検証できない」と
#   言われるため、利用者は初回だけ右クリック →「開く」が必要。
#   正式配布には Developer ID 証明書＋公証が要る:
#     SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" sh scripts/make_dmg.sh
#     xcrun notarytool submit .build/MrEditor-<ver>.dmg --keychain-profile <prof> --wait
#     xcrun stapler staple .build/MrEditor-<ver>.dmg
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-MrEditor}"
VERSION="${VERSION:-0.7}"
APP="$ROOT/.build/$APP_NAME.app"
DMG="$ROOT/.build/$APP_NAME-$VERSION.dmg"

# Apple Silicon / Intel の両方で動くようにする。
# `swift build -c release` だけだとビルド機のアーキテクチャ専用バイナリになり、
# Intel Mac では起動できない。
echo ">> release ビルド（universal: arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64

echo ">> .app バンドル作成（署名込み）"
BINDIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP_NAME="$APP_NAME" BINDIR="$BINDIR" sh "$ROOT/scripts/make_app.sh" release >/dev/null

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
