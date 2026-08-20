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
    local signal="$1"
    local child
    for child in $(descendants "$TEST_PID"); do
        kill "-$signal" "$child" 2>/dev/null || true
    done
    kill "-$signal" "$TEST_PID" 2>/dev/null || true
}

(
    sleep "$TIMEOUT_SECONDS"
    if kill -0 "$TEST_PID" 2>/dev/null; then
        echo "Tests exceeded ${TIMEOUT_SECONDS}s; terminating the test process tree." >&2
        terminate_tree TERM
        sleep 5
        terminate_tree KILL
    fi
) &
WATCHDOG_PID=$!

set +e
wait "$TEST_PID"
STATUS=$?
set -e

kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
exit "$STATUS"
