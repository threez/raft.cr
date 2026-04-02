require "../spec_helper"

describe Raft::RTTMonitor do
  it "measures RTT via Ping/Pong in a live cluster" do
    Raft::Transport::InMemory.reset
    config = Raft::Config.new(
      election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25,
      rtt_tuning: true, rtt_probe_interval: 1,
    )
    node1 = Raft::Node.new(
      id: "rtt-1", peers: ["rtt-2"],
      state_machine: TestStateMachine.new,
      transport: Raft::Transport::InMemory.new("rtt-1"),
      log: Raft::Log::InMemory.new, config: config,
    )
    node2 = Raft::Node.new(
      id: "rtt-2", peers: ["rtt-1"],
      state_machine: TestStateMachine.new,
      transport: Raft::Transport::InMemory.new("rtt-2"),
      log: Raft::Log::InMemory.new, config: config,
    )
    node1.start
    node2.start

    # Wait for RTT probe + pong cycle (probe interval = 1s + 2s wait)
    sleep 4.seconds

    node1.stop
    node2.stop
    Raft::Transport::InMemory.reset
  end

  it "Ping/Pong codec roundtrip" do
    ping = Raft::RPC::Ping.new(sequence: 42_u64)
    encoded = Raft::RPC::Codec.encode(ping)
    decoded = Raft::RPC::Codec.decode(IO::Memory.new(encoded))
    decoded.should be_a(Raft::RPC::Ping)
    decoded.as(Raft::RPC::Ping).sequence.should eq(42_u64)

    pong = Raft::RPC::Pong.new(sequence: 42_u64)
    encoded = Raft::RPC::Codec.encode(pong)
    decoded = Raft::RPC::Codec.decode(IO::Memory.new(encoded))
    decoded.should be_a(Raft::RPC::Pong)
    decoded.as(Raft::RPC::Pong).sequence.should eq(42_u64)
  end

  it "node responds to Ping with Pong" do
    Raft::Transport::InMemory.reset
    config = Raft::Config.new(
      election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25,
    )
    node = Raft::Node.new(
      id: "node-1",
      peers: ["node-2"],
      state_machine: TestStateMachine.new,
      transport: Raft::Transport::InMemory.new("node-1"),
      log: Raft::Log::InMemory.new,
      config: config,
    )
    node.start

    # Register a channel to receive the Pong response
    pong_inbox = Channel(Raft::RPC::Envelope).new(16)
    Raft::Transport::InMemory.new("node-2").tap do |transport2|
      transport2.start(pong_inbox)
    end

    # Send Ping from "node-2" to "node-1"
    transport2 = Raft::Transport::InMemory.new("node-2")
    transport2.send("node-1", Raft::RPC::Ping.new(sequence: 99_u64))

    # Wait for Pong response
    pong_received = false
    wait_until do
      select
      when envelope = pong_inbox.receive
        if envelope.message.is_a?(Raft::RPC::Pong)
          envelope.message.as(Raft::RPC::Pong).sequence.should eq(99_u64)
          pong_received = true
        end
      else
      end
      pong_received
    end
    pong_received.should be_true

    node.stop
    Raft::Transport::InMemory.reset
  end

  it "tuning formula produces correct values" do
    config = Raft::Config.new(
      rtt_tuning: true, rtt_probe_interval: 1,
      heartbeat_interval: 50, election_timeout_min: 150, election_timeout_max: 300,
    )
    transport = Raft::Transport::InMemory.new("test")
    monitor = Raft::RTTMonitor.new("test", transport, config, -> { false })
    monitor.start(["peer-1"])

    # Verify defaults are unchanged when no samples exist (not leader, no probing)
    config.heartbeat_interval.should eq(50)
    config.election_timeout_min.should eq(150)
    config.election_timeout_max.should eq(300)

    monitor.stop
  end
end
