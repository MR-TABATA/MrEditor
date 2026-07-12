#!/bin/sh
# release ビルド（universal: arm64 + x86_64） → .app → 配布用 .dmg を作る。
#
# ■ 既定（環境変数なし）: ad-hoc 署名
#   クラッシュはしないが、Gatekeeper に「開発元を検証できない」と言われる。
#   利用者は初回だけ右クリック →「開く」が必要。
#
# ■ 正式配布（Developer ID 署名＋公証）
#   一度だけの準備:
#     1. 証明書を作る（Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸
#        Developer ID Application）。`security find-identity -v -p codesigning` で確認。
#     2. 公証の資格情報を Keychain に保存する:
#        xcrun notarytool store-credentials mreditor \
#          --apple-id <AppleID> --team-id <TEAMID> --password <App用パスワード>
#        （App 用パスワードは appleid.apple.com で発行する。Apple ID の本パスワードではない）
#   ビルド:
#     SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#     NOTARY_PROFILE=mreditor \
#     sh scripts/make_dmg.sh
#
#   公証は Apple のサーバへ送って審査を待つ（数分）。成功したら staple で
#   チケットを dmg に焼き付ける。これでオフラインでも Gatekeeper を通る。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-MrEditor}"
VERSION="${VERSION:-1.0.3}"
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

# .app 自体を先に公証して staple しておく。
# dmg だけに staple すると、Applications へドラッグした後の .app にチケットが無く、
# オフラインの Mac では Gatekeeper が Apple に問い合わせられず検証に失敗しうる。
# 公証は zip で提出する（.app はディレクトリなのでそのままでは送れない）。
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
    ZIP="$ROOT/.build/$APP_NAME-notarize.zip"
    rm -f "$ZIP"
    echo ">> .app を公証へ提出"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    echo ">> 公証チケットを .app に焼き付ける"
    xcrun stapler staple "$APP"
fi

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

# ---------------------------------------------------------------------------
# Developer ID 署名がある場合のみ: dmg にも署名し、公証して staple する。
# .app は make_app.sh が既に署名済み。dmg 自体にも署名しないと公証を通らない。
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    echo ">> dmg に署名"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

    if [ -n "$NOTARY_PROFILE" ]; then
        echo ">> 公証へ提出（Apple のサーバで審査。数分かかる）"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

        echo ">> 公証チケットを dmg に焼き付ける（staple）"
        xcrun stapler staple "$DMG"

        echo ">> 検証: Gatekeeper が受け入れるか"
        # 「Notarized Developer ID」と出れば、利用者は右クリックすら不要になる。
        spctl -a -vvv -t install "$DMG"
        xcrun stapler validate "$DMG"
        # .app にもチケットが焼かれていること（オフラインでも通るため）。
        xcrun stapler validate "$APP"
    else
        echo ">> NOTARY_PROFILE が未設定のため公証はスキップ（署名のみ）"
        echo "   公証しないと Gatekeeper は依然として警告する。"
    fi
fi

echo "$DMG"
