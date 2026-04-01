# raft.cr

A Crystal implementation of the [Raft consensus algorithm](https://raft.github.io/raft.pdf) for building distributed systems with strong consistency guarantees.

## Features

- **Leader election** with pre-vote protocol (prevents term inflation from partitioned nodes)
- **Log replication** with conflict detection and per-follower replicator fibers
- **Pluggable transport** -- TCP with TLV framing and HMAC-SHA256 authentication, or in-memory for testing
- **Pluggable storage** -- in-memory or file-backed with crash recovery and log compaction
- **Pluggable state machine** -- implement three methods to replicate any application state
- **Snapshots** -- multi-chunk transfer for lagging followers
- **Dynamic membership** -- add and remove peers at runtime
- **Metrics** -- elections, proposals, commits, term, and role observable via `node.metrics`
- **Deterministic testing** -- all non-determinism is injected; full cluster tests run in-process

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  raft:
    github: threez/raft.cr
```

Then run `shards install`.

## Quick Start

```crystal
require "raft"

# 1. Implement your state machine
class MyApp < Raft::StateMachine
  def apply(command : Bytes) : Bytes
    # execute command, return result
  end

  # Optional: override for bulk optimizations (e.g. a single DB transaction per batch)
  def apply(commands : Array(Bytes)) : Array(Bytes)
    commands.map { |cmd| apply(cmd) }
  end

  def snapshot : Bytes
    # serialize state
  end

  def restore(io : IO) : Nil
    # restore from snapshot
  end
end

# 2. Create and start a node
node = Raft::Node.new(
  id: "node-1",
  peers: ["node-2", "node-3"],
  state_machine: MyApp.new,
  transport: Raft::Transport::TCP.new("0.0.0.0", 7001, {
    "node-2" => {"192.168.1.11", 7002},
    "node-3" => {"192.168.1.12", 7003},
  }, cookie: "shared-secret"),
  log: Raft::Log::File.new("/var/lib/raft/node-1"),
)
node.start

# 3. Propose commands (leader only, blocks until committed)
result = node.propose("SET key value".to_slice)

# 4. Linearizable read (confirms leadership, then reads locally)
value = node.read("GET key".to_slice)

# 5. Shut down
node.stop
```

## Example: Distributed KV Store

A complete 3-node KV store with an HTTP API lives in [`examples/kv_store/`](examples/kv_store/).

```bash
# Build and run the cluster
./examples/kv_store/run.sh

# In another terminal
bin/kv_client put hello world    # store a value
bin/kv_client get hello          # retrieve it
bin/kv_client delete hello       # remove it
bin/kv_client status             # view node metrics
bin/kv_client leader             # find the leader

# Or use curl directly
curl -X PUT localhost:8001/hello -d 'world'
curl localhost:8001/hello
curl localhost:8001/_status
```

The example demonstrates TCP transport, file-backed persistence, HMAC authentication, HTTP API with automatic leader redirection (307), and a CLI client.

## Architecture

```
Client API (propose / read / add_peer / stop)
        |
   Raft::Node  [Follower <-> Candidate <-> Leader]
        |
   Log / RPC / Config
        |
  +-----------+--------------+
  |                          |
StateMachine (yours)    Transport (TCP / InMemory)
```

Each node runs a **single event-loop fiber** -- all state mutations happen on one fiber, eliminating locks. Leader spawns per-follower **replicator fibers** that send `AppendEntries` and heartbeats. Communication uses **TLV binary framing** with HMAC-SHA256 cookie authentication on TCP connections.

See the [design documentation](doc/) for details:
- [Architecture](doc/architecture.md) -- design principles, component diagram, module structure
- [Protocol](doc/protocol.md) -- TLV wire format, handshake protocol, on-disk log format
- [Concurrency](doc/concurrency.md) -- fiber model, epoch-gated timers, replicator design

## API Overview

| Class | Purpose |
|-------|---------|
| `Raft::Node` | Consensus node -- `start`, `stop`, `propose`, `read`, `add_peer`, `remove_peer` |
| `Raft::StateMachine` | Abstract -- implement `apply`, `snapshot`, `restore` |
| `Raft::Log::InMemory` | In-memory log for testing |
| `Raft::Log::File` | File-backed log with crash recovery |
| `Raft::Transport::TCP` | TCP transport with TLV + HMAC-SHA256 |
| `Raft::Transport::InMemory` | In-process transport for testing (with partition simulation) |
| `Raft::Config` | Election timeouts, heartbeat interval, cookie, chunk size |
| `Raft::Metrics` | Observable counters -- access via `node.metrics` |

Full API documentation: `crystal docs`

## Development

```bash
make           # clean, format, lint, docs, spec
make spec      # run tests (100 specs)
make lint      # ameba linter
make fmt       # crystal format
make bench     # codec throughput, election latency, propose/sec
make example   # build KV store server + client
make docs      # generate API docs
```

Requires Crystal >= 1.19.1.

## Contributing

1. Fork it (<https://github.com/threez/raft.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

[MIT](LICENSE) -- Vincent Landgraf
