require "benchmark"
require "../src/raft"

Log.setup(:none)

class BenchStateMachine < Raft::StateMachine
  def apply(command : Bytes) : Bytes
    command
  end

  def snapshot : Bytes
    Bytes.empty
  end

  def restore(io : IO) : Nil
  end
end

puts "=== Raft.cr Benchmarks ===\n"

# --- RPC Codec Benchmarks ---

puts "--- RPC Codec ---"

request_vote = Raft::RPC::RequestVote.new(
  term: 5_u64, candidate_id: "node-1", last_log_index: 100_u64, last_log_term: 4_u64,
)
append_entries = Raft::RPC::AppendEntries.new(
  term: 5_u64, leader_id: "leader", prev_log_index: 99_u64, prev_log_term: 4_u64,
  entries: (1..10).map { |idx|
    Raft::Log::Entry.new(index: idx.to_u64, term: 5_u64, entry_type: Raft::Log::EntryType::Op, data: "command-#{idx}".to_slice)
  },
  leader_commit: 95_u64,
)

Benchmark.ips do |bench|
  bench.report("encode RequestVote") do
    Raft::RPC::Codec.encode(request_vote)
  end

  bench.report("encode AppendEntries (10 entries)") do
    Raft::RPC::Codec.encode(append_entries)
  end

  bench.report("roundtrip RequestVote") do
    io = IO::Memory.new
    Raft::RPC::Codec.encode(request_vote, io)
    io.rewind
    Raft::RPC::Codec.decode(io)
  end

  bench.report("roundtrip AppendEntries (10 entries)") do
    io = IO::Memory.new
    Raft::RPC::Codec.encode(append_entries, io)
    io.rewind
    Raft::RPC::Codec.decode(io)
  end
end

# --- Leader Election Latency ---

puts "\n--- Leader Election Latency ---"

election_times = Array(Float64).new
5.times do
  Raft::Transport::InMemory.reset
  config = Raft::Config.new(
    election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25,
  )
  ids = (1..3).map { |idx| "node-#{idx}" }
  nodes = ids.map do |id|
    peers = ids.reject { |peer| peer == id }
    Raft::Node.new(
      id: id, peers: peers,
      state_machine: BenchStateMachine.new,
      transport: Raft::Transport::InMemory.new(id),
      log: Raft::Log::InMemory.new, config: config,
    )
  end

  start = Time.instant
  nodes.each(&.start)
  loop do
    if nodes.any?(&.role.leader?)
      elapsed = (Time.instant - start).total_milliseconds
      election_times << elapsed
      break
    end
    sleep 1.milliseconds
  end
  nodes.each(&.stop)
end

avg = election_times.sum / election_times.size
min = election_times.min
max = election_times.max
puts "  3-node election: avg=#{avg.round(1)}ms min=#{min.round(1)}ms max=#{max.round(1)}ms (#{election_times.size} runs)"

# --- Propose Throughput ---

puts "\n--- Propose Throughput ---"

Raft::Transport::InMemory.reset
config = Raft::Config.new(
  election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25,
  snapshot_threshold: 0,
)
ids = (1..3).map { |idx| "bench-#{idx}" }
nodes = ids.map do |id|
  peers = ids.reject { |peer| peer == id }
  Raft::Node.new(
    id: id, peers: peers,
    state_machine: BenchStateMachine.new,
    transport: Raft::Transport::InMemory.new(id),
    log: Raft::Log::InMemory.new, config: config,
  )
end
nodes.each(&.start)

# Wait for leader
leader = nil
deadline = Time.instant + 3.seconds
loop do
  leader = nodes.find(&.role.leader?)
  break if leader
  raise "No leader" if Time.instant > deadline
  sleep 10.milliseconds
end

proposal_count = 2000
start = Time.instant
proposal_count.times do |idx|
  leader.not_nil!.propose("bench-#{idx}".to_slice)
  Fiber.yield
end
elapsed = (Time.instant - start).total_seconds

puts "  #{proposal_count} sequential proposals: #{elapsed.round(3)}s (#{(proposal_count / elapsed).round(0)}/sec)"

nodes.each(&.stop)
Raft::Transport::InMemory.reset

# --- Concurrent Propose Throughput ---

puts "\n--- Concurrent Propose Throughput ---"

Raft::Transport::InMemory.reset
config = Raft::Config.new(
  election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25,
  snapshot_threshold: 0, max_inflight_rpcs: 1, max_entries_per_rpc: 20,
)
ids = (1..3).map { |idx| "conc-#{idx}" }
nodes = ids.map do |id|
  peers = ids.reject { |peer| peer == id }
  Raft::Node.new(
    id: id, peers: peers,
    state_machine: BenchStateMachine.new,
    transport: Raft::Transport::InMemory.new(id),
    log: Raft::Log::InMemory.new, config: config,
  )
end
nodes.each(&.start)

leader = nil
deadline = Time.instant + 3.seconds
loop do
  leader = nodes.find(&.role.leader?)
  break if leader
  raise "No leader" if Time.instant > deadline
  sleep 10.milliseconds
end

fiber_count = 4
proposals_per_fiber = 50
total_ch = Channel(Int32).new(fiber_count)
bench_leader = leader.not_nil!
start = Time.instant
fiber_count.times do |fiber_id|
  spawn do
    proposals_per_fiber.times do |idx|
      bench_leader.propose("conc-#{fiber_id}-#{idx}".to_slice)
      Fiber.yield
    end
    total_ch.send(proposals_per_fiber)
  end
end
total_count = fiber_count.times.sum { total_ch.receive }
elapsed = (Time.instant - start).total_seconds

puts "  #{fiber_count} fibers x #{proposals_per_fiber} proposals: #{total_count} total (#{(total_count / elapsed).round(0)}/sec)"

nodes.each(&.stop)
Raft::Transport::InMemory.reset

puts "\n=== Done ==="
