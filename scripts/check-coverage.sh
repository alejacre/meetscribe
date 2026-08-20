#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MINIMUM="${MINIMUM_COVERAGE:-29}"
scripts/run-tests.sh --coverage

TEST_BINARY="$(find .build -path '*debug/MeetScribePackageTests.xctest/Contents/MacOS/MeetScribePackageTests' -type f | head -1)"
PROFILE="$(find .build -name default.profdata -type f | head -1)"
if [ -z "$TEST_BINARY" ] || [ -z "$PROFILE" ]; then
    echo "Could not locate Swift coverage artifacts" >&2
    exit 1
fi

REPORT="$(xcrun llvm-cov report "$TEST_BINARY" -instr-profile="$PROFILE" \
    -ignore-filename-regex='Tests/|\.build/' Sources/MeetScribe/*.swift)"
COVERAGE="$(printf '%s\n' "$REPORT" | awk '/^TOTAL/ {gsub("%", "", $10); print $10}')"
printf '%s\n' "$REPORT"

awk -v actual="$COVERAGE" -v minimum="$MINIMUM" \
    'BEGIN {
        printf "Production line coverage: %.2f%% (minimum %.2f%%)\n", actual, minimum
        exit(actual + 0 < minimum + 0)
    }'
