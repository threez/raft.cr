# Concurrency Model

How Raft.cr uses Crystal fibers and channels to implement the consensus protocol.

## Single-Writer Event Loop

Each `Raft::Node` runs a single Crystal fiber that processes messages from a
central inbox channel. This "single-writer" design avoids locks entirely
within the consensus core — all state mutations happen on one fiber.

```
                ┌──────────────────────┐
 Transport ────▶│  inbox : Channel(    │
                │    NodeMessage)      │──────▶ Node fiber (event loop)
 Client API ───▶│                      │
                └──────────────────────┘
```

Messages arrive from three sources:
- **RPC::Envelope** — from the transport, tagged with sender node ID
- **ClientRequest** — from `Node#propose`, carrying a response channel
- **TimerTick** — from epoch-gated timer fibers

The event loop is a simple receive-and-dispatch loop. The node fiber is the
only fiber that reads or writes consensus state (`@current_term`, `@role`,
`@commit_index`, etc.).

## Epoch-Gated Timers

Crystal fibers cannot be cancelled. The node uses **epoch counters** to
invalidate stale timers without cancellation:

1. Each `reset_election_timer` call increments `@election_epoch` and captures
   the current value.
2. A new fiber is spawned that sleeps for a randomized duration.
3. When the fiber wakes, it checks if its captured epoch still matches the
   current `@election_epoch`. If not, the timer was reset — the tick is
   silently discarded.
4. If the epoch matches, the fiber sends a `TimerTick` into the inbox.

This prevents acting on stale timeouts (e.g., an election timer that fires
after a valid AppendEntries was already received and reset the timer).

The same pattern is used for the heartbeat timer (`@heartbeat_epoch`).

## Pre-Vote Protocol

Before incrementing its term and sending `RequestVote`, a node first runs a
**pre-vote round**:

1. Election timer fires → `start_pre_vote` sends `PreVote` RPCs with the
   *speculative* next term (current + 1), but does NOT actually increment.
2. Peers respond based on log up-to-date checks, without updating their own state.
3. If a majority grants pre-vote → `start_election` runs the real election
   (now safe to increment term).
4. If pre-vote fails (e.g., node is partitioned) → term stays the same.

This prevents partitioned nodes from inflating their terms, which would
disrupt the cluster leader when the partition heals.

## Leader Replication Fibers

When a node becomes leader, it spawns one `Raft::Node::Replicator` per
follower. Each replicator runs in its own fiber:

```
Leader fiber
  │
  ├── Replicator fiber (peer A) ──▶ Transport.send(A, AppendEntries)  ◀── ack(bool)
  ├── Replicator fiber (peer B) ──▶ Transport.send(B, AppendEntries)  ◀── ack(bool)
  └── Replicator fiber (peer C) ──▶ Transport.send(C, AppendEntries)  ◀── ack(bool)
          │
          └── responses arrive in node inbox as RPC::Envelope
```

Each replicator uses three signals:

- **Notify** — The leader calls `Replicator#notify` (non-blocking) when new
  entries are appended. The replicator wakes and sends the next pipelined batch.
- **Ack** — The leader calls `Replicator#ack(success)` after processing an
  `AppendEntriesResponse` that advances `match_index` (real entries replicated)
  or returns a failure. This allows the replicator to immediately send the next
  batch without waiting for the heartbeat timeout. Heartbeat responses (where
  `match_index` does not change) do not produce an ack; heartbeats are
  fire-and-forget and are not counted in `@inflight`.
- **Heartbeat timeout** — If neither notify nor ack arrives within the heartbeat
  interval, the replicator sends an empty `AppendEntries` to maintain authority.

### Pipelined send cursor

Each replicator maintains two positions for its peer:

| Field | Owner | Meaning |
|---|---|---|
| `@next_index[@peer_id]` | Leader event loop | Highest confirmed-replicated index + 1. Written on each `AppendEntriesResponse`. |
| `@pipeline_next_index` | Replicator fiber | Optimistic send cursor. May run ahead by up to `max_inflight_rpcs × max_entries_per_rpc` entries. |

The replicator sends up to `Config#max_inflight_rpcs` (default: 2) batches
before waiting. Each ack decrements `@inflight`; a failure ack resets
`@pipeline_next_index` to `@next_index[@peer_id]` and clears `@inflight`.
Subsequent stale failure acks from pipelined batches that also failed are
clamped by `{@inflight - 1, 0}.max` and have no further effect.

Heartbeats (empty `AppendEntries`) are sent only when `@inflight == 0` and
`@pipeline_next_index > @log.last_index` (nothing to pipeline). They are
always anchored to the confirmed `@next_index` rather than the optimistic cursor.
Heartbeat responses do not trigger `Replicator#ack` — they carry no new
`match_index` information and are not part of the pipeline window.

When a follower is too far behind (behind the snapshot index), the replicator
sends the snapshot in chunks via `InstallSnapshot` instead of `AppendEntries`,
and resets both cursors to `snap_index + 1`.

## Client-Request Batching

When the event-loop dequeues a `ClientRequest` it immediately attempts a
non-blocking drain of any additional `ClientRequest` messages waiting in
the inbox. All drained requests are appended to the log in a single
`Log#append` call and trigger one `notify_replicators` call. For
`Log::File` this collapses N fsyncs into 1; for `Transport::TCP` the
replicator naturally bundles the batch into one or a few `AppendEntries`
RPCs (up to `max_entries_per_rpc` entries each).

```
inbox:  [ClientReq(1), ClientReq(2), AppendEntriesResponse, ClientReq(3)]
         ▲
         first blocking receive

drain (non-blocking):
  batch    = [ClientReq(1), ClientReq(2), ClientReq(3)]
  deferred = [AppendEntriesResponse]

process deferred first → advance commit for earlier entries
process batch       → one log.append([entry1, entry2, entry3]) + one notify_replicators
```

Non-client messages collected during the drain are processed **before** the
batch. This preserves safety: a concurrent `AppendEntriesResponse` carrying a
higher term will trigger `step_down`, setting the role to Follower and causing
`handle_client_request_batch` to reject all queued requests — rather than
appending them under a stale term.

The batching is transparent to callers. Each `propose()` call creates its own
response channel and receives its own result; entries are resolved individually
as the commit index advances in `apply_committed_entries`.

## Performance Tuning

| Parameter | Default | Effect |
|---|---|---|
| `max_inflight_rpcs` | 2 | Pipeline depth per replicator. Increase to 4–8 on high-RTT networks to overlap more network round-trips. |
| `max_entries_per_rpc` | 100 | Max log entries per `AppendEntries` RPC. Increase for larger batches or high-throughput write workloads. |
| `heartbeat_interval` | 50 ms | Sets the replication floor latency and the leader authority timeout. Lower values reduce commit latency but increase steady-state traffic. |
| `snapshot_threshold` | 1000 | Log entries between auto-snapshots. Lower values reduce replay time on restart; higher values reduce compaction overhead during normal operation. |
