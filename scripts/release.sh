#!/bin/sh
# GitHub Release を「draft で作る → dmg を付ける → 付いたことを確かめる → 公開」の順で出す。
#
#   SIGN_IDENTITY=<40桁ハッシュ> NOTARY_PROFILE=mreditor \
#   sh scripts/release.sh 1.23.2 notes-1.23.2.md
#
# dmg が付いていない公開済み Release を作らないための手順。MrkTools の Mirror releases は
# 最新リリースに MrEditor-<版>.dmg が無いと失敗する（1.23.1 はこれで落ちた）。
#
# 前提: main の最新・変更なしで、版上げ（AppInfo.swift など）がマージ済みであること。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: release.sh <version> <notes-file>}"
NOTES="${2:?usage: release.sh <version> <notes-file>}"
TAG="v$VERSION"
DMG="$ROOT/.build/MrEditor-$VERSION.dmg"

[ -f "$NOTES" ] || { echo "ノートが無い: $NOTES" >&2; exit 1; }
[ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ] || {
    echo "SIGN_IDENTITY と NOTARY_PROFILE が必要（署名・公証済みの dmg だけを配る）" >&2; exit 1; }

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "main ではない" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "未コミットの変更がある" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "origin/main と一致しない" >&2; exit 1; }

grep -q "\"$VERSION\"" Sources/MrEditorCore/AppInfo.swift || {
    echo "AppInfo.swift に $VERSION が無い（版上げがマージされていない）" >&2; exit 1; }

if gh release view "$TAG" >/dev/null 2>&1; then
    [ "$(gh release view "$TAG" --json isDraft -q .isDraft)" = "true" ] || {
        echo "$TAG はすでに公開済み。dmg が無いなら gh release upload で付ける" >&2; exit 1; }
    echo ">> 既存の draft $TAG を使う"
else
    echo ">> draft を作る"
    gh release create "$TAG" --draft --target "$(git rev-parse HEAD)" \
        --title "MrEditor $VERSION" --notes-file "$NOTES"
fi

echo ">> dmg を作る（署名・公証）"
VERSION="$VERSION" sh scripts/make_dmg.sh

echo ">> dmg を添付"
gh release upload "$TAG" "$DMG" --clobber

LOCAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
REMOTE="$(gh release view "$TAG" --json assets -q ".assets[]|select(.name==\"MrEditor-$VERSION.dmg\")|.digest")"
[ "$REMOTE" = "sha256:$LOCAL" ] || { echo "添付した dmg の SHA-256 が一致しない: $REMOTE != $LOCAL" >&2; exit 1; }

echo ">> 公開"
gh release edit "$TAG" --draft=false --latest
echo "$TAG を公開した（dmg sha256:$LOCAL）"
