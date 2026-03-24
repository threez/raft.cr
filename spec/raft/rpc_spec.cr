require "../spec_helper"

describe Raft::RPC do
  describe Raft::RPC::Type do
    it "has correct values" do
      Raft::RPC::Type::RequestVote.value.should eq(0x01_u8)
      Raft::RPC::Type::RequestVoteResponse.value.should eq(0x02_u8)
      Raft::RPC::Type::AppendEntries.value.should eq(0x03_u8)
      Raft::RPC::Type::AppendEntriesResponse.value.should eq(0x04_u8)
      Raft::RPC::Type::InstallSnapshot.value.should eq(0x05_u8)
      Raft::RPC::Type::InstallSnapshotResponse.value.should eq(0x06_u8)
    end
  end

  describe Raft::RPC::RequestVote do
    it "stores all fields" do
      msg = Raft::RPC::RequestVote.new(
        term: 5_u64,
        candidate_id: "node-1",
        last_log_index: 10_u64,
        last_log_term: 4_u64,
      )
      msg.type.should eq(Raft::RPC::Type::RequestVote)
      msg.term.should eq(5_u64)
      msg.candidate_id.should eq("node-1")
      msg.last_log_index.should eq(10_u64)
      msg.last_log_term.should eq(4_u64)
    end
  end

  describe Raft::RPC::RequestVoteResponse do
    it "stores all fields" do
      msg = Raft::RPC::RequestVoteResponse.new(term: 5_u64, vote_granted: true)
      msg.type.should eq(Raft::RPC::Type::RequestVoteResponse)
      msg.term.should eq(5_u64)
      msg.vote_granted?.should be_true
    end
  end

  describe Raft::RPC::AppendEntries do
    it "stores all fields with entries" do
      entry = Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "cmd".to_slice)
      msg = Raft::RPC::AppendEntries.new(
        term: 2_u64,
        leader_id: "leader",
        prev_log_index: 0_u64,
        prev_log_term: 0_u64,
        entries: [entry],
        leader_commit: 0_u64,
      )
      msg.type.should eq(Raft::RPC::Type::AppendEntries)
      msg.entries.size.should eq(1)
      msg.leader_id.should eq("leader")
    end

    it "works with empty entries" do
      msg = Raft::RPC::AppendEntries.new(
        term: 1_u64,
        leader_id: "leader",
        prev_log_index: 0_u64,
        prev_log_term: 0_u64,
        entries: [] of Raft::Log::Entry,
        leader_commit: 0_u64,
      )
      msg.entries.should be_empty
    end
  end

  describe Raft::RPC::AppendEntriesResponse do
    it "stores all fields" do
      msg = Raft::RPC::AppendEntriesResponse.new(term: 3_u64, success: false, match_index: 5_u64)
      msg.type.should eq(Raft::RPC::Type::AppendEntriesResponse)
      msg.success?.should be_false
      msg.match_index.should eq(5_u64)
    end
  end

  describe Raft::RPC::InstallSnapshot do
    it "stores all fields" do
      msg = Raft::RPC::InstallSnapshot.new(
        term: 7_u64,
        leader_id: "leader",
        last_included_index: 100_u64,
        last_included_term: 6_u64,
        offset: 0_u64,
        data: Bytes[1, 2, 3],
        done: false,
      )
      msg.type.should eq(Raft::RPC::Type::InstallSnapshot)
      msg.data.should eq(Bytes[1, 2, 3])
      msg.done?.should be_false
    end
  end

  describe Raft::RPC::InstallSnapshotResponse do
    it "stores term" do
      msg = Raft::RPC::InstallSnapshotResponse.new(term: 7_u64)
      msg.type.should eq(Raft::RPC::Type::InstallSnapshotResponse)
      msg.term.should eq(7_u64)
    end
  end

  describe Raft::RPC::PreVote do
    it "stores all fields" do
      msg = Raft::RPC::PreVote.new(term: 2_u64, candidate_id: "node-1", last_log_index: 5_u64, last_log_term: 1_u64)
      msg.type.should eq(Raft::RPC::Type::PreVote)
      msg.term.should eq(2_u64)
      msg.candidate_id.should eq("node-1")
      msg.last_log_index.should eq(5_u64)
      msg.last_log_term.should eq(1_u64)
    end
  end

  describe Raft::RPC::PreVoteResponse do
    it "stores all fields" do
      msg = Raft::RPC::PreVoteResponse.new(term: 2_u64, vote_granted: true)
      msg.type.should eq(Raft::RPC::Type::PreVoteResponse)
      msg.term.should eq(2_u64)
      msg.vote_granted?.should be_true
    end
  end

  describe Raft::RPC::Handshake do
    it "stores hmac and nonce" do
      hmac = Bytes.new(32, 0xAB_u8)
      nonce = Bytes.new(32, 0xCD_u8)
      msg = Raft::RPC::Handshake.new(hmac: hmac, nonce: nonce)
      msg.type.should eq(Raft::RPC::Type::Handshake)
      msg.hmac.should eq(hmac)
      msg.nonce.should eq(nonce)
    end
  end

  describe Raft::RPC::ErrorMessage do
    it "stores message" do
      msg = Raft::RPC::ErrorMessage.new("auth failed")
      msg.type.should eq(Raft::RPC::Type::Error)
      msg.message.should eq("auth failed")
    end
  end

  it "Message union accepts all types" do
    msg : Raft::RPC::Message = Raft::RPC::RequestVote.new(term: 1_u64, candidate_id: "n", last_log_index: 0_u64, last_log_term: 0_u64)
    msg.is_a?(Raft::RPC::Message).should be_true

    msg = Raft::RPC::AppendEntriesResponse.new(term: 1_u64, success: true, match_index: 0_u64)
    msg.is_a?(Raft::RPC::Message).should be_true
  end
end
