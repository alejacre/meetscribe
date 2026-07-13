#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/MeetScribe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetScribe "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"
# Stable self-signed identity: keeps the same signature across rebuilds so
# TCC permissions (Screen Recording, Microphone) survive. Falls back to ad-hoc.
IDENTITY="MeetScribe Dev Signing"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "WARNING: '$IDENTITY' cert not found; ad-hoc signing (TCC grants will reset on rebuild)"
    codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
