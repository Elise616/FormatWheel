#!/bin/bash
# Builds a universal FormatWheel.app (Apple silicon + Intel) and packs it for sharing:
#   dist/FormatWheel.dmg  — open, drag into Applications
#   dist/FormatWheel.zip  — the bare app
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

rm -rf dist
mkdir -p dist/stage
cp -R build/FormatWheel.app dist/stage/
ln -s /Applications dist/stage/Applications
cp "Resources/打不开？看这里.txt" dist/stage/

echo "Packing DMG…"
hdiutil create -volname "格式轮盘 $VERSION" -srcfolder dist/stage -ov -format UDZO dist/FormatWheel.dmg >/dev/null
ditto -c -k --sequesterRsrc --keepParent build/FormatWheel.app dist/FormatWheel.zip
rm -rf dist/stage
ls -lh dist
