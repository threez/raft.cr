require "benchmark"
require "../src/raft"

class BenchStateMachine < Raft::StateMachine
  def apply(command : Bytes) : Bytes
    command
  end

  def snapshot : Bytes
    Bytes.empty
  end

  def restore(data : Bytes) : Nil
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

count = 0
start = Time.instant
elapsed = 0.0
while elapsed < 1.0
  leader.not_nil!.propose("bench-#{count}".to_slice)
  count += 1
  elapsed = (Time.instant - start).total_seconds
end

puts "  Sequential proposals in 1s: #{count} (#{count}/sec)"

nodes.each(&.stop)
Raft::Transport::InMemory.reset

# --- Concurrent Propose Throughput ---

puts "\n--- Concurrent Propose Throughput ---"

Raft::Transport::InMemory.reset
config = Raft::Config.new(
  election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25,
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

fiber_count = 10
total_ch = Channel(Int32).new(fiber_count)
bench_leader = leader.not_nil!
fiber_count.times do |fiber_id|
  spawn do
    local_count = 0
    start = Time.instant
    while (Time.instant - start).total_seconds < 1.0
      bench_leader.propose("conc-#{fiber_id}-#{local_count}".to_slice)
      local_count += 1
    end
    total_ch.send(local_count)
  end
end
total_count = fiber_count.times.sum { total_ch.receive }

puts "  #{fiber_count} concurrent fibers, 1s: #{total_count} proposals (#{total_count}/sec)"

nodes.each(&.stop)
Raft::Transport::InMemory.reset

puts "\n=== Done ==="
