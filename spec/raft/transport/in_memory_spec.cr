require "../../spec_helper"

private def receive_with_timeout(ch : Channel(Raft::RPC::Envelope), ms = 50) : Raft::RPC::Envelope?
  select
  when msg = ch.receive
    msg
  when timeout(ms.milliseconds)
    nil
  end
end

describe Raft::Transport::InMemory do
  before_each { Raft::Transport::InMemory.reset }

  it "delivers messages between nodes" do
    ch_a = Channel(Raft::RPC::Envelope).new(capacity: 16)
    ch_b = Channel(Raft::RPC::Envelope).new(capacity: 16)

    a = Raft::Transport::InMemory.new("a")
    b = Raft::Transport::InMemory.new("b")
    a.start(ch_a)
    b.start(ch_b)

    msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
    a.send("b", msg)

    envelope = ch_b.receive
    envelope.from.should eq("a")
    envelope.message.as(Raft::RPC::RequestVoteResponse).vote_granted?.should be_true
  end

  it "silently drops messages to unregistered peers" do
    ch = Channel(Raft::RPC::Envelope).new(capacity: 16)
    a = Raft::Transport::InMemory.new("a")
    a.start(ch)

    msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
    a.send("nonexistent", msg)
  end

  it "stop unregisters the node" do
    ch_a = Channel(Raft::RPC::Envelope).new(capacity: 16)
    ch_b = Channel(Raft::RPC::Envelope).new(capacity: 16)

    a = Raft::Transport::InMemory.new("a")
    b = Raft::Transport::InMemory.new("b")
    a.start(ch_a)
    b.start(ch_b)
    a.stop

    msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
    b.send("a", msg)

    receive_with_timeout(ch_a).should be_nil
  end

  it "reset clears all registrations" do
    ch = Channel(Raft::RPC::Envelope).new(capacity: 16)
    a = Raft::Transport::InMemory.new("a")
    a.start(ch)

    Raft::Transport::InMemory.reset

    b = Raft::Transport::InMemory.new("b")
    b_ch = Channel(Raft::RPC::Envelope).new(capacity: 16)
    b.start(b_ch)

    msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
    b.send("a", msg)

    receive_with_timeout(ch).should be_nil
  end

  describe "partition simulation" do
    it "blocks messages between partitioned nodes" do
      ch_b = Channel(Raft::RPC::Envelope).new(capacity: 16)

      a = Raft::Transport::InMemory.new("a")
      b = Raft::Transport::InMemory.new("b")
      a.start(Channel(Raft::RPC::Envelope).new(capacity: 16))
      b.start(ch_b)

      Raft::Transport::InMemory.partition("a", "b")

      msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
      a.send("b", msg)

      receive_with_timeout(ch_b).should be_nil
    end

    it "blocks in both directions" do
      ch_a = Channel(Raft::RPC::Envelope).new(capacity: 16)

      a = Raft::Transport::InMemory.new("a")
      b = Raft::Transport::InMemory.new("b")
      a.start(ch_a)
      b.start(Channel(Raft::RPC::Envelope).new(capacity: 16))

      Raft::Transport::InMemory.partition("a", "b")

      msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
      b.send("a", msg)

      receive_with_timeout(ch_a).should be_nil
    end

    it "heal restores message delivery" do
      ch_b = Channel(Raft::RPC::Envelope).new(capacity: 16)

      a = Raft::Transport::InMemory.new("a")
      b = Raft::Transport::InMemory.new("b")
      a.start(Channel(Raft::RPC::Envelope).new(capacity: 16))
      b.start(ch_b)

      Raft::Transport::InMemory.partition("a", "b")
      Raft::Transport::InMemory.heal("a", "b")

      msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
      a.send("b", msg)

      envelope = ch_b.receive
      envelope.message.as(Raft::RPC::RequestVoteResponse).vote_granted?.should be_true
    end
  end

  it "works across fibers" do
    ch = Channel(Raft::RPC::Envelope).new(capacity: 16)

    a = Raft::Transport::InMemory.new("a")
    b = Raft::Transport::InMemory.new("b")
    a.start(Channel(Raft::RPC::Envelope).new(capacity: 16))
    b.start(ch)

    spawn do
      msg = Raft::RPC::RequestVoteResponse.new(term: 42_u64, vote_granted: false)
      a.send("b", msg)
    end

    envelope = ch.receive
    envelope.from.should eq("a")
    envelope.message.as(Raft::RPC::RequestVoteResponse).term.should eq(42_u64)
  end
end
