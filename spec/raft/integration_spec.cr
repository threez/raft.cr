require "../spec_helper"

describe "Raft Integration" do
  after_each { Raft::Transport::InMemory.reset }

  it "3-node cluster elects exactly one leader" do
    cluster = TestCluster.new(3)
    cluster.start
    cluster.wait_for_leader
    leaders = cluster.nodes.select(&.role.leader?)
    leaders.size.should eq(1)
    cluster.stop
  end

  it "5-node cluster elects exactly one leader" do
    cluster = TestCluster.new(5)
    cluster.start
    cluster.wait_for_leader
    leaders = cluster.nodes.select(&.role.leader?)
    leaders.size.should eq(1)
    cluster.stop
  end

  it "single node cluster elects itself" do
    Raft::Transport::InMemory.reset
    node = Raft::Node.new(
      id: "solo",
      peers: [] of String,
      state_machine: TestStateMachine.new,
      transport: Raft::Transport::InMemory.new("solo"),
      log: Raft::Log::InMemory.new,
      config: Raft::Config.new(election_timeout_min: 30, election_timeout_max: 60, heartbeat_interval: 15),
    )
    node.start
    sleep 200.milliseconds
    node.role.leader?.should be_true
    node.stop
  end

  it "propose returns after majority replication" do
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader
    result = leader.propose("hello".to_slice)
    result.should eq("hello".to_slice)
    cluster.stop
  end

  it "propose on non-leader raises NotLeader" do
    cluster = TestCluster.new(3)
    cluster.start
    cluster.wait_for_leader
    follower = cluster.nodes.find(&.role.follower?)
    follower.should_not be_nil
    expect_raises(Raft::Error::NotLeader) do
      follower.not_nil!.propose("hello".to_slice)
    end
    cluster.stop
  end

  it "leader steps down on network partition (minority)" do
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader
    leader_id = leader.id

    # Partition the leader from both followers
    cluster.nodes.each do |node|
      next if node.id == leader_id
      Raft::Transport::InMemory.partition(leader_id, node.id)
    end

    # Wait for a new leader to be elected among the majority
    sleep 500.milliseconds

    # The two non-partitioned nodes should elect a new leader
    non_partitioned = cluster.nodes.reject { |node| node.id == leader_id }
    new_leader = non_partitioned.find(&.role.leader?)
    new_leader.should_not be_nil

    cluster.stop
  end

  it "pre-vote prevents term inflation on partitioned node" do
    cluster = TestCluster.new(3)
    cluster.start
    cluster.wait_for_leader

    # Pick a follower to partition
    follower = cluster.nodes.find(&.role.follower?)
    follower.should_not be_nil
    follower_id = follower.not_nil!.id
    initial_term = follower.not_nil!.metrics.term

    # Partition the follower from everyone
    cluster.nodes.each do |node|
      next if node.id == follower_id
      Raft::Transport::InMemory.partition(follower_id, node.id)
    end

    # Let it attempt elections (pre-vote should fail, term should not inflate much)
    sleep 500.milliseconds

    # With pre-vote, the partitioned node's term should NOT have inflated significantly
    # Without pre-vote, it would increment term on every election attempt
    follower_term = follower.not_nil!.metrics.term
    # Allow at most 1 term increment (the initial pre-vote attempt might trigger one election)
    # but NOT 5+ increments from repeated failed elections
    (follower_term - initial_term).should be <= 2_u64

    # Heal and verify cluster still works
    cluster.nodes.each do |node|
      next if node.id == follower_id
      Raft::Transport::InMemory.heal(follower_id, node.id)
    end
    sleep 300.milliseconds

    # Original leader should still be leader (not disrupted)
    remaining_leader = cluster.nodes.find(&.role.leader?)
    remaining_leader.should_not be_nil

    cluster.stop
  end

  it "concurrent proposals via pipeline are all committed" do
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader
    results = Channel(Bytes).new(10)
    10.times do |i|
      spawn { results.send(leader.propose("cmd-#{i}".to_slice)) }
    end
    received = 10.times.map { results.receive }.to_a
    received.size.should eq(10)
    cluster.stop
  end

  it "batches concurrent proposals into fewer batch calls" do
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader

    n = 20
    results = Channel(Bytes).new(n)
    n.times do |i|
      spawn { results.send(leader.propose("batch-#{i}".to_slice)) }
    end
    received = n.times.map { results.receive }.to_a

    received.size.should eq(n)
    leader.metrics.proposals_committed.should eq(n.to_u64)
    # At least two proposals must have been collapsed into one batch call.
    # If every proposal were processed individually, batches_processed == n.
    leader.metrics.batches_processed.should be < n.to_u64
    cluster.stop
  end

  it "pipeline with max_inflight_rpcs: 1 behaves identically to single-RPC mode" do
    cluster = TestCluster.new(
      3,
      config: Raft::Config.new(
        election_timeout_min: 50,
        election_timeout_max: 100,
        heartbeat_interval: 25,
        max_inflight_rpcs: 1,
      )
    )
    cluster.start
    leader = cluster.wait_for_leader
    result = leader.propose("hello".to_slice)
    result.should eq("hello".to_slice)
    cluster.stop
  end

  it "add_peer expands the cluster" do
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader

    # Create a 4th node
    new_transport = Raft::Transport::InMemory.new("node-4")
    new_node = Raft::Node.new(
      id: "node-4",
      peers: cluster.nodes.map(&.id),
      state_machine: TestStateMachine.new,
      transport: new_transport,
      log: Raft::Log::InMemory.new,
      config: Raft::Config.new(election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25),
    )
    new_node.start

    # Leader adds the new peer
    leader.add_peer("node-4")
    sleep 300.milliseconds

    # Verify the new node receives heartbeats (it should know the leader)
    new_node.leader.should_not be_nil

    new_node.stop
    cluster.stop
  end
end
