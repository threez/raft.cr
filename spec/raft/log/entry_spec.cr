require "../../spec_helper"

describe Raft::Log::EntryType do
  it "has correct values" do
    Raft::Log::EntryType::Noop.value.should eq(0_u8)
    Raft::Log::EntryType::Op.value.should eq(1_u8)
    Raft::Log::EntryType::Config.value.should eq(2_u8)
  end
end

describe Raft::Log::Entry do
  it "stores all fields" do
    data = "hello".to_slice
    entry = Raft::Log::Entry.new(
      index: 1_u64,
      term: 3_u64,
      entry_type: Raft::Log::EntryType::Op,
      data: data,
    )
    entry.index.should eq(1_u64)
    entry.term.should eq(3_u64)
    entry.entry_type.should eq(Raft::Log::EntryType::Op)
    entry.data.should eq("hello".to_slice)
  end

  it "defaults data to empty" do
    entry = Raft::Log::Entry.new(
      index: 0_u64,
      term: 0_u64,
      entry_type: Raft::Log::EntryType::Noop,
    )
    entry.data.should eq(Bytes.empty)
  end
end
