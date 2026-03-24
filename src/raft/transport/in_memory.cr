# In-memory transport for testing.
#
# Messages are delivered directly between fibers via a class-level channel
# registry — no sockets involved. Supports partition simulation via
# `partition` / `heal` class methods.
#
# Call `reset` between test cases to clear all registrations and partitions.
class Raft::Transport::InMemory < Raft::Transport
  @@registry = Hash(String, Channel(RPC::Envelope)).new
  @@partitions = Set({String, String}).new

  def initialize(@node_id : String)
  end

  def start(inbox : Channel(RPC::Envelope)) : Nil
    @@registry[@node_id] = inbox
  end

  def send(peer_id : String, message : RPC::Message) : Nil
    return if partitioned?(peer_id)
    if ch = @@registry[peer_id]?
      ch.send(RPC::Envelope.new(from: @node_id, message: message))
    end
  end

  def stop : Nil
    @@registry.delete(@node_id)
  end

  # Clears all registrations and partitions. Call in `before_each` blocks.
  def self.reset : Nil
    @@registry.clear
    @@partitions.clear
  end

  # Simulates a network partition between nodes *a* and *b* (bidirectional).
  def self.partition(a : String, b : String) : Nil
    @@partitions << {a, b}
  end

  # Removes the partition between nodes *a* and *b*, restoring connectivity.
  def self.heal(a : String, b : String) : Nil
    @@partitions.delete({a, b})
    @@partitions.delete({b, a})
  end

  private def partitioned?(peer_id : String) : Bool
    @@partitions.includes?({@node_id, peer_id}) || @@partitions.includes?({peer_id, @node_id})
  end
end
