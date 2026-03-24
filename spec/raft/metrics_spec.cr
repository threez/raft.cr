require "../spec_helper"

describe Raft::Metrics do
  it "has zero defaults" do
    metrics = Raft::Metrics.new
    metrics.elections_started.should eq(0_u64)
    metrics.elections_won.should eq(0_u64)
    metrics.proposals_committed.should eq(0_u64)
    metrics.entries_applied.should eq(0_u64)
    metrics.snapshots_installed.should eq(0_u64)
    metrics.term.should eq(0_u64)
    metrics.commit_index.should eq(0_u64)
    metrics.role.should eq("follower")
  end

  it "converts to hash" do
    metrics = Raft::Metrics.new
    metrics.elections_started = 5_u64
    hash = metrics.to_h
    hash["elections_started"].should eq(5_u64)
    hash["role"].should eq("follower")
  end

  it "tracks metrics through cluster operation" do
    Raft::Transport::InMemory.reset
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader

    leader.metrics.elections_won.should be > 0_u64
    leader.metrics.role.should eq("leader")

    leader.propose("test".to_slice)
    leader.metrics.proposals_committed.should be > 0_u64

    cluster.stop
  end
end
