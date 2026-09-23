#!/bin/bash
# Assemble a real macOS .app bundle around the SwiftPM executable, so the gallery is a
# proper double-clickable foreground app -- native keyboard focus, window resize, Dock icon,
# and app menu -- without the bare-`swift run` runtime nudges.
#
# Non-sandboxed by design (no entitlements/signing): a personal backup tool reads a
# user-chosen folder directly. Code signing / notarization / sandboxing are distribution
# concerns for later.
#
# Usage:  ./Packaging/make-app.sh [debug|release]   (default: release)
#         open "build/AO3 Archiver.app"
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "building AO3ArchiverApp ($CONFIG)..."
swift build -c "$CONFIG" --product AO3ArchiverApp

BIN="${ROOT}/.build/${CONFIG}/AO3ArchiverApp"
APP="${ROOT}/build/AO3 Archiver.app"
CONTENTS="${APP}/Contents"

echo "assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BIN}" "${CONTENTS}/MacOS/AO3ArchiverApp"
cp "${ROOT}/Packaging/Info.plist" "${CONTENTS}/Info.plist"
# Version comes from AO3Config.toolVersion (the single source — the User-Agent uses it too).
VERSION="$(sed -n 's/.*static let toolVersion = "\([^"]*\)".*/\1/p' "${ROOT}/Sources/AO3Kit/AO3Client.swift")"
if [ -n "${VERSION}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
                            -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS}/Info.plist"
    echo "  version ${VERSION}"
else
    echo "  (couldn't read AO3Config.toolVersion — keeping Info.plist's version)"
fi

# App icon (Info.plist already references AppIcon via CFBundleIconFile). Regenerate it with
# ./Packaging/make-icon.sh; bundled here if present.
if [ -f "${ROOT}/Packaging/AppIcon.icns" ]; then
    cp "${ROOT}/Packaging/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"
else
    echo "  (no AppIcon.icns — run ./Packaging/make-icon.sh to generate it)"
fi

# Ad-hoc sign so Gatekeeper/TCC treat it as a stable identity (no Developer ID needed).
codesign --force --deep --sign - "${APP}" 2>/dev/null || echo "  (codesign skipped)"

echo "built ${APP}"
echo "run with:  open \"${APP}\""
