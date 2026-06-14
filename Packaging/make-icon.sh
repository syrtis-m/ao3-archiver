#!/bin/bash
# Render the app icon (Packaging/IconGen.swift) and build Packaging/AppIcon.icns from it.
# Run this once (or when the design changes); make-app.sh then bundles the .icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Packaging"

echo "rendering icon_1024.png..."
swift IconGen.swift icon_1024.png

echo "building iconset..."
SET="AppIcon.iconset"
rm -rf "$SET"; mkdir "$SET"
sips -z 16 16     icon_1024.png --out "$SET/icon_16x16.png"      >/dev/null
sips -z 32 32     icon_1024.png --out "$SET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     icon_1024.png --out "$SET/icon_32x32.png"      >/dev/null
sips -z 64 64     icon_1024.png --out "$SET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   icon_1024.png --out "$SET/icon_128x128.png"    >/dev/null
sips -z 256 256   icon_1024.png --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   icon_1024.png --out "$SET/icon_256x256.png"    >/dev/null
sips -z 512 512   icon_1024.png --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   icon_1024.png --out "$SET/icon_512x512.png"    >/dev/null
cp icon_1024.png "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "built Packaging/AppIcon.icns"
