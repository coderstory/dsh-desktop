#!/usr/bin/env bash
# End-to-end spawn test: launches the wrapper on a non-conflicting port
# (13080) and verifies dsh spawn + TCP probe works. Does NOT touch 3080.
#
# Usage: ./scripts/test-spawn.sh

set -euo pipefail

PORT=13080
WRAPPER_BIN=/Applications/DshDesktop.app/Contents/MacOS/DshDesktop
DSH_BIN=/Users/coderstory/.global-npm/bin/dsh

echo "==========================================="
echo "  DshDesktop spawn test (port $PORT)"
echo "==========================================="

# Sanity
test -x "$WRAPPER_BIN" || { echo "FAIL: wrapper binary not found at $WRAPPER_BIN"; exit 1; }
test -x "$DSH_BIN" || { echo "FAIL: dsh binary not found at $DSH_BIN"; exit 1; }
echo "wrapper: $WRAPPER_BIN"
echo "dsh:     $DSH_BIN"
echo "port:    $PORT"
echo

# Cleanup any prior test instance
pkill -f "DshDesktop.*--port $PORT" 2>/dev/null || true
sleep 0.5

# Start log capture in background
LOG_FILE=$(mktemp -t dsh-desktop-spawn-test.XXXXXX.log)
echo "==> streaming log to: $LOG_FILE"
log stream --predicate 'subsystem == "ai.deepseek.dsh.desktop"' --info --debug \
    > "$LOG_FILE" &
LOG_PID=$!
sleep 0.5  # let log stream subscribe

# Launch the wrapper in background
echo "==> launching wrapper: $WRAPPER_BIN --port $PORT --dsh-path $DSH_BIN"
"$WRAPPER_BIN" --port "$PORT" --dsh-path "$DSH_BIN" > /tmp/wrapper-stdout.log 2>&1 &
WRAPPER_PID=$!
echo "wrapper pid: $WRAPPER_PID"

# Wait for spawn + startup
sleep 6

# Capture log
echo
echo "==========================================="
echo "  Captured log ($LOG_FILE)"
echo "==========================================="
cat "$LOG_FILE" 2>/dev/null | head -60

# Verify TCP probe
echo
echo "==========================================="
echo "  TCP probe on 127.0.0.1:$PORT"
echo "==========================================="
lsof -i :$PORT 2>/dev/null | head -5 || echo "(no process listening on $PORT)"

# Try a curl
echo
echo "==> curl http://127.0.0.1:$PORT/"
curl -m 3 -sI "http://127.0.0.1:$PORT/" 2>&1 | head -5 || echo "(curl failed)"

# Cleanup
echo
echo "==> cleaning up"
kill $WRAPPER_PID 2>/dev/null || true
sleep 1
kill -9 $WRAPPER_PID 2>/dev/null || true
kill $LOG_PID 2>/dev/null || true
rm -f /tmp/wrapper-stdout.log

echo
echo "Test finished. Full log: $LOG_FILE"
