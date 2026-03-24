#!/bin/bash
set -e

if [ "${1:-}" = "clean" ]; then
  echo "Cleaning data directories..."
  rm -rf ./data/node-{1,2,3}
  echo "Done."
  exit 0
fi

echo "Building KV store example..."
mkdir -p bin
crystal build examples/kv_store/main.cr -o bin/kv_store
crystal build examples/kv_store/client.cr -o bin/kv_client

echo "Starting 3-node cluster..."
./bin/kv_store --node-id node-1 &
PID1=$!
sleep 0.5
./bin/kv_store --node-id node-2 &
PID2=$!
sleep 0.5
./bin/kv_store --node-id node-3 &
PID3=$!
sleep 0.5

cleanup() {
  echo ""
  echo "Stopping all nodes..."
  kill $PID1 $PID2 $PID3 2>/dev/null
  wait $PID1 $PID2 $PID3 2>/dev/null
  rm -f bin/kv_store bin/kv_client
  echo "Done."
}
trap cleanup EXIT INT TERM

echo ""
echo "Cluster is running. Try with curl:"
echo "  curl -X PUT  localhost:8001/hello -d 'world'"
echo "  curl         localhost:8001/hello"
echo "  curl -X DELETE localhost:8001/hello"
echo "  curl         localhost:8001/_leader"
echo ""
echo "Or with the client CLI:"
echo "  bin/kv_client put hello world"
echo "  bin/kv_client get hello"
echo "  bin/kv_client delete hello"
echo "  bin/kv_client leader"
echo "  bin/kv_client status"
echo ""

wait
