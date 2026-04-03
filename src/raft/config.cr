module Raft
  # Configuration parameters for a Raft node.
  #
  # All timeout values are in milliseconds. Sensible defaults are provided
  # for production use. For testing, use shorter timeouts (e.g., 50-100ms
  # election timeout, 25ms heartbeat).
  struct Config
    # Minimum election timeout in milliseconds. A follower that receives no
    # heartbeat within a random duration between this and `election_timeout_max`
    # will start a pre-vote round.
    property election_timeout_min : Int32

    # Maximum election timeout in milliseconds.
    property election_timeout_max : Int32

    # Heartbeat interval in milliseconds. The leader sends heartbeats to
    # followers at this interval to maintain authority. Should be significantly
    # less than the election timeout.
    property heartbeat_interval : Int32

    # Maximum number of log entries to include in a single `AppendEntries` RPC.
    property max_entries_per_rpc : Int32

    # Pre-shared key for HMAC-SHA256 connection authentication.
    # Used by `Transport::TCP` and `Transport::Handshake`.
    property cookie : String

    # Maximum size in bytes of each snapshot chunk sent via `InstallSnapshot` RPC.
    property snapshot_chunk_size : Int32

    # Number of applied entries since the last snapshot before automatically
    # triggering a new snapshot. Set to 0 to disable auto-snapshots.
    property snapshot_threshold : Int32

    # Maximum number of in-flight `AppendEntries` RPCs per replicator (pipeline depth).
    # Higher values improve throughput when network RTT is the bottleneck by overlapping
    # consecutive batches. Set to 1 to disable pipelining and match pre-pipeline behaviour.
    property max_inflight_rpcs : Int32

    # Enable active-passive mode for 2-node clusters. Lowers quorum to 1 so
    # either node can elect itself and accept writes when the other is down.
    #
    # **WARNING**: This sacrifices consistency for availability. During a
    # network partition both nodes may accept writes independently. When the
    # partition heals, the node with the lower term loses its divergent entries
    # via normal Raft log conflict resolution. Only use when availability is
    # more important than strict consistency.
    getter? active_passive : Bool

    # Enable automatic RTT-based timeout tuning. When enabled, the node
    # periodically measures round-trip time to peers and adjusts heartbeat
    # and election timeouts following etcd best practices.
    getter? rtt_tuning : Bool

    # Interval in seconds between RTT measurement probes. Default: 60.
    property rtt_probe_interval : Int32

    # Creates a `Config` with all fields set to their defaults.
    #
    # All parameters are keyword arguments matching the property names.
    # Defaults are appropriate for local clusters; adjust timeouts based on
    # your network RTT (or enable `rtt_tuning` for automatic tuning).
    def initialize(
      @election_timeout_min : Int32 = 150,
      @election_timeout_max : Int32 = 300,
      @heartbeat_interval : Int32 = 50,
      @max_entries_per_rpc : Int32 = 100,
      @cookie : String = "",
      @snapshot_chunk_size : Int32 = 65536,
      @snapshot_threshold : Int32 = 1000,
      @max_inflight_rpcs : Int32 = 2,
      @active_passive : Bool = false,
      @rtt_tuning : Bool = false,
      @rtt_probe_interval : Int32 = 60,
    )
    end
  end
end
