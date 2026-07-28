#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DESTINATION="/Applications/MeetScribe.app"
STAGED="/Applications/.MeetScribe.app.staged"
BACKUP="/Applications/.MeetScribe.app.backup"

rm -rf "$STAGED" "$BACKUP"
ditto build/MeetScribe.app "$STAGED"
osascript -e 'quit app "MeetScribe"' 2>/dev/null || true

if [ -d "$DESTINATION" ]; then
    mv "$DESTINATION" "$BACKUP"
fi
if ! mv "$STAGED" "$DESTINATION"; then
    if [ -d "$BACKUP" ]; then mv "$BACKUP" "$DESTINATION"; fi
    exit 1
fi
rm -rf "$BACKUP"
echo "Installed $DESTINATION"
