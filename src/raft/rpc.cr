# Raft RPC message definitions and transport types.
#
# All messages are standalone structs combined into the `Message` union alias.
# Each struct has a `#type` method returning its `Type` enum tag and a
# `getter term` for the Raft term. Boolean fields use `getter?` per Crystal convention.
# Serialization is handled by `RPC::Codec`, not per-struct methods.
module Raft::RPC
  # Wire type tags for TLV framing. Each message type has a unique 1-byte tag.
  enum Type : UInt8
    Handshake               = 0x00
    RequestVote             = 0x01
    RequestVoteResponse     = 0x02
    AppendEntries           = 0x03
    AppendEntriesResponse   = 0x04
    InstallSnapshot         = 0x05
    InstallSnapshotResponse = 0x06
    PreVote                 = 0x07
    PreVoteResponse         = 0x08
    Error                   = 0xFF
  end

  # Sent by a candidate to request a vote from a peer during an election.
  struct RequestVote
    # The candidate's current term.
    getter term : UInt64
    # The ID of the candidate requesting the vote.
    getter candidate_id : String
    # Index of the candidate's last log entry.
    getter last_log_index : UInt64
    # Term of the candidate's last log entry.
    getter last_log_term : UInt64

    def initialize(@term : UInt64, @candidate_id : String, @last_log_index : UInt64, @last_log_term : UInt64)
    end

    def type : Type
      Type::RequestVote
    end
  end

  # Response to a `RequestVote` RPC.
  struct RequestVoteResponse
    # The responder's current term.
    getter term : UInt64
    # `true` if the vote was granted.
    getter? vote_granted : Bool

    def initialize(@term : UInt64, @vote_granted : Bool)
    end

    def type : Type
      Type::RequestVoteResponse
    end
  end

  # Sent by the leader to replicate log entries and serve as heartbeat.
  #
  # An empty `entries` array acts as a heartbeat without appending any entries.
  struct AppendEntries
    # The leader's current term.
    getter term : UInt64
    # The ID of the leader, so followers can redirect clients.
    getter leader_id : String
    # Index of the log entry immediately preceding the new entries.
    getter prev_log_index : UInt64
    # Term of the entry at `prev_log_index`.
    getter prev_log_term : UInt64
    # Log entries to append (empty for heartbeats).
    getter entries : Array(Log::Entry)
    # The leader's commit index.
    getter leader_commit : UInt64

    def initialize(@term : UInt64, @leader_id : String, @prev_log_index : UInt64,
                   @prev_log_term : UInt64, @entries : Array(Log::Entry), @leader_commit : UInt64)
    end

    def type : Type
      Type::AppendEntries
    end
  end

  # Response to an `AppendEntries` RPC.
  struct AppendEntriesResponse
    # The responder's current term.
    getter term : UInt64
    # `true` if the entries were accepted.
    getter? success : Bool
    # The highest log index replicated on the responder.
    getter match_index : UInt64

    def initialize(@term : UInt64, @success : Bool, @match_index : UInt64)
    end

    def type : Type
      Type::AppendEntriesResponse
    end
  end

  # Sent by the leader to transfer a snapshot to a lagging follower.
  #
  # Large snapshots are sent in multiple chunks. Each chunk carries an `offset`
  # and `data` slice. The final chunk sets `done` to `true`.
  struct InstallSnapshot
    # The leader's current term.
    getter term : UInt64
    # The ID of the leader.
    getter leader_id : String
    # The last log index included in the snapshot.
    getter last_included_index : UInt64
    # The term of the last included log entry.
    getter last_included_term : UInt64
    # Byte offset of this chunk within the full snapshot.
    getter offset : UInt64
    # Raw snapshot data for this chunk.
    getter data : Bytes
    # `true` if this is the final chunk of the snapshot.
    getter? done : Bool

    def initialize(@term : UInt64, @leader_id : String, @last_included_index : UInt64,
                   @last_included_term : UInt64, @offset : UInt64, @data : Bytes, @done : Bool)
    end

    def type : Type
      Type::InstallSnapshot
    end
  end

  # Response to an `InstallSnapshot` RPC.
  struct InstallSnapshotResponse
    # The responder's current term.
    getter term : UInt64

    def initialize(@term : UInt64)
    end

    def type : Type
      Type::InstallSnapshotResponse
    end
  end

  # Sent before a real election to check if the candidate would win,
  # without incrementing its term. Prevents partitioned nodes from
  # disrupting the cluster with inflated terms.
  struct PreVote
    # The speculative next term (current term + 1, not yet committed).
    getter term : UInt64
    # The ID of the candidate.
    getter candidate_id : String
    # Index of the candidate's last log entry.
    getter last_log_index : UInt64
    # Term of the candidate's last log entry.
    getter last_log_term : UInt64

    def initialize(@term : UInt64, @candidate_id : String, @last_log_index : UInt64, @last_log_term : UInt64)
    end

    def type : Type
      Type::PreVote
    end
  end

  # Response to a `PreVote` RPC.
  struct PreVoteResponse
    # The responder's current term.
    getter term : UInt64
    # `true` if the pre-vote was granted.
    getter? vote_granted : Bool

    def initialize(@term : UInt64, @vote_granted : Bool)
    end

    def type : Type
      Type::PreVoteResponse
    end
  end

  # HMAC-SHA256 challenge frame for connection authentication.
  #
  # Sent as the first TLV message on a new TCP connection. Both sides exchange
  # a challenge and verify the peer holds the same cookie.
  struct Handshake
    # HMAC-SHA256 digest of the cookie and nonce (32 bytes).
    getter hmac : Bytes
    # Random nonce (32 bytes).
    getter nonce : Bytes

    def initialize(@hmac : Bytes, @nonce : Bytes)
    end

    def type : Type
      Type::Handshake
    end
  end

  # General-purpose error frame sent before closing a connection.
  #
  # Used by the handshake responder to signal authentication failure.
  # Can be reused for other protocol-level errors in the future.
  struct ErrorMessage
    # Human-readable error description.
    getter message : String

    def initialize(@message : String)
    end

    def type : Type
      Type::Error
    end
  end

  # Union of all RPC message types (including handshake and error frames).
  alias Message = RequestVote | RequestVoteResponse | AppendEntries | AppendEntriesResponse | InstallSnapshot | InstallSnapshotResponse | PreVote | PreVoteResponse | Handshake | ErrorMessage

  # Wraps an RPC message with the sender's node ID.
  #
  # Created by the transport layer so the receiving node can attribute
  # responses to specific peers (e.g., knowing which peer granted a vote).
  struct Envelope
    # The node ID of the sender.
    getter from : String
    # The RPC message.
    getter message : Message

    def initialize(@from : String, @message : Message)
    end
  end
end
