module Raft
  # Base exception class for all Raft errors.
  class Error < Exception; end

  # Raised when an operation requires the leader role but this node is not the leader.
  #
  # The `leader_hint` field, when set, contains the ID of the node believed to be
  # the current leader, allowing clients to redirect their requests.
  class Error::NotLeader < Error
    # The ID of the current leader, if known. `nil` when the leader is unknown.
    getter leader_hint : String?

    def initialize(@leader_hint : String? = nil)
      super("Not the leader#{@leader_hint ? ", try #{@leader_hint}" : ""}")
    end
  end

  # Raised when an operation exceeds its deadline. Reserved for future use.
  class Error::Timeout < Error; end

  # Raised when an operation is attempted on a node that has been shut down.
  class Error::Shutdown < Error; end

  # Raised when an unknown command is received by a state machine.
  class Error::UnknownCommand < Error; end

  # Raised when a log file is corrupted or contains invalid data.
  class Error::LogCorrupted < Error; end

  # Raised when a network connection to a peer fails.
  class Error::ConnectionFailed < Error; end

  # Raised when a cluster membership change is invalid.
  class Error::ConfigChange < Error; end

  # Raised when HMAC-SHA256 cookie authentication fails during a transport handshake.
  class Error::AuthenticationFailed < Error
    def initialize(message : String = "Authentication failed")
      super(message)
    end
  end
end
