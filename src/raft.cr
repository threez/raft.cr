require "./raft/error"
require "./raft/log/entry"
require "./raft/config"
require "./raft/state_machine"
require "./raft/metrics"
require "./raft/rpc"
require "./raft/rpc/codec"
require "./raft/log"
require "./raft/log/in_memory"
require "./raft/log/file"
require "./raft/transport"
require "./raft/transport/in_memory"
require "./raft/transport/handshake"
require "./raft/transport/tcp"
require "./raft/node/role"
require "./raft/node/follower"
require "./raft/node/candidate"
require "./raft/node/leader"
require "./raft/node/replicator"
require "./raft/rtt_monitor"
require "./raft/node"

# Raft consensus algorithm implementation for Crystal.
#
# Provides a library for building distributed systems with strong consistency
# guarantees. A cluster of `Raft::Node` instances elect a leader, replicate a
# command log, and apply committed entries to a user-provided state machine.
#
# ```
# node = Raft::Node.new(
#   id: "node-1",
#   peers: ["node-2", "node-3"],
#   state_machine: my_state_machine,
#   transport: Raft::Transport::InMemory.new("node-1"),
#   log: Raft::Log::InMemory.new,
# )
# node.start
# result = node.propose("SET key value".to_slice)
# node.stop
# ```
module Raft
  VERSION = "0.2.0"
end
