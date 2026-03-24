require "../../spec_helper"
require "file_utils"

private def temp_dir : String
  dir = File.join(Dir.tempdir, "raft-test-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  dir
end

describe Raft::Log::File do
  it "empty store has zero last_index and last_term" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    store.last_index.should eq(0_u64)
    store.last_term.should eq(0_u64)
    store.get(1_u64).should be_nil
    store.close
    FileUtils.rm_rf(dir)
  end

  it "appends and retrieves entries" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    entries = (1_u64..3_u64).map do |idx|
      Raft::Log::Entry.new(index: idx, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "cmd#{idx}".to_slice)
    end
    store.append(entries)

    store.last_index.should eq(3_u64)
    store.last_term.should eq(1_u64)
    store.get(2_u64).not_nil!.data.should eq("cmd2".to_slice)
    store.term_at(3_u64).should eq(1_u64)
    store.close
    FileUtils.rm_rf(dir)
  end

  it "persists across close and reopen" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    store.append([Raft::Log::Entry.new(index: 1_u64, term: 5_u64, entry_type: Raft::Log::EntryType::Op, data: "persistent".to_slice)])
    store.close

    store2 = Raft::Log::File.new(dir)
    store2.last_index.should eq(1_u64)
    store2.last_term.should eq(5_u64)
    store2.get(1_u64).not_nil!.data.should eq("persistent".to_slice)
    store2.close
    FileUtils.rm_rf(dir)
  end

  it "truncates entries" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    entries = (1_u64..5_u64).map { |idx| Raft::Log::Entry.new(index: idx, term: 1_u64, entry_type: Raft::Log::EntryType::Op) }
    store.append(entries)

    store.truncate_from(3_u64)
    store.last_index.should eq(2_u64)
    store.get(3_u64).should be_nil
    store.get(2_u64).should_not be_nil
    store.close
    FileUtils.rm_rf(dir)
  end

  it "slices entries" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    entries = (1_u64..5_u64).map { |idx| Raft::Log::Entry.new(index: idx, term: 1_u64, entry_type: Raft::Log::EntryType::Op) }
    store.append(entries)

    result = store.slice(2_u64, 4_u64)
    result.size.should eq(3)
    result[0].index.should eq(2_u64)
    result[2].index.should eq(4_u64)
    store.close
    FileUtils.rm_rf(dir)
  end

  it "saves and loads metadata" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    store.save_metadata(Raft::Log::Metadata.new(current_term: 10_u64, voted_for: "node-3"))
    store.close

    store2 = Raft::Log::File.new(dir)
    meta = store2.load_metadata
    meta.current_term.should eq(10_u64)
    meta.voted_for.should eq("node-3")
    store2.close
    FileUtils.rm_rf(dir)
  end

  it "handles nil voted_for in metadata" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    store.save_metadata(Raft::Log::Metadata.new(current_term: 1_u64, voted_for: nil))
    store.close

    store2 = Raft::Log::File.new(dir)
    meta = store2.load_metadata
    meta.voted_for.should be_nil
    store2.close
    FileUtils.rm_rf(dir)
  end

  it "saves and loads snapshots" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    data = "snapshot-data".to_slice
    store.save_snapshot(5_u64, 3_u64, data)

    result = store.load_snapshot
    result.should_not be_nil
    idx, term, snap_data = result.not_nil!
    idx.should eq(5_u64)
    term.should eq(3_u64)
    snap_data.should eq(data)
    store.close
    FileUtils.rm_rf(dir)
  end

  it "compacts log after snapshot" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    entries = (1_u64..10_u64).map { |idx| Raft::Log::Entry.new(index: idx, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "d#{idx}".to_slice) }
    store.append(entries)

    store.save_snapshot(5_u64, 1_u64, "snap".to_slice)
    store.get(5_u64).should be_nil # compacted
    store.get(6_u64).should_not be_nil
    store.last_index.should eq(10_u64)
    store.close
    FileUtils.rm_rf(dir)
  end

  it "detects conflict and replaces entries" do
    dir = temp_dir
    store = Raft::Log::File.new(dir)
    store.append((1_u64..5_u64).map { |idx| Raft::Log::Entry.new(index: idx, term: 1_u64, entry_type: Raft::Log::EntryType::Op) })

    store.append([
      Raft::Log::Entry.new(index: 3_u64, term: 2_u64, entry_type: Raft::Log::EntryType::Op, data: "new".to_slice),
      Raft::Log::Entry.new(index: 4_u64, term: 2_u64, entry_type: Raft::Log::EntryType::Op),
    ])

    store.last_index.should eq(4_u64)
    store.term_at(3_u64).should eq(2_u64)
    store.get(3_u64).not_nil!.data.should eq("new".to_slice)
    store.get(5_u64).should be_nil
    store.close
    FileUtils.rm_rf(dir)
  end
end
