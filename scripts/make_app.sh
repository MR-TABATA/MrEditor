#!/bin/sh
# SPM でビルドしたバイナリを .app バンドルに包む。
# unbundled な実行ファイルはウィンドウ合成が正しく行われないため、
# GUI として動かすにはバンドルが必要。
set -e

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/MrEditor"
APP="$ROOT/.build/MrEditor.app"

if [ ! -f "$BIN" ]; then
    echo "バイナリが見つかりません: $BIN (先に swift build を実行)" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MrEditor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MrEditor</string>
    <key>CFBundleDisplayName</key>
    <string>MrEditor</string>
    <key>CFBundleIdentifier</key>
    <string>com.aaedit.MrEditor</string>
    <key>CFBundleExecutable</key>
    <string>MrEditor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
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
