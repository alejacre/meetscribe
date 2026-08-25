#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(uname -m)" != "arm64" ]; then
    echo "MeetScribe requires Apple Silicon (arm64)" >&2
    exit 1
fi

CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
APP="build/MeetScribe.app"

swift build -c "$CONFIGURATION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIGURATION/MeetScribe" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"
cp Assets/mlx-whisper-constraints.txt "$APP/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:-MeetScribe Dev Signing}"
if security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
    TIMESTAMP=(--timestamp=none)
    if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
        TIMESTAMP=(--timestamp)
    fi
    codesign --force --options runtime "${TIMESTAMP[@]}" \
        --entitlements MeetScribe.entitlements --sign "$IDENTITY" "$APP"
else
    echo "WARNING: '$IDENTITY' not found; using an ad-hoc development signature"
    codesign --force --options runtime --timestamp=none \
        --entitlements MeetScribe.entitlements --sign - "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP ($VERSION build $BUILD_NUMBER)"
