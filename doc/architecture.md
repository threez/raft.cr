# Raft.cr Architecture

Crystal implementation of the [Raft consensus algorithm](https://raft.github.io/raft.pdf),
modeled after [andrewjstone/rafter](https://github.com/andrewjstone/rafter) (Erlang).

## Design Principles

1. **Fibers as processes** — Each Raft node runs inside a Crystal fiber. Inter-fiber
   communication uses typed `Channel(T)` values, mirroring Erlang's mailbox model.
2. **Pluggable transport** — The `Raft::Transport` abstract class decouples consensus
   logic from networking. Swap TCP for in-memory without changing any node code.
3. **Pluggable state machine** — Users implement `Raft::StateMachine` to define
   what "apply" means. The library handles replication; the user handles semantics.
4. **Pluggable log** — `Raft::Log` is an abstract class with `InMemory` and
   `File` implementations. Choose storage strategy at construction time.
5. **Deterministic by default** — All non-determinism (time, network) is injected,
   making the consensus core fully testable.

## Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│                      Client API                         │
│         propose(cmd) / read(cmd) / add_peer / stop      │
└──────────────────────────┬──────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                     Raft::Node                          │
│  ┌──────────┐  ┌───────────┐  ┌────────┐                │
│  │ Follower │◄─┤ Candidate │◄─┤ Leader │                │
│  └────┬─────┘  └─────┬─────┘  └───┬────┘                │
│       │              │             │                    │
│       └──────────────┴─────────────┘                    │
│                      │                                  │
│         ┌────────────┼─────────────┐                    │
│         ▼            ▼            ▼                    │
│   ┌──────────┐ ┌──────────┐ ┌─────────────┐             │
│   │ Raft::Log│ │ Raft::RPC│ │Raft::Config │             │
│   └──────────┘ └──────────┘ └─────────────┘             │
└──────────────────────────┬──────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
┌──────────────────────┐  ┌──────────────────────────┐
│  Raft::StateMachine  │  │    Raft::Transport       │
│  (user-provided)     │  │    (abstract)            │
│                      │  │  ┌────────────────────┐  │
│  apply(cmd) : Bytes  │  │  │ Transport::TCP     │  │
│  snapshot() : Bytes  │  │  │ (TLV framing)      │  │
│  restore(data)       │  │  ├────────────────────┤  │
│                      │  │  │ Transport::InMemory │  │
│                      │  │  │ (testing)           │  │
└──────────────────────┘  └──────────────────────────┘
```

## Module Structure

```
src/
├── raft.cr                        # Top-level require, VERSION
├── raft/
│   ├── node.cr                    # Raft::Node — consensus fiber + state transitions
│   ├── node/
│   │   ├── role.cr                # Role enum, internal message types
│   │   ├── follower.cr            # Follower state handler module
│   │   ├── candidate.cr           # Candidate state handler (pre-vote + election)
│   │   ├── leader.cr              # Leader state handler (replication, commit)
│   │   └── replicator.cr          # Per-peer replication fiber (pipelined AppendEntries)
│   ├── log.cr                     # Raft::Log — abstract log interface
│   ├── log/
│   │   ├── entry.cr               # Raft::Log::Entry struct + EntryType enum
│   │   ├── in_memory.cr           # Raft::Log::InMemory
│   │   └── file.cr                # Raft::Log::File — on-disk persistence
│   ├── rpc.cr                     # RPC message structs + Envelope + Message union
│   ├── rpc/codec.cr               # TLV binary serialization
│   ├── metrics.cr                 # Observable counters
│   ├── state_machine.cr           # Abstract state machine interface
│   ├── config.cr                  # Cluster configuration
│   ├── error.cr                   # Error hierarchy
│   ├── transport.cr               # Abstract transport interface
│   └── transport/
│       ├── tcp.cr                 # TCP + TLV + connection pooling
│       ├── in_memory.cr           # Fiber-to-fiber delivery (testing)
│       └── handshake.cr           # HMAC-SHA256 cookie authentication
```

## Client-Request Batching

When the leader event-loop receives a `ClientRequest` it non-blockingly drains
any additional `ClientRequest` messages already queued in the inbox, then issues
a single `Log#append(entries)` for the whole batch and one `notify_replicators`
call. For `Log::File` this turns N fsyncs into 1; the replicator then naturally
sends the batch as one or a few `AppendEntries` RPCs. Callers receive individual
responses as entries commit — batching is transparent to `Node#propose`.

## Replication Pipeline

The `Replicator` keeps up to `Config#max_inflight_rpcs` (default: 2) `AppendEntries`
RPCs in-flight per follower simultaneously, overlapping the network round-trip of batch N
with the sending of batch N+1. This is allowed by §10.2.1 of the Raft dissertation.

Each replicator maintains two cursors:

| Cursor | Meaning |
|---|---|
| `@next_index` (shared with leader) | Highest index confirmed replicated on this follower — updated by the leader event loop on each `AppendEntriesResponse`. |
| `@pipeline_next_index` (replicator-local) | Optimistic send cursor — may run ahead by up to `max_inflight_rpcs × max_entries_per_rpc` entries. Reset to `@next_index` on failure. |

The leader event loop calls `Replicator#ack(success)` after processing an
`AppendEntriesResponse` that advances `match_index` (real entries replicated) or
returns a failure, unblocking the replicator to send the next batch immediately
rather than waiting for the heartbeat timeout. Heartbeat responses (where
`match_index` does not advance) do not produce an ack — heartbeats are
fire-and-forget and are not tracked in the inflight window. Set `max_inflight_rpcs: 1`
to disable pipelining and revert to one RPC per round-trip.

## Durability Guarantees

| Storage backend | Durability |
|---|---|
| `Log::InMemory` | None — all data is lost on restart. Use for testing only. |
| `Log::File` (`fsync: true`, default) | Full durability. Every log entry write and every metadata/snapshot rename is preceded by `fsync(2)`, and the directory entry is synced after each rename. Safe against power loss and kernel panics. |
| `Log::File` (`fsync: false`) | OS page-cache only. Faster, but data flushed to the kernel since the last OS writeback can be lost on a hard crash. Acceptable when an external restore path exists — for example, replicated block storage (EBS, Ceph RBD), periodic backups, or a peer node that always holds the complete log. |

The default is `fsync: true`. Opt out explicitly only when you have a tested recovery procedure that does not depend on the local disk being durable:

```crystal
log = Raft::Log::File.new("/var/lib/raft/node-1")               # fsync on (safe default)
log = Raft::Log::File.new("/var/lib/raft/node-1", fsync: false) # page-cache only
```

## Further Documentation

- **[Protocol](protocol.md)** — Wire formats (TLV, handshake, on-disk log)
- **[Concurrency](concurrency.md)** — Fiber model, timers, replicator design
- **[examples/kv_store/](../examples/kv_store/)** — Runnable 3-node KV store with HTTP API

API documentation for all public types is in the source code doc comments.
Generate browsable docs with `crystal docs`.
