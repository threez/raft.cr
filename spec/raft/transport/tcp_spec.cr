require "../../spec_helper"

private def make_tcp_pair(cookie = "test-cookie")
  inbox_a = Channel(Raft::RPC::Envelope).new(capacity: 64)
  inbox_b = Channel(Raft::RPC::Envelope).new(capacity: 64)

  # Use port 0 for OS-assigned ports
  transport_a = Raft::Transport::TCP.new("127.0.0.1", 0, Hash(String, {String, Int32}).new, cookie)
  transport_a.start(inbox_a)
  port_a = transport_a.actual_port

  transport_b = Raft::Transport::TCP.new("127.0.0.1", 0, {"a" => {"127.0.0.1", port_a}}, cookie)
  transport_b.start(inbox_b)
  port_b = transport_b.actual_port

  # Update a's peer addresses with b's actual port
  transport_a_with_peers = Raft::Transport::TCP.new("127.0.0.1", port_a, {"b" => {"127.0.0.1", port_b}}, cookie)

  {transport_a, transport_a_with_peers, transport_b, inbox_a, inbox_b, port_a, port_b}
end

describe Raft::Transport::TCP do
  it "delivers messages over TCP" do
    inbox_a = Channel(Raft::RPC::Envelope).new(capacity: 64)
    inbox_b = Channel(Raft::RPC::Envelope).new(capacity: 64)
    cookie = "test-cookie"

    server_b = Raft::Transport::TCP.new("127.0.0.1", 0, Hash(String, {String, Int32}).new, cookie)
    server_b.start(inbox_b)
    port_b = server_b.actual_port

    client_a = Raft::Transport::TCP.new("127.0.0.1", 0, {"b" => {"127.0.0.1", port_b}}, cookie)
    client_a.start(inbox_a)

    msg = Raft::RPC::RequestVoteResponse.new(term: 42_u64, vote_granted: true)
    client_a.send("b", msg)

    # Wait for message
    envelope = select
    when env = inbox_b.receive
      env
    when timeout(2.seconds)
      nil
    end

    envelope.should_not be_nil
    envelope.not_nil!.message.as(Raft::RPC::RequestVoteResponse).term.should eq(42_u64)

    client_a.stop
    server_b.stop
  end

  it "handles multiple message types" do
    inbox = Channel(Raft::RPC::Envelope).new(capacity: 64)
    cookie = "test"

    server = Raft::Transport::TCP.new("127.0.0.1", 0, Hash(String, {String, Int32}).new, cookie)
    server.start(inbox)
    port = server.actual_port

    client = Raft::Transport::TCP.new("127.0.0.1", 0, {"srv" => {"127.0.0.1", port}}, cookie)
    client.start(Channel(Raft::RPC::Envelope).new(capacity: 1))

    entry = Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "hello".to_slice)
    msg = Raft::RPC::AppendEntries.new(
      term: 3_u64, leader_id: "leader", prev_log_index: 0_u64,
      prev_log_term: 0_u64, entries: [entry], leader_commit: 1_u64,
    )
    client.send("srv", msg)

    envelope = select
    when env = inbox.receive
      env
    when timeout(2.seconds)
      nil
    end

    envelope.should_not be_nil
    decoded = envelope.not_nil!.message.as(Raft::RPC::AppendEntries)
    decoded.term.should eq(3_u64)
    decoded.entries.size.should eq(1)
    decoded.entries[0].data.should eq("hello".to_slice)

    client.stop
    server.stop
  end

  it "stop closes server and connections" do
    inbox = Channel(Raft::RPC::Envelope).new(capacity: 64)
    transport = Raft::Transport::TCP.new("127.0.0.1", 0, Hash(String, {String, Int32}).new, "cookie")
    transport.start(inbox)
    transport.stop
    # Should not raise
  end

  it "drops messages to unreachable peers" do
    inbox = Channel(Raft::RPC::Envelope).new(capacity: 64)
    transport = Raft::Transport::TCP.new("127.0.0.1", 0, {"bad" => {"127.0.0.1", 1}}, "cookie")
    transport.start(inbox)

    msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
    transport.send("bad", msg) # should not raise, just drop

    transport.stop
  end
end
