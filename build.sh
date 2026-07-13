#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/MeetScribe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetScribe "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
