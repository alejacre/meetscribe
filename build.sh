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

# Keep the installed copy in lockstep with the freshly-signed build. Running one
# copy while rebuilding another (esp. if that other was ad-hoc signed) orphans the
# Screen Recording / Microphone grants and makes macOS re-prompt on every launch.
if [ -d /Applications/MeetScribe.app ]; then
    osascript -e 'quit app "MeetScribe"' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/MeetScribe.app
    cp -R "$APP" /Applications/MeetScribe.app
    echo "Synced /Applications/MeetScribe.app"
fi
