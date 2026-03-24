module Raft
  # Abstract base class for user-provided state machines.
  #
  # Implement this class to define the application logic that is replicated
  # across the Raft cluster. All methods must be **deterministic** — given the
  # same sequence of commands, every replica must produce identical state.
  #
  # ```
  # class KVStore < Raft::StateMachine
  #   def apply(command : Bytes) : Bytes
  #     # parse and execute command, return result
  #   end
  #
  #   def snapshot : Bytes
  #     # serialize entire state
  #   end
  #
  #   def restore(io : IO) : Nil
  #     # replace state from snapshot
  #   end
  # end
  # ```
  abstract class StateMachine
    # Applies a committed command to the state machine and returns a response.
    #
    # Called by the Raft node after a log entry is committed (replicated to a
    # majority). The returned bytes are sent back to the client that proposed
    # the command via `Node#propose`.
    abstract def apply(command : Bytes) : Bytes

    # Serializes the entire current state for snapshotting.
    #
    # Called when the leader needs to send a snapshot to a lagging follower
    # via the `InstallSnapshot` RPC.
    abstract def snapshot : Bytes

    # Replaces the current state from a snapshot.
    #
    # Called when this node receives a snapshot from the leader because it
    # is too far behind to catch up via normal log replication.
    abstract def restore(io : IO) : Nil
  end
end
