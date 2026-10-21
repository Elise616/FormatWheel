#!/bin/bash
# Builds the promo renderer from the app's own drawing code plus Promo/*.swift, then renders the film.
#   ./Promo/render.sh                      → 宣传片/格式轮盘-宣传片.mp4 (sound effects only, no music)
#   ./Promo/render.sh --with-music --out 宣传片/格式轮盘-宣传片.mp4   → also a cut with the synth beat
#   ./Promo/render.sh --frames 5,12 --out dir   → stills for checking
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build 宣传片
FLAGS=()
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

SOURCES=()
for f in Sources/*.swift; do [ "$(basename "$f")" = "main.swift" ] || SOURCES+=("$f"); done
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" ${FLAGS[@]+"${FLAGS[@]}"} \
  -o build/promo "${SOURCES[@]}" Promo/*.swift

if [ $# -eq 0 ]; then
  build/promo --out "宣传片/格式轮盘-宣传片.mp4"
else
  build/promo "$@"
fi
