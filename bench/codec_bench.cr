require "./bench_helper"

puts "--- RPC Codec: Encode ---"

request_vote = Raft::RPC::RequestVote.new(
  term: 5_u64, candidate_id: "node-1", last_log_index: 100_u64, last_log_term: 4_u64,
)
request_vote_response = Raft::RPC::RequestVoteResponse.new(
  term: 5_u64, vote_granted: true,
)
append_entries = Raft::RPC::AppendEntries.new(
  term: 5_u64, leader_id: "leader", prev_log_index: 99_u64, prev_log_term: 4_u64,
  entries: (1..10).map { |idx|
    Raft::Log::Entry.new(index: idx.to_u64, term: 5_u64, entry_type: Raft::Log::EntryType::Op, data: "command-#{idx}".to_slice)
  },
  leader_commit: 95_u64,
)
append_entries_empty = Raft::RPC::AppendEntries.new(
  term: 5_u64, leader_id: "leader", prev_log_index: 99_u64, prev_log_term: 4_u64,
  entries: [] of Raft::Log::Entry, leader_commit: 95_u64,
)
append_entries_response = Raft::RPC::AppendEntriesResponse.new(
  term: 5_u64, success: true, match_index: 109_u64,
)
install_snapshot = Raft::RPC::InstallSnapshot.new(
  term: 5_u64, leader_id: "leader", last_included_index: 50_u64,
  last_included_term: 3_u64, offset: 0_u64, data: Bytes.new(4096), done: false,
)
install_snapshot_response = Raft::RPC::InstallSnapshotResponse.new(term: 5_u64)
pre_vote = Raft::RPC::PreVote.new(
  term: 6_u64, candidate_id: "node-2", last_log_index: 100_u64, last_log_term: 5_u64,
)
pre_vote_response = Raft::RPC::PreVoteResponse.new(term: 6_u64, vote_granted: true)
handshake = Raft::RPC::Handshake.new(hmac: Bytes.new(32, 0xAB_u8), nonce: Bytes.new(32, 0xCD_u8))
error_msg = Raft::RPC::ErrorMessage.new(message: "not leader")

Benchmark.ips do |bench|
  bench.report("RequestVote") { Raft::RPC::Codec.encode(request_vote) }
  bench.report("RequestVoteResponse") { Raft::RPC::Codec.encode(request_vote_response) }
  bench.report("AppendEntries (10)") { Raft::RPC::Codec.encode(append_entries) }
  bench.report("AppendEntries (hb)") { Raft::RPC::Codec.encode(append_entries_empty) }
  bench.report("AppendEntriesResponse") { Raft::RPC::Codec.encode(append_entries_response) }
  bench.report("InstallSnapshot (4KB)") { Raft::RPC::Codec.encode(install_snapshot) }
  bench.report("InstallSnapshotResp") { Raft::RPC::Codec.encode(install_snapshot_response) }
  bench.report("PreVote") { Raft::RPC::Codec.encode(pre_vote) }
  bench.report("PreVoteResponse") { Raft::RPC::Codec.encode(pre_vote_response) }
  bench.report("Handshake") { Raft::RPC::Codec.encode(handshake) }
  bench.report("ErrorMessage") { Raft::RPC::Codec.encode(error_msg) }
end

puts "\n--- RPC Codec: Decode ---"

encoded_msgs = {
  "RequestVote"           => Raft::RPC::Codec.encode(request_vote),
  "RequestVoteResponse"   => Raft::RPC::Codec.encode(request_vote_response),
  "AppendEntries (10)"    => Raft::RPC::Codec.encode(append_entries),
  "AppendEntries (hb)"    => Raft::RPC::Codec.encode(append_entries_empty),
  "AppendEntriesResponse" => Raft::RPC::Codec.encode(append_entries_response),
  "InstallSnapshot (4KB)" => Raft::RPC::Codec.encode(install_snapshot),
  "InstallSnapshotResp"   => Raft::RPC::Codec.encode(install_snapshot_response),
  "PreVote"               => Raft::RPC::Codec.encode(pre_vote),
  "PreVoteResponse"       => Raft::RPC::Codec.encode(pre_vote_response),
  "Handshake"             => Raft::RPC::Codec.encode(handshake),
  "ErrorMessage"          => Raft::RPC::Codec.encode(error_msg),
}

Benchmark.ips do |bench|
  encoded_msgs.each do |name, bytes|
    bench.report(name) do
      io = IO::Memory.new(bytes)
      Raft::RPC::Codec.decode(io)
    end
  end
end

puts "\n--- RPC Codec: Roundtrip ---"

codec_io = IO::Memory.new(8192)
Benchmark.ips do |bench|
  bench.report("RequestVote") do
    codec_io.clear
    Raft::RPC::Codec.encode(request_vote, codec_io)
    codec_io.rewind
    Raft::RPC::Codec.decode(codec_io)
  end
  bench.report("AppendEntries (10)") do
    codec_io.clear
    Raft::RPC::Codec.encode(append_entries, codec_io)
    codec_io.rewind
    Raft::RPC::Codec.decode(codec_io)
  end
  bench.report("AppendEntries (hb)") do
    codec_io.clear
    Raft::RPC::Codec.encode(append_entries_empty, codec_io)
    codec_io.rewind
    Raft::RPC::Codec.decode(codec_io)
  end
  bench.report("InstallSnapshot (4KB)") do
    codec_io.clear
    Raft::RPC::Codec.encode(install_snapshot, codec_io)
    codec_io.rewind
    Raft::RPC::Codec.decode(codec_io)
  end
end
