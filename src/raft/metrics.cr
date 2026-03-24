module Raft
  # Observable counters and state for a Raft node.
  #
  # Access via `Node#metrics`. Counters are incremented internally as the
  # node operates. All fields are readable and can be scraped for monitoring.
  class Metrics
    # Number of elections this node has initiated.
    property elections_started : UInt64 = 0_u64

    # Number of elections this node has won (became leader).
    property elections_won : UInt64 = 0_u64

    # Number of client proposals that were committed and applied.
    property proposals_committed : UInt64 = 0_u64

    # Total number of log entries applied to the state machine.
    property entries_applied : UInt64 = 0_u64

    # Number of snapshots installed from a leader.
    property snapshots_installed : UInt64 = 0_u64

    # Number of times a client-request batch was processed by the leader.
    # Each batch may contain one or more proposals. For concurrent workloads,
    # this should be less than `proposals_committed` when batching is active.
    property batches_processed : UInt64 = 0_u64

    # Current Raft term.
    property term : UInt64 = 0_u64

    # Index of the highest committed log entry.
    property commit_index : UInt64 = 0_u64

    # Current role as a string: `"follower"`, `"candidate"`, or `"leader"`.
    property role : String = "follower"

    # Returns all metrics as a flat hash.
    def to_h : Hash(String, UInt64 | String)
      {
        "elections_started"   => @elections_started,
        "elections_won"       => @elections_won,
        "proposals_committed" => @proposals_committed,
        "entries_applied"     => @entries_applied,
        "snapshots_installed" => @snapshots_installed,
        "batches_processed"   => @batches_processed,
        "term"                => @term,
        "commit_index"        => @commit_index,
        "role"                => @role,
      } of String => UInt64 | String
    end
  end
end
