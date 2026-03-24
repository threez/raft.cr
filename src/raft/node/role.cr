class Raft::Node
  # The three possible states of a Raft node.
  enum Role
    # Passive state. Responds to RPCs and waits for a leader heartbeat.
    Follower
    # Transitional state during an election. Requests votes from peers.
    Candidate
    # Active state. Handles client requests, replicates log, sends heartbeats.
    Leader
  end

  # A client command submitted via `Node#propose`, waiting for commit.
  # :nodoc:
  struct ClientRequest
    getter command : Bytes
    getter response_channel : Channel(ClientResponse)

    def initialize(@command : Bytes, @response_channel : Channel(ClientResponse))
    end
  end

  # The result of a client proposal, delivered via the response channel.
  # :nodoc:
  struct ClientResponse
    getter? success : Bool
    getter data : Bytes
    getter leader_hint : String?

    def initialize(@success : Bool, @data : Bytes, @leader_hint : String? = nil)
    end
  end

  # Internal timer event sent by epoch-gated timer fibers.
  # :nodoc:
  struct TimerTick
    enum Kind
      Election
      Heartbeat
    end

    getter kind : Kind
    getter epoch : UInt64

    def initialize(@kind : Kind, @epoch : UInt64 = 0_u64)
    end
  end

  # Tracks a pending client request awaiting commit.
  # :nodoc:
  record PendingRequest, index : UInt64, channel : Channel(ClientResponse)

  # Union of all message types the node event loop processes.
  # :nodoc:
  alias NodeMessage = RPC::Envelope | ClientRequest | TimerTick
end
