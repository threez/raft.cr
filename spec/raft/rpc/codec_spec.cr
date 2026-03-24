require "../../spec_helper"

private def roundtrip(msg : Raft::RPC::Message) : Raft::RPC::Message
  io = IO::Memory.new
  Raft::RPC::Codec.encode(msg, io)
  io.rewind
  Raft::RPC::Codec.decode(io)
end

describe Raft::RPC::Codec do
  describe "RequestVote" do
    it "roundtrips" do
      original = Raft::RPC::RequestVote.new(
        term: 5_u64,
        candidate_id: "node-1",
        last_log_index: 10_u64,
        last_log_term: 4_u64,
      )
      decoded = roundtrip(original).as(Raft::RPC::RequestVote)
      decoded.term.should eq(5_u64)
      decoded.candidate_id.should eq("node-1")
      decoded.last_log_index.should eq(10_u64)
      decoded.last_log_term.should eq(4_u64)
    end

    it "handles empty candidate_id" do
      original = Raft::RPC::RequestVote.new(term: 1_u64, candidate_id: "", last_log_index: 0_u64, last_log_term: 0_u64)
      decoded = roundtrip(original).as(Raft::RPC::RequestVote)
      decoded.candidate_id.should eq("")
    end
  end

  describe "RequestVoteResponse" do
    it "roundtrips with vote granted" do
      original = Raft::RPC::RequestVoteResponse.new(term: 3_u64, vote_granted: true)
      decoded = roundtrip(original).as(Raft::RPC::RequestVoteResponse)
      decoded.term.should eq(3_u64)
      decoded.vote_granted?.should be_true
    end

    it "roundtrips with vote denied" do
      original = Raft::RPC::RequestVoteResponse.new(term: 3_u64, vote_granted: false)
      decoded = roundtrip(original).as(Raft::RPC::RequestVoteResponse)
      decoded.vote_granted?.should be_false
    end
  end

  describe "AppendEntries" do
    it "roundtrips with empty entries" do
      original = Raft::RPC::AppendEntries.new(
        term: 2_u64,
        leader_id: "leader",
        prev_log_index: 0_u64,
        prev_log_term: 0_u64,
        entries: [] of Raft::Log::Entry,
        leader_commit: 0_u64,
      )
      decoded = roundtrip(original).as(Raft::RPC::AppendEntries)
      decoded.term.should eq(2_u64)
      decoded.leader_id.should eq("leader")
      decoded.entries.should be_empty
    end

    it "roundtrips with multiple entries" do
      entries = [
        Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "cmd1".to_slice),
        Raft::Log::Entry.new(index: 2_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Config, data: "cfg".to_slice),
        Raft::Log::Entry.new(index: 3_u64, term: 2_u64, entry_type: Raft::Log::EntryType::Noop),
      ]
      original = Raft::RPC::AppendEntries.new(
        term: 2_u64,
        leader_id: "leader",
        prev_log_index: 0_u64,
        prev_log_term: 0_u64,
        entries: entries,
        leader_commit: 1_u64,
      )
      decoded = roundtrip(original).as(Raft::RPC::AppendEntries)
      decoded.entries.size.should eq(3)
      decoded.entries[0].index.should eq(1_u64)
      decoded.entries[0].data.should eq("cmd1".to_slice)
      decoded.entries[1].entry_type.should eq(Raft::Log::EntryType::Config)
      decoded.entries[2].data.should eq(Bytes.empty)
      decoded.leader_commit.should eq(1_u64)
    end

    it "handles binary-safe data with zero bytes" do
      data = Bytes[0, 1, 0, 255, 0]
      entry = Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: data)
      original = Raft::RPC::AppendEntries.new(
        term: 1_u64, leader_id: "l", prev_log_index: 0_u64, prev_log_term: 0_u64,
        entries: [entry], leader_commit: 0_u64,
      )
      decoded = roundtrip(original).as(Raft::RPC::AppendEntries)
      decoded.entries[0].data.should eq(data)
    end
  end

  describe "AppendEntriesResponse" do
    it "roundtrips" do
      original = Raft::RPC::AppendEntriesResponse.new(term: 3_u64, success: true, match_index: 10_u64)
      decoded = roundtrip(original).as(Raft::RPC::AppendEntriesResponse)
      decoded.term.should eq(3_u64)
      decoded.success?.should be_true
      decoded.match_index.should eq(10_u64)
    end
  end

  describe "InstallSnapshot" do
    it "roundtrips with data" do
      data = Bytes.new(1024) { |i| (i % 256).to_u8 }
      original = Raft::RPC::InstallSnapshot.new(
        term: 7_u64,
        leader_id: "leader",
        last_included_index: 100_u64,
        last_included_term: 6_u64,
        offset: 512_u64,
        data: data,
        done: false,
      )
      decoded = roundtrip(original).as(Raft::RPC::InstallSnapshot)
      decoded.term.should eq(7_u64)
      decoded.leader_id.should eq("leader")
      decoded.last_included_index.should eq(100_u64)
      decoded.last_included_term.should eq(6_u64)
      decoded.offset.should eq(512_u64)
      decoded.data.should eq(data)
      decoded.done?.should be_false
    end

    it "roundtrips with empty data" do
      original = Raft::RPC::InstallSnapshot.new(
        term: 1_u64, leader_id: "l", last_included_index: 0_u64,
        last_included_term: 0_u64, offset: 0_u64, data: Bytes.empty, done: true,
      )
      decoded = roundtrip(original).as(Raft::RPC::InstallSnapshot)
      decoded.data.should eq(Bytes.empty)
      decoded.done?.should be_true
    end
  end

  describe "InstallSnapshotResponse" do
    it "roundtrips" do
      original = Raft::RPC::InstallSnapshotResponse.new(term: 7_u64)
      decoded = roundtrip(original).as(Raft::RPC::InstallSnapshotResponse)
      decoded.term.should eq(7_u64)
    end
  end

  it "handles max UInt64 values" do
    original = Raft::RPC::RequestVote.new(
      term: UInt64::MAX,
      candidate_id: "n",
      last_log_index: UInt64::MAX,
      last_log_term: UInt64::MAX,
    )
    decoded = roundtrip(original).as(Raft::RPC::RequestVote)
    decoded.term.should eq(UInt64::MAX)
    decoded.last_log_index.should eq(UInt64::MAX)
    decoded.last_log_term.should eq(UInt64::MAX)
  end

  describe "PreVote" do
    it "roundtrips" do
      original = Raft::RPC::PreVote.new(term: 3_u64, candidate_id: "node-2", last_log_index: 10_u64, last_log_term: 2_u64)
      decoded = roundtrip(original).as(Raft::RPC::PreVote)
      decoded.term.should eq(3_u64)
      decoded.candidate_id.should eq("node-2")
      decoded.last_log_index.should eq(10_u64)
      decoded.last_log_term.should eq(2_u64)
    end
  end

  describe "Handshake" do
    it "roundtrips" do
      hmac = Random::Secure.random_bytes(32)
      nonce = Random::Secure.random_bytes(32)
      original = Raft::RPC::Handshake.new(hmac: hmac, nonce: nonce)
      decoded = roundtrip(original).as(Raft::RPC::Handshake)
      decoded.hmac.should eq(hmac)
      decoded.nonce.should eq(nonce)
    end
  end

  describe "ErrorMessage" do
    it "roundtrips" do
      original = Raft::RPC::ErrorMessage.new("authentication failed")
      decoded = roundtrip(original).as(Raft::RPC::ErrorMessage)
      decoded.message.should eq("authentication failed")
    end

    it "roundtrips with empty message" do
      original = Raft::RPC::ErrorMessage.new("")
      decoded = roundtrip(original).as(Raft::RPC::ErrorMessage)
      decoded.message.should eq("")
    end
  end

  describe "PreVoteResponse" do
    it "roundtrips with vote granted" do
      original = Raft::RPC::PreVoteResponse.new(term: 3_u64, vote_granted: true)
      decoded = roundtrip(original).as(Raft::RPC::PreVoteResponse)
      decoded.term.should eq(3_u64)
      decoded.vote_granted?.should be_true
    end

    it "roundtrips with vote denied" do
      original = Raft::RPC::PreVoteResponse.new(term: 3_u64, vote_granted: false)
      decoded = roundtrip(original).as(Raft::RPC::PreVoteResponse)
      decoded.vote_granted?.should be_false
    end
  end

  it "decodes multiple messages from a stream" do
    io = IO::Memory.new
    msg1 = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
    msg2 = Raft::RPC::AppendEntriesResponse.new(term: 2_u64, success: false, match_index: 0_u64)
    Raft::RPC::Codec.encode(msg1, io)
    Raft::RPC::Codec.encode(msg2, io)
    io.rewind

    decoded1 = Raft::RPC::Codec.decode(io).as(Raft::RPC::RequestVoteResponse)
    decoded1.vote_granted?.should be_true

    decoded2 = Raft::RPC::Codec.decode(io).as(Raft::RPC::AppendEntriesResponse)
    decoded2.success?.should be_false
  end

  it "encode returns Bytes" do
    msg = Raft::RPC::RequestVoteResponse.new(term: 1_u64, vote_granted: true)
    bytes = Raft::RPC::Codec.encode(msg)
    bytes.should be_a(Bytes)
    bytes.size.should be > 0
  end
end
