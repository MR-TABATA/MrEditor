#!/bin/sh
# SPM でビルドしたバイナリを .app バンドルに包む。
# unbundled な実行ファイルはウィンドウ合成が正しく行われないため、
# GUI として動かすにはバンドルが必要。
set -e

CONFIG="${1:-debug}"

# 製品名（表示名）。Swift 側の Sources/MrEditor/AppInfo.swift の AppInfo.name と揃える。
# 環境変数 APP_NAME で上書き可能（例: APP_NAME=FooView sh scripts/make_app.sh）。
APP_NAME="${APP_NAME:-MrEditor}"
BUNDLE_ID="${BUNDLE_ID:-com.aaedit.MrEditor}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/MrEditor"
RESBUNDLE="$ROOT/.build/$CONFIG/MrEditor_MrEditor.bundle"
APP="$ROOT/.build/$APP_NAME.app"

if [ ! -f "$BIN" ]; then
    echo "バイナリが見つかりません: $BIN (先に swift build を実行)" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MrEditor"

# ローカライズ等のリソースバンドル（SPM 生成）を同梱する。
# これがないと Bundle.module が解決できず、文字列が key のまま表示される。
if [ -d "$RESBUNDLE" ]; then
    cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
fi

# アプリアイコン（art/AppIcon.icns）を同梱する。
if [ -f "$ROOT/art/AppIcon.icns" ]; then
    cp "$ROOT/art/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>MrEditor</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.2</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ja</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "$APP"
