#!/bin/sh
# SPM でビルドしたバイナリを .app バンドルに包む。
# unbundled な実行ファイルはウィンドウ合成が正しく行われないため、
# GUI として動かすにはバンドルが必要。
set -e

CONFIG="${1:-debug}"

# 製品名（表示名）。実行時の表示名は AppInfo.name が CFBundleName を読むので、ここが唯一の元。
# 環境変数 APP_NAME で上書き可能（例: APP_NAME=FooView sh scripts/make_app.sh）。
#
# Pro 版（MrkEditor）は別リポからこのスクリプトを呼び、次を渡す:
#   APP_NAME=MrkEditor BUNDLE_ID=com.aaedit.MrkEditor EXECUTABLE=MrkEditor \
#   ICON=art/AppIcon-Pro.icns COPYRIGHT="© 2026 TABATA Hitoshi. All rights reserved."
APP_NAME="${APP_NAME:-MrEditor}"
BUNDLE_ID="${BUNDLE_ID:-com.aaedit.MrEditor}"
# 実行ファイル名（SPM の executableTarget 名）。無料版=MrEditor / Pro 版=MrkEditor。
EXECUTABLE="${EXECUTABLE:-MrEditor}"
# バージョン（Info.plist へ埋め込む）。make_dmg.sh と揃えるため VERSION で上書き可能。
VERSION="${VERSION:-1.11.1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON="${ICON:-$ROOT/art/AppIcon.icns}"
COPYRIGHT="${COPYRIGHT:-© 2026 TABATA Hitoshi. MIT License.}"
# 共有リンクのスキーム（mreditor://theme?d=…）。
URL_SCHEME="${URL_SCHEME:-mreditor}"
# 成果物の置き場所。universal ビルド（--arch arm64 --arch x86_64）では
# .build/apple/Products/<Config> になるため、make_dmg.sh から BINDIR で上書きする。
BINDIR="${BINDIR:-$ROOT/.build/$CONFIG}"
BIN="$BINDIR/$EXECUTABLE"
# SPM のリソースバンドルは `<パッケージ名>_<ターゲット名>.bundle`。ターゲットが
# MrEditorCore になっても、パッケージ名は依存元から見ても MrEditor のままなので、
# **この名前は無料版と Pro 版で同じ**（Pro リポからも同じパスで拾える）。
RESBUNDLE="$BINDIR/MrEditor_MrEditorCore.bundle"
# .app の置き場所。既定はこのリポジトリの .build。Pro リポ（MrkEditor）は自分の
# .build へ出したいので OUTDIR で上書きする（成果物が公開リポ側に紛れ込まないように）。
OUTDIR="${OUTDIR:-$ROOT/.build}"
APP="$OUTDIR/$APP_NAME.app"

# コード署名の ID。既定は ad-hoc（"-"）。
# Developer ID を取得したら SIGN_IDENTITY="Developer ID Application: ..." を渡すだけでよい。
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [ ! -f "$BIN" ]; then
    echo "バイナリが見つかりません: $BIN (先に swift build を実行)" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

# ローカライズ等のリソースバンドル（SPM 生成）を同梱する。
# これがないと Bundle.module が解決できず、文字列が key のまま表示される。
if [ -d "$RESBUNDLE" ]; then
    cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
fi

# アプリアイコン（既定 art/AppIcon.icns、Pro は ICON で差し替え）を同梱する。
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
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
    <string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
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
    <key>NSHumanReadableCopyright</key>
    <string>$COPYRIGHT</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>

    <!-- Finder の「このアプリケーションで開く」に出すための宣言。
         これが無いと AppDelegate の application(_:open:) は永遠に呼ばれない。
         LSHandlerRank=Alternate: 既定アプリ（TextEdit 等）は奪わないが候補には出る。
         2 つ目の public.data は「拡張子が何であれログは開ける」ためのもの
         （.log でも .out でも拡張子無しでも Finder から開ける）。
         ここも Alternate。None は「順位が低い」ではなく「この型は開かない」の意味なので使わない。 -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Text Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
                <string>public.utf8-plain-text</string>
                <string>public.log</string>
                <string>public.comma-separated-values-text</string>
                <string>public.tab-separated-values-text</string>
                <string>public.json</string>
                <string>public.source-code</string>
                <string>public.script</string>
                <string>public.xml</string>
                <string>public.yaml</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Any File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
    </array>
    <!-- 外観設定の共有リンク（mreditor://theme?d=…）を受け取るためのスキーム宣言。
         これが無いと macOS がリンクをこのアプリへ渡さない。application(_:open:) が受ける。 -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID.settings</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>$URL_SCHEME</string>
            </array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# コード署名。**これを省くと、ダウンロードした他の Mac でアプリがクラッシュする。**
#
# Swift のリンカは実行バイナリを ad-hoc 署名する（flags: adhoc,linker-signed）。
# その署名は「バンドルにリソース署名がある」前提なのに、バイナリを .app へ
# コピーしただけでは Contents/_CodeSignature/CodeResources が作られない。
# 結果 `codesign --verify` は
#   "code has no resources but signature indicates they must be present"
# となり署名が矛盾する。開発機は quarantine 属性が付かないので検証されず動くが、
# ダウンロードした Mac では quarantine が付き AMFI が検証してプロセスを殺す。
# ユーザーには「アプリケーションが予期しない理由で終了しました」と見える
# （Gatekeeper の「開けません」ではなくクラッシュ）。
#
# 対処: バンドル全体を署名し直して CodeResources を作る。
# ad-hoc のままでも**クラッシュはしなくなる**（初回は右クリック→開くが必要）。
# Developer ID を取得したら SIGN_IDENTITY を渡すだけで正式署名に切り替わる。
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP"
else
    # 正式署名では入れ子から順に署名し、hardened runtime を有効にする（公証の要件）。
    if [ -d "$APP/Contents/Resources/$(basename "$RESBUNDLE")" ]; then
        codesign --force --options runtime --timestamp \
                 --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/$(basename "$RESBUNDLE")"
    fi
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

# 署名が矛盾していないことを必ず確かめる（矛盾したまま配ると他機でクラッシュする）。
codesign --verify --deep --strict "$APP"

echo "$APP"
