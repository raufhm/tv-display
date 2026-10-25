#!/usr/bin/env bash
# Build "TV Display.app" (menu-bar sender) with swiftc — no Xcode project.
#   ./build.sh            build the app
#   ./build.sh run        build and open it
#   ./build.sh install    build and copy it to /Applications
#   ./build.sh dmg        build TV-Display.dmg for sharing
set -euo pipefail
cd "$(dirname "$0")"
APP="TV Display.app"
ART=../art/out

[ -f "$ART/AppIcon.icns" ] || { swift ../art/make-icons.swift "$ART" && iconutil -c icns "$ART/AppIcon.iconset" -o "$ART/AppIcon.icns"; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$ART/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Universal binary: Apple silicon and Intel.
mkdir -p build
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14 -import-objc-header CGVirtualDisplay.h \
    main.swift Stream.swift AudioTap.swift Discovery.swift \
    -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit -framework VideoToolbox \
    -framework CoreMedia -framework CoreVideo -framework ServiceManagement -framework CoreAudio -framework AudioToolbox -framework Network \
    -o build/TVDisplay-$arch
done
lipo -create build/TVDisplay-arm64 build/TVDisplay-x86_64 -output "$APP/Contents/MacOS/TVDisplay"
# Identifier-only requirement keeps the Screen Recording grant valid across rebuilds.
codesign -s - -f --identifier app.tvdisplay -r='designated => identifier "app.tvdisplay"' "$APP" 2>/dev/null
echo "Built $(pwd)/$APP"

case "${1:-}" in
  run) pkill -x TVDisplay && sleep 1 || true; open "$APP" ;;
  install)
    pkill -x TVDisplay || true
    rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/
    echo "Installed /Applications/$APP" ;;
  dmg)
    rm -rf build/dmg TV-Display.dmg && mkdir -p build/dmg
    cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
    hdiutil create -volname "TV Display" -srcfolder build/dmg -ov -format UDZO TV-Display.dmg >/dev/null
    echo "Built $(pwd)/TV-Display.dmg" ;;
esac
