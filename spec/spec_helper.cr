require "spec"
require "../src/raft"

class PipeIO < IO
  def initialize(@reader : IO, @writer : IO)
  end

  def read(slice : Bytes) : Int32
    @reader.read(slice)
  end

  def write(slice : Bytes) : Nil
    @writer.write(slice)
  end
end

class TestStateMachine < Raft::StateMachine
  getter applied = Array(Bytes).new

  def apply(command : Bytes) : Bytes
    @applied << command
    command
  end

  def snapshot : Bytes
    Bytes.empty
  end

  def restore(io : IO) : Nil
  end
end

class TestCluster
  getter nodes : Array(Raft::Node)

  def initialize(size : Int32, config : Raft::Config? = nil)
    Raft::Transport::InMemory.reset
    cfg = config || Raft::Config.new(
      election_timeout_min: 50,
      election_timeout_max: 100,
      heartbeat_interval: 25,
    )
    ids = (1..size).map { |i| "node-#{i}" }
    @nodes = ids.map do |id|
      peers = ids.reject { |peer| peer == id }
      Raft::Node.new(
        id: id,
        peers: peers,
        state_machine: TestStateMachine.new,
        transport: Raft::Transport::InMemory.new(id),
        log: Raft::Log::InMemory.new,
        config: cfg,
      )
    end
  end

  def start : Nil
    @nodes.each(&.start)
  end

  def stop : Nil
    @nodes.each(&.stop)
  end

  def wait_for_leader(timeout_ms = 2000) : Raft::Node
    deadline = Time.instant + timeout_ms.milliseconds
    loop do
      if leader = @nodes.find(&.role.leader?)
        return leader
      end
      raise "No leader elected within timeout" if Time.instant > deadline
      sleep 10.milliseconds
    end
  end

  def leader : Raft::Node?
    @nodes.find(&.role.leader?)
  end
end
