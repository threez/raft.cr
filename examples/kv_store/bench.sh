#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "Building KV store..."
mkdir -p "$ROOT_DIR/bin"
crystal build "$SCRIPT_DIR/main.cr" -o "$ROOT_DIR/bin/kv_store" --release

echo "Cleaning data directories..."
rm -rf "$ROOT_DIR/data/node-"{1,2,3}

echo "Starting 3-node cluster..."
LOG_LEVEL=NONE "$ROOT_DIR/bin/kv_store" --node-id node-1 > /dev/null 2>&1 &
PID1=$!
sleep 0.5
LOG_LEVEL=NONE "$ROOT_DIR/bin/kv_store" --node-id node-2 > /dev/null 2>&1 &
PID2=$!
sleep 0.5
LOG_LEVEL=NONE "$ROOT_DIR/bin/kv_store" --node-id node-3 > /dev/null 2>&1 &
PID3=$!

cleanup() {
  echo ""
  echo "Stopping cluster..."
  kill $PID1 $PID2 $PID3 2>/dev/null
  wait $PID1 $PID2 $PID3 2>/dev/null
  rm -rf "$ROOT_DIR/data/node-"{1,2,3}
  echo "Done."
}
trap cleanup EXIT INT TERM

# Wait for leader election
echo "Waiting for leader..."
for i in $(seq 1 30); do
  if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8001/_leader 2>/dev/null | grep -q "204\|307"; then
    echo "Leader elected."
    break
  fi
  sleep 0.5
done

echo ""
echo "Running k6 benchmark..."
echo ""

k6 run "$SCRIPT_DIR/k6_bench.js" --no-usage-report --summary-trend-stats="avg,med,p(95),p(99)"
