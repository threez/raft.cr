require "../spec_helper"

describe Raft::Log do
  describe "empty log" do
    it "has last_index 0" do
      log = Raft::Log::InMemory.new
      log.last_index.should eq(0_u64)
    end

    it "has last_term 0" do
      log = Raft::Log::InMemory.new
      log.last_term.should eq(0_u64)
    end

    it "get returns nil" do
      log = Raft::Log::InMemory.new
      log.get(1_u64).should be_nil
    end

    it "slice returns empty" do
      log = Raft::Log::InMemory.new
      log.slice(1_u64, 5_u64).should be_empty
    end

    it "term_at returns nil" do
      log = Raft::Log::InMemory.new
      log.term_at(1_u64).should be_nil
    end
  end

  describe "#append and #get" do
    it "appends and retrieves a single entry" do
      log = Raft::Log::InMemory.new
      entry = Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "cmd".to_slice)
      log.append([entry])

      result = log.get(1_u64)
      result.should_not be_nil
      result.not_nil!.term.should eq(1_u64)
      result.not_nil!.data.should eq("cmd".to_slice)
    end

    it "appends multiple entries" do
      log = Raft::Log::InMemory.new
      entries = (1_u64..3_u64).map do |i|
        Raft::Log::Entry.new(index: i, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "cmd#{i}".to_slice)
      end
      log.append(entries)

      log.last_index.should eq(3_u64)
      log.last_term.should eq(1_u64)
      log.get(2_u64).not_nil!.data.should eq("cmd2".to_slice)
    end
  end

  describe "#term_at" do
    it "returns correct term" do
      log = Raft::Log::InMemory.new
      log.append([
        Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op),
        Raft::Log::Entry.new(index: 2_u64, term: 3_u64, entry_type: Raft::Log::EntryType::Op),
      ])
      log.term_at(1_u64).should eq(1_u64)
      log.term_at(2_u64).should eq(3_u64)
      log.term_at(3_u64).should be_nil
    end
  end

  describe "#truncate_from" do
    it "removes entries from index onward" do
      log = Raft::Log::InMemory.new
      entries = (1_u64..5_u64).map do |i|
        Raft::Log::Entry.new(index: i, term: 1_u64, entry_type: Raft::Log::EntryType::Op)
      end
      log.append(entries)

      log.truncate_from(3_u64)
      log.last_index.should eq(2_u64)
      log.get(3_u64).should be_nil
      log.get(2_u64).should_not be_nil
    end

    it "truncate_from(1) empties the log" do
      log = Raft::Log::InMemory.new
      log.append([Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op)])
      log.truncate_from(1_u64)
      log.last_index.should eq(0_u64)
    end

    it "truncate beyond last_index is a no-op" do
      log = Raft::Log::InMemory.new
      log.append([Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op)])
      log.truncate_from(10_u64)
      log.last_index.should eq(1_u64)
    end
  end

  describe "#slice" do
    it "returns entries in inclusive range" do
      log = Raft::Log::InMemory.new
      entries = (1_u64..5_u64).map do |i|
        Raft::Log::Entry.new(index: i, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "#{i}".to_slice)
      end
      log.append(entries)

      result = log.slice(2_u64, 4_u64)
      result.size.should eq(3)
      result[0].index.should eq(2_u64)
      result[2].index.should eq(4_u64)
    end

    it "returns partial when range exceeds log" do
      log = Raft::Log::InMemory.new
      log.append([Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op)])
      result = log.slice(1_u64, 10_u64)
      result.size.should eq(1)
    end
  end

  describe "metadata" do
    it "defaults to term 0 and no vote" do
      log = Raft::Log::InMemory.new
      meta = log.load_metadata
      meta.current_term.should eq(0_u64)
      meta.voted_for.should be_nil
    end

    it "roundtrips save and load" do
      log = Raft::Log::InMemory.new
      log.save_metadata(Raft::Log::Metadata.new(current_term: 5_u64, voted_for: "node-1"))
      meta = log.load_metadata
      meta.current_term.should eq(5_u64)
      meta.voted_for.should eq("node-1")
    end
  end

  describe "conflict detection on append" do
    it "replaces conflicting entries with different term" do
      log = Raft::Log::InMemory.new
      # Initial entries at term 1
      log.append((1_u64..5_u64).map { |i|
        Raft::Log::Entry.new(index: i, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "old#{i}".to_slice)
      })

      # New entries at term 2 starting from index 3
      log.append([
        Raft::Log::Entry.new(index: 3_u64, term: 2_u64, entry_type: Raft::Log::EntryType::Op, data: "new3".to_slice),
        Raft::Log::Entry.new(index: 4_u64, term: 2_u64, entry_type: Raft::Log::EntryType::Op, data: "new4".to_slice),
      ])

      log.last_index.should eq(4_u64)
      log.get(1_u64).not_nil!.term.should eq(1_u64)
      log.get(2_u64).not_nil!.term.should eq(1_u64)
      log.get(3_u64).not_nil!.term.should eq(2_u64)
      log.get(3_u64).not_nil!.data.should eq("new3".to_slice)
      log.get(4_u64).not_nil!.term.should eq(2_u64)
      log.get(5_u64).should be_nil # was truncated
    end

    it "skips entries that already match" do
      log = Raft::Log::InMemory.new
      log.append([
        Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "a".to_slice),
        Raft::Log::Entry.new(index: 2_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "b".to_slice),
      ])

      # Re-append same entries (idempotent)
      log.append([
        Raft::Log::Entry.new(index: 1_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "a".to_slice),
        Raft::Log::Entry.new(index: 2_u64, term: 1_u64, entry_type: Raft::Log::EntryType::Op, data: "b".to_slice),
      ])

      log.last_index.should eq(2_u64)
    end
  end
end
