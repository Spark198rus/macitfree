#!/usr/bin/env bash
# Builds build/MacItFree.app (universal arm64 + x86_64) with the `mif` CLI inside,
# and optionally a distributable DMG (pass --dmg).
#
#   scripts/build-app.sh            # app only
#   scripts/build-app.sh --dmg      # app + build/MacItFree.dmg
#
# Environment:
#   VERSION            marketing version (default: latest git tag or 1.0.0)
#   ARCHS              architectures (default: "arm64 x86_64"; use "$(uname -m)" for a faster local build)
#   CODESIGN_IDENTITY  signing identity (default: ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCHS="${ARCHS:-arm64 x86_64}"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

echo "==> Building MacItFree $VERSION ($BUILD) for: $ARCHS"
swift build -c release "${arch_flags[@]}" --product MacItFree
swift build -c release "${arch_flags[@]}" --product mif
BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

APP="build/MacItFree.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/MacItFree" "$APP/Contents/MacOS/MacItFree"
cp "$BIN_DIR/mif" "$APP/Contents/Resources/bin/mif"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

echo "==> Rendering icon"
rm -rf build/AppIcon.iconset
if swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"; then
    echo "    icon ok"
else
    echo "warning: icon generation failed; the app will use the generic icon" >&2
fi

echo "==> Signing (${CODESIGN_IDENTITY:--})"
codesign --force --options runtime --timestamp=none --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/Resources/bin/mif"
codesign --force --options runtime --timestamp=none --sign "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--dmg" ]]; then
    echo "==> Creating DMG"
    STAGE="build/dmg"
    rm -rf "$STAGE" build/MacItFree.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname "MacItFree $VERSION" -srcfolder "$STAGE" -format UDZO -ov build/MacItFree.dmg
    rm -rf "$STAGE"
    echo "    build/MacItFree.dmg"
fi

echo "==> Done: $APP"
