# Raft log entry types and data structures.
abstract class Raft::Log
  # The type of a log entry, stored as a single byte on the wire.
  enum EntryType : UInt8
    # No-op entry. Appended by a new leader to establish commit authority.
    Noop = 0
    # Client command. Applied to the state machine when committed.
    Op = 1
    # Cluster membership change. Updates the peer list when committed.
    Config = 2
  end

  # A single entry in the Raft log.
  #
  # Entries are 1-indexed. Each entry records the Raft term in which it was
  # created, its type, and an opaque data payload.
  struct Entry
    # The 1-based position of this entry in the log.
    getter index : UInt64
    # The Raft term when this entry was created.
    getter term : UInt64
    # The type of this entry (Noop, Op, or Config).
    getter entry_type : EntryType
    # The opaque payload. For `Op` entries this is the client command;
    # for `Config` entries this is the serialized peer list.
    getter data : Bytes

    def initialize(@index : UInt64, @term : UInt64, @entry_type : EntryType, @data : Bytes = Bytes.empty)
    end
  end
end
