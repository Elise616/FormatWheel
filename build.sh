#!/bin/bash
# Builds build/FormatWheel.app with the Xcode Command Line Tools (Xcode itself is not needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FormatWheel.app"
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

FLAGS=()
# Some Command Line Tools installs keep a stale duplicate of the SwiftBridging module map, which
# makes every swiftc run fail with "redefinition of module 'SwiftBridging'". Hide it with a VFS overlay
# instead of touching the system files.
SWIFT_INC="$(dirname "$(xcrun -f swiftc)")/../include/swift"
if [ -f "$SWIFT_INC/module.modulemap" ] && [ -f "$SWIFT_INC/bridging.modulemap" ]; then
  INC="$(cd "$SWIFT_INC" && pwd)"
  echo "// hides a stale duplicate SwiftBridging module map" > build/empty.modulemap
  cat > build/overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$INC",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
EOF
  FLAGS+=(-vfsoverlay build/overlay.yaml)
fi

# UNIVERSAL=1 builds for both Apple silicon and Intel (what package.sh ships).
ARCHS="$(uname -m)"
[ "${UNIVERSAL:-0}" = "1" ] && ARCHS="arm64 x86_64"
SLICES=()
for ARCH in $ARCHS; do
  echo "Compiling ($ARCH)…"
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" ${FLAGS[@]+"${FLAGS[@]}"} \
    -o "build/FormatWheel-$ARCH" Sources/*.swift
  SLICES+=("build/FormatWheel-$ARCH")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/FormatWheel"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "Drawing the icon…"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  "$APP/Contents/MacOS/FormatWheel" --icon "$ICONSET/icon_${s}x${s}.png" --px "$s"
  "$APP/Contents/MacOS/FormatWheel" --icon "$ICONSET/icon_${s}x${s}@2x.png" --px "$((s * 2))"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
