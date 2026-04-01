require "./bench_helper"

puts "--- Log Append ---"

mem_idx = 0_u64
file_idx = 0_u64
file_dir = File.join(Dir.tempdir, "raft_bench_log_#{Process.pid}")
file_log = Raft::Log::File.new(file_dir, fsync: false)
payload = "bench-command".to_slice

Benchmark.ips do |bench|
  bench.report("InMemory append (1 entry)") do
    mem_log = Raft::Log::InMemory.new
    mem_idx += 1
    mem_log.append([Raft::Log::Entry.new(index: mem_idx, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: payload)])
  end

  bench.report("InMemory append (100 entries)") do
    mem_log = Raft::Log::InMemory.new
    base = mem_idx + 1
    entries = Array(Raft::Log::Entry).new(100) do |i|
      Raft::Log::Entry.new(index: base + i.to_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: payload)
    end
    mem_idx = base + 99
    mem_log.append(entries)
  end

  bench.report("File append (1 entry, no fsync)") do
    file_idx += 1
    file_log.append([Raft::Log::Entry.new(index: file_idx, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: payload)])
  end

  bench.report("File append (100 entries, no fsync)") do
    base = file_idx + 1
    entries = Array(Raft::Log::Entry).new(100) do |i|
      Raft::Log::Entry.new(index: base + i.to_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: payload)
    end
    file_idx = base + 99
    file_log.append(entries)
  end
end

file_log.close
FileUtils.rm_rf(file_dir)
