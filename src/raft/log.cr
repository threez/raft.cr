# Abstract base class for the Raft replicated log.
#
# The log stores an ordered sequence of entries, persistent metadata (current
# term and voted-for), and snapshots. Entries are 1-indexed — index 0 means
# "no entry" (empty log).
#
# Two implementations are provided:
# - `Log::InMemory` — all data held in memory, suitable for testing
# - `Log::File` — on-disk persistence with crash recovery
#
# ```
# log = Raft::Log::InMemory.new      # for testing
# log = Raft::Log::File.new("/data") # for production
# ```
abstract class Raft::Log
  # Persistent metadata that survives restarts: the current term and
  # the candidate this node voted for (if any) in the current term.
  record Metadata, current_term : UInt64, voted_for : String?

  # Appends entries to the log with conflict detection.
  #
  # If an existing entry at the same index has a different term, all entries
  # from that index onward are truncated before appending. Entries with
  # matching index and term are skipped (idempotent).
  abstract def append(entries : Array(Entry)) : Nil

  # Returns the entry at the given 1-based *index*, or `nil` if not present.
  abstract def get(index : UInt64) : Entry?

  # Returns the index of the last entry, or `0` if the log is empty.
  abstract def last_index : UInt64

  # Returns the term of the last entry, or `0` if the log is empty.
  abstract def last_term : UInt64

  # Returns the term of the entry at *index*, or `nil` if not present.
  abstract def term_at(index : UInt64) : UInt64?

  # Removes all entries at *index* and beyond (inclusive).
  abstract def truncate_from(index : UInt64) : Nil

  # Returns entries in the inclusive range [*from*, *to*].
  abstract def slice(from : UInt64, to : UInt64) : Array(Entry)

  # Yields each entry in the inclusive range [*from*, *to*] without
  # allocating an intermediate array. Preferred over `slice` on hot paths.
  abstract def each_in_range(from : UInt64, to : UInt64, & : Entry ->) : Nil

  # Persists the node's current term and voted-for state.
  abstract def save_metadata(meta : Metadata) : Nil

  # Loads the persisted metadata, or returns defaults (term 0, no vote).
  abstract def load_metadata : Metadata

  # Saves a snapshot and compacts the log up to *last_index*.
  #
  # All entries with index <= *last_index* are removed from the log.
  abstract def save_snapshot(last_index : UInt64, last_term : UInt64, data : Bytes) : Nil

  # Loads the most recent snapshot, or returns `nil` if none exists.
  #
  # Returns a tuple of `{last_included_index, last_included_term, snapshot_data}`.
  abstract def load_snapshot : {UInt64, UInt64, Bytes}?

  # Releases any resources held by the log (e.g., file handles).
  abstract def close : Nil
end
