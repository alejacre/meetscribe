#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MINIMUM="${MINIMUM_COVERAGE:-75}"
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

# Aggregate coverage can hide regressions in the recovery and background-work
# paths. Keep explicit floors for core logic and modest floors for macOS adapters
# whose remaining behavior requires permissioned manual checks.
CRITICAL_COVERAGE=(
    "AudioRecorder.swift:25"
    "Notifier.swift:20"
    "Permissions.swift:15"
    "PublicationService.swift:90"
    "RecordingBackgroundWorkController.swift:90"
    "RecordingCoordinator.swift:45"
    "RecordingDestination.swift:95"
    "RecordingLibrary.swift:85"
    "RecordingManifest.swift:85"
    "RecordingTranscriptionService.swift:70"
    "TranscriptSearch.swift:95"
)

for requirement in "${CRITICAL_COVERAGE[@]}"; do
    file="${requirement%%:*}"
    minimum="${requirement##*:}"
    actual="$(printf '%s\n' "$REPORT" | awk -v file="$file" '
        $1 == file {
            gsub("%", "", $10)
            print $10
        }')"
    if [ -z "$actual" ]; then
        echo "Could not locate coverage for $file" >&2
        exit 1
    fi
    awk -v file="$file" -v actual="$actual" -v minimum="$minimum" \
        'BEGIN {
            printf "%s line coverage: %.2f%% (minimum %.2f%%)\n",
                file, actual, minimum
            exit(actual + 0 < minimum + 0)
        }'
done
