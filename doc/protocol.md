# Wire Protocols

Binary formats used for RPC communication and on-disk persistence.

## TLV Message Framing

Every RPC message on the wire uses Type-Length-Value framing with network
byte order (big-endian):

```
┌──────────┬──────────────┬─────────────────────┐
│ Type     │ Length       │ Value               │
│ 1 byte   │ 4 bytes      │ <Length> bytes      │
│ UInt8    │ UInt32 BE    │ serialized payload  │
└──────────┴──────────────┴─────────────────────┘
```

- **Type**: `RPC::Type` enum value (see table below).
- **Length**: Byte count of the serialized payload (excludes the 5-byte header).
- **Value**: Fields serialized with `IO::ByteFormat::BigEndian`. Strings are
  `UInt16 BE` length-prefixed, byte arrays `UInt32 BE` length-prefixed,
  booleans a single byte (0/1).

### RPC Type Tags

| Tag  | Message                |
|------|------------------------|
| 0x00 | Handshake              |
| 0x01 | RequestVote            |
| 0x02 | RequestVoteResponse    |
| 0x03 | AppendEntries          |
| 0x04 | AppendEntriesResponse  |
| 0x05 | InstallSnapshot        |
| 0x06 | InstallSnapshotResponse|
| 0x07 | PreVote                |
| 0x08 | PreVoteResponse        |
| 0xFF | Error                  |

See `Raft::RPC` source for full struct definitions and `Raft::RPC::Codec` for
the serialization implementation.

## Connection Handshake (Cookie Authentication)

The **first** TLV message on a new TCP connection is a `Handshake` frame
(type `0x00`). Both sides exchange a challenge and verify the peer holds the
same cookie. On failure, an `Error` frame (type `0xFF`) is sent before closing.

### Protocol Flow

```
Initiator                              Responder
    │                                      │
    │── TLV Handshake (0x00) ────────────▶ │  (hmac + nonce, 69 bytes)
    │                                      │  verify HMAC
    │                                      │  if invalid → TLV Error (0xFF), close
    │                                      │
    │ ◀──── TLV Handshake (0x00) ───────── │  (hmac + nonce, 69 bytes)
    │  verify HMAC                         │
    │  if invalid → close                  │
    │                                      │
    │ ◀════ TLV Raft messages ═══════════▶ │
```

### Handshake TLV Payload (type 0x00, 64 bytes payload)

```
┌──────────────────────────┬──────────────────────────┐
│ HMAC-SHA256(cookie, R)   │ R (random nonce)          │
│ 32 bytes                 │ 32 bytes                  │
└──────────────────────────┴──────────────────────────┘
```

### Error TLV Payload (type 0xFF)

```
┌─────────────────┬──────────────┐
│ message_len     │ message      │
│ 2 bytes         │ N bytes      │
│ UInt16 BE       │ UTF-8        │
└─────────────────┴──────────────┘
```

### Steps

1. **Initiator** generates 32 random bytes `R` via `Random::Secure`, computes
   `HMAC-SHA256(cookie, R)`, and writes the 64-byte frame.
2. **Responder** reads 64 bytes, splits into `received_hmac` and `R`, recomputes
   `HMAC-SHA256(cookie, R)` with its own cookie, and performs a **constant-time
   comparison**. If mismatch: write single byte `0xFF` and close the socket.
3. **Responder** generates its own 32 random bytes, computes its HMAC, and writes
   its 64-byte challenge back.
4. **Initiator** verifies the responder's HMAC the same way. If invalid: close.
5. Connection is now authenticated. TLV message exchange begins.

On failure, an `Error` TLV frame (type `0xFF`) is sent with a human-readable
message, then the connection is closed. Raises `Raft::Error::AuthenticationFailed`.

See `Raft::Transport::Handshake` source for the implementation.

## On-Disk Log Format

`Raft::Log::File` stores data in three files within its `data_dir`:

### log.bin — Append-only entry file

Each entry is a fixed-header record:

```
┌──────────┬──────────┬───────────┬──────────────┬──────────────┐
│ Index    │ Term     │ Type      │ Data Length  │ Data         │
│ 8 bytes  │ 8 bytes  │ 1 byte    │ 4 bytes      │ N bytes      │
│ UInt64BE │ UInt64BE │ UInt8     │ UInt32BE     │ raw bytes    │
└──────────┴──────────┴───────────┴──────────────┴──────────────┘
```

Header is 21 bytes + variable-length data. Incomplete trailing records
(from a crash mid-write) are detected during index rebuild and ignored.

### metadata.bin — Current term and voted-for

```
┌───────────────┬─────────────────┬──────────────┐
│ current_term  │ voted_for_len   │ voted_for    │
│ 8 bytes       │ 2 bytes         │ N bytes      │
│ UInt64 BE     │ UInt16 BE       │ UTF-8        │
└───────────────┴─────────────────┴──────────────┘
```

Written atomically via tmp+rename. `voted_for_len = 0` means no vote.

### snapshot.bin — State machine snapshot

```
┌───────────────┬───────────────┬──────────────┬──────────────┐
│ last_index    │ last_term     │ data_len     │ data         │
│ 8 bytes       │ 8 bytes       │ 4 bytes      │ N bytes      │
│ UInt64 BE     │ UInt64 BE     │ UInt32 BE    │ raw bytes    │
└───────────────┴───────────────┴──────────────┴──────────────┘
```

Written atomically via tmp+rename. After a successful snapshot, log entries
up to `last_index` are compacted (rewritten excluding old entries).
