#!/bin/bash
# Compiles Sources/ (everything except main.swift) with Tests/SecuritySmoke.swift as the entry point
# in a throwaway directory, then runs it. Exits non-zero when a check fails.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FLAGS=()
# Same stale SwiftBridging module map workaround as build.sh.
SWIFT_INC="$(dirname "$(xcrun -f swiftc)")/../include/swift"
if [ -f "$SWIFT_INC/module.modulemap" ] && [ -f "$SWIFT_INC/bridging.modulemap" ]; then
  INC="$(cd "$SWIFT_INC" && pwd)"
  echo "// hides a stale duplicate SwiftBridging module map" > "$WORK/empty.modulemap"
  cat > "$WORK/overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$INC",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$WORK/empty.modulemap" } ] } ] }
EOF
  FLAGS+=(-vfsoverlay "$WORK/overlay.yaml")
fi

SOURCES=()
for f in Sources/*.swift; do
  [ "$(basename "$f")" = "main.swift" ] || SOURCES+=("$f")
done
cp Tests/SecuritySmoke.swift "$WORK/main.swift"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" ${FLAGS[@]+"${FLAGS[@]}"} \
  -o "$WORK/smoke" "${SOURCES[@]}" "$WORK/main.swift"
"$WORK/smoke"
