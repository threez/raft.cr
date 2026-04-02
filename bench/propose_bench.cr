require "./bench_helper"

payload = "bench-command".to_slice

# --- Channel Roundtrip ---

puts "--- Propose Path: Channel Roundtrip ---"

Benchmark.ips do |bench|
  bench.report("Channel.new(1)") do
    Channel(Raft::Node::ClientResponse).new(1)
  end

  bench.report("create + send + receive") do
    ch = Channel(Raft::Node::ClientResponse).new(1)
    spawn { ch.send(Raft::Node::ClientResponse.new(success: true, data: Bytes.empty)) }
    ch.receive
  end
end

# --- Log Append + Pending Queue ---

puts "\n--- Propose Path: Log Append + Pending Queue ---"

Benchmark.ips do |bench|
  bench.report("append 1 + push pending") do
    log = Raft::Log::InMemory.new
    pending = Deque(Raft::Node::PendingRequest).new
    ch = Channel(Raft::Node::ClientResponse).new(1)
    entry = Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: payload)
    log.append(entry)
    pending << Raft::Node::PendingRequest.new(1_u64, ch)
  end

  bench.report("append 10 + push pending") do
    log = Raft::Log::InMemory.new
    pending = Deque(Raft::Node::PendingRequest).new
    entries = Array(Raft::Log::Entry).new(10) do |i|
      Raft::Log::Entry.new(index: (i + 1).to_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: payload)
    end
    log.append(entries)
    10.times do |i|
      ch = Channel(Raft::Node::ClientResponse).new(1)
      pending << Raft::Node::PendingRequest.new((i + 1).to_u64, ch)
    end
  end
end

# --- Advance Commit Index ---

puts "\n--- Propose Path: Advance Commit Index ---"

Benchmark.ips do |bench|
  bench.report("3-node quorum sort") do
    match_index = {"node-2" => 100_u64, "node-3" => 95_u64}
    sorted = Array(UInt64).new(match_index.size + 1)
    match_index.each_value { |val| sorted << val }
    sorted << 100_u64 # self
    sorted.sort!
    quorum_size = (3 // 2) + 1
    _commit = sorted[sorted.size - quorum_size]
  end

  bench.report("5-node quorum sort") do
    match_index = {"n2" => 100_u64, "n3" => 95_u64, "n4" => 98_u64, "n5" => 90_u64}
    sorted = Array(UInt64).new(match_index.size + 1)
    match_index.each_value { |val| sorted << val }
    sorted << 100_u64
    sorted.sort!
    quorum_size = (5 // 2) + 1
    _commit = sorted[sorted.size - quorum_size]
  end
end

# --- State Machine Apply ---

puts "\n--- Propose Path: State Machine Apply ---"

sm = BenchStateMachine.new
commands_1 = [payload]
commands_10 = Array(Bytes).new(10) { payload }
commands_100 = Array(Bytes).new(100) { payload }

Benchmark.ips do |bench|
  bench.report("apply 1 command") { sm.apply(commands_1) }
  bench.report("apply 10 commands") { sm.apply(commands_10) }
  bench.report("apply 100 commands") { sm.apply(commands_100) }
end

# --- Resolve Pending (Deque shift) ---

puts "\n--- Propose Path: Resolve Pending ---"

Benchmark.ips do |bench|
  bench.report("resolve 10 pending") do
    pending = Deque(Raft::Node::PendingRequest).new
    channels = Array(Channel(Raft::Node::ClientResponse)).new(10) do
      Channel(Raft::Node::ClientResponse).new(1)
    end
    10.times do |i|
      pending << Raft::Node::PendingRequest.new((i + 1).to_u64, channels[i])
    end
    while req = pending.first?
      break if req.index > 10_u64
      pending.shift
      req.channel.send(Raft::Node::ClientResponse.new(success: true, data: Bytes.empty))
    end
  end
end

# --- Full Propose Latency Distribution ---

puts "\n--- Propose Path: Latency Distribution ---"

Raft::Transport::InMemory.reset
config = Raft::Config.new(
  election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25,
  snapshot_threshold: 0,
)
ids = (1..3).map { |idx| "lat-#{idx}" }
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

# Warmup
10.times do |idx|
  leader.not_nil!.propose("warmup-#{idx}".to_slice)
end

latencies = Array(Float64).new(500)
500.times do |idx|
  start = Time.instant
  leader.not_nil!.propose("lat-#{idx}".to_slice)
  latencies << (Time.instant - start).total_microseconds
end

latencies.sort!
avg = latencies.sum / latencies.size
p50 = latencies[latencies.size // 2]
p99 = latencies[(latencies.size * 0.99).to_i]
min_lat = latencies.first
max_lat = latencies.last

puts "  500 proposals: avg=#{avg.round(1)}µs p50=#{p50.round(1)}µs p99=#{p99.round(1)}µs min=#{min_lat.round(1)}µs max=#{max_lat.round(1)}µs"

nodes.each(&.stop)
Raft::Transport::InMemory.reset
