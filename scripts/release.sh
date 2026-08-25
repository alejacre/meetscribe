#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
: "${VERSION:?Set VERSION, for example 1.2.0}"

if [[ "$CODESIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "CODESIGN_IDENTITY must be a Developer ID Application identity" >&2
    exit 1
fi

BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
export CODESIGN_IDENTITY VERSION BUILD_NUMBER
./build.sh

ARCHIVE="build/MeetScribe-${VERSION}.zip"
create_archive() {
    rm -f "$ARCHIVE"
    ditto -c -k --keepParent build/MeetScribe.app "$ARCHIVE"
}

create_archive
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/MeetScribe.app
xcrun stapler validate build/MeetScribe.app
spctl --assess --type execute --verbose=2 build/MeetScribe.app
create_archive
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "Release artifact: $ARCHIVE"
