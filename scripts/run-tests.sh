#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-900}"
ARGS=(swift test)
if [ "${1:-}" = "--coverage" ]; then
    ARGS+=(--enable-code-coverage)
elif [ -n "${1:-}" ]; then
    echo "Usage: scripts/run-tests.sh [--coverage]" >&2
    exit 2
fi

"${ARGS[@]}" &
TEST_PID=$!

descendants() {
    local parent="$1"
    local child
    for child in $(pgrep -P "$parent" 2>/dev/null || true); do
        descendants "$child"
        printf '%s\n' "$child"
    done
}

terminate_tree() {
    local root="$1"
    local signal="$2"
    local child
    for child in $(descendants "$root"); do
        kill "-$signal" "$child" 2>/dev/null || true
    done
    kill "-$signal" "$root" 2>/dev/null || true
}

(
    sleep "$TIMEOUT_SECONDS"
    if kill -0 "$TEST_PID" 2>/dev/null; then
        echo "Tests exceeded ${TIMEOUT_SECONDS}s; terminating the test process tree." >&2
        terminate_tree "$TEST_PID" TERM
        sleep 5
        terminate_tree "$TEST_PID" KILL
    fi
) &
WATCHDOG_PID=$!

set +e
wait "$TEST_PID"
STATUS=$?
set -e

terminate_tree "$WATCHDOG_PID" TERM
wait "$WATCHDOG_PID" 2>/dev/null || true
exit "$STATUS"
