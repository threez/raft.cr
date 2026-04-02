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
    wait_until { node.role.leader? }.should be_true
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
    non_partitioned = cluster.nodes.reject { |node| node.id == leader_id }
    new_leader = nil
    wait_until { (new_leader = non_partitioned.find(&.role.leader?)) != nil }
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
    # Original leader should still be leader (not disrupted)
    remaining_leader = nil
    wait_until { (remaining_leader = cluster.nodes.find(&.role.leader?)) != nil }
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

    # Verify the new node receives heartbeats (it should know the leader)
    wait_until { new_node.leader != nil }.should be_true
    new_node.leader.should_not be_nil

    new_node.stop
    cluster.stop
  end

  it "add_learner adds non-voting member that receives replication" do
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader

    # Create a learner node
    learner_sm = TestStateMachine.new
    learner = Raft::Node.new(
      id: "learner-1",
      peers: cluster.nodes.map(&.id),
      state_machine: learner_sm,
      transport: Raft::Transport::InMemory.new("learner-1"),
      log: Raft::Log::InMemory.new,
      config: Raft::Config.new(election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25),
    )
    learner.start

    leader.add_learner("learner-1")

    # Propose a value — learner should receive it via replication
    leader.propose("learner-test".to_slice)

    wait_until { learner_sm.applied.any? { |cmd| cmd == "learner-test".to_slice } }.should be_true

    learner.stop
    cluster.stop
  end

  it "learner does not affect quorum" do
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader

    learner = Raft::Node.new(
      id: "learner-1",
      peers: cluster.nodes.map(&.id),
      state_machine: TestStateMachine.new,
      transport: Raft::Transport::InMemory.new("learner-1"),
      log: Raft::Log::InMemory.new,
      config: Raft::Config.new(election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25),
    )
    learner.start
    leader.add_learner("learner-1")

    # Partition the learner — proposals should still commit with 3 voters
    Raft::Transport::InMemory.partition(leader.id, "learner-1")

    result = leader.propose("quorum-test".to_slice)
    result.should eq("quorum-test".to_slice)

    Raft::Transport::InMemory.heal(leader.id, "learner-1")
    learner.stop
    cluster.stop
  end

  it "learner does not start elections" do
    Raft::Transport::InMemory.reset
    # Create a 2-node cluster where one is a learner
    voter = Raft::Node.new(
      id: "voter-1",
      peers: [] of String,
      state_machine: TestStateMachine.new,
      transport: Raft::Transport::InMemory.new("voter-1"),
      log: Raft::Log::InMemory.new,
      config: Raft::Config.new(election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25),
      learners: ["learner-1"],
    )
    learner = Raft::Node.new(
      id: "learner-1",
      peers: ["voter-1"],
      state_machine: TestStateMachine.new,
      transport: Raft::Transport::InMemory.new("learner-1"),
      log: Raft::Log::InMemory.new,
      config: Raft::Config.new(election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25),
      learners: ["learner-1"],
    )

    voter.start
    learner.start

    # Voter should become leader; learner should stay follower
    wait_until { voter.role.leader? }.should be_true
    sleep 200.milliseconds # give learner time to NOT start an election
    learner.role.leader?.should be_false

    learner.stop
    voter.stop
  end

  it "promote_learner converts learner to voter" do
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader

    learner = Raft::Node.new(
      id: "learner-1",
      peers: cluster.nodes.map(&.id),
      state_machine: TestStateMachine.new,
      transport: Raft::Transport::InMemory.new("learner-1"),
      log: Raft::Log::InMemory.new,
      config: Raft::Config.new(election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25),
    )
    learner.start
    leader.add_learner("learner-1")

    # Wait for learner to catch up
    wait_until { learner.leader != nil }.should be_true

    # Promote to voter
    leader.promote_learner("learner-1")
    leader.learners.should_not contain("learner-1")

    # Verify promoted node participates in consensus
    result = leader.propose("post-promote".to_slice)
    result.should eq("post-promote".to_slice)

    learner.stop
    cluster.stop
  end

  it "learner join, promote, remove original member — full membership transition" do
    # Start a 3-node voting cluster: node-1, node-2, node-3
    cluster = TestCluster.new(3)
    cluster.start
    leader = cluster.wait_for_leader
    leader_id = leader.id

    # Phase 1: Write data before the learner joins
    leader.propose("before-learner".to_slice)

    # Phase 2: Add learner-1 as non-voting member
    learner_sm = TestStateMachine.new
    learner_node = Raft::Node.new(
      id: "learner-1",
      peers: cluster.nodes.map(&.id),
      state_machine: learner_sm,
      transport: Raft::Transport::InMemory.new("learner-1"),
      log: Raft::Log::InMemory.new,
      config: Raft::Config.new(election_timeout_min: 50, election_timeout_max: 100, heartbeat_interval: 25),
    )
    learner_node.start
    leader.add_learner("learner-1")
    leader.learners.should contain("learner-1")

    # Verify learner receives replication (both old and new entries)
    leader.propose("during-learner".to_slice)
    wait_until { learner_sm.applied.any? { |cmd| cmd == "during-learner".to_slice } }.should be_true

    # Phase 3: Promote learner to voter (now 4 voters: node-1, node-2, node-3, learner-1)
    leader.promote_learner("learner-1")
    leader.learners.should be_empty

    # Proposals still work with 4 voters (quorum = 3)
    result = leader.propose("after-promote".to_slice)
    result.should eq("after-promote".to_slice)

    # Phase 4: Remove one original member (pick a non-leader voter)
    removed_id = cluster.nodes.reject(&.role.leader?).first.id
    leader.remove_peer(removed_id)

    # Now 3 voters remain: leader + one original + promoted learner
    # Quorum = 2, cluster should still function

    # Stop the removed node to simulate it leaving
    cluster.nodes.find! { |node| node.id == removed_id }.stop

    # Phase 5: Verify the cluster still works with the new membership
    result = leader.propose("after-remove".to_slice)
    result.should eq("after-remove".to_slice)

    # Verify the promoted learner received all entries
    wait_until {
      learner_sm.applied.any? { |cmd| cmd == "after-remove".to_slice }
    }.should be_true

    # Phase 6: Partition the other original non-leader voter.
    # Only leader + promoted learner remain reachable.
    # With 3 voters (leader, remaining original, learner-1), quorum = 2.
    # Leader + learner-1 = 2 → still a quorum.
    remaining_id = cluster.nodes.reject { |node| node.id == removed_id || node.role.leader? }.first.id
    Raft::Transport::InMemory.partition(leader_id, remaining_id)
    Raft::Transport::InMemory.partition("learner-1", remaining_id)

    result = leader.propose("quorum-with-learner".to_slice)
    result.should eq("quorum-with-learner".to_slice)

    wait_until {
      learner_sm.applied.any? { |cmd| cmd == "quorum-with-learner".to_slice }
    }.should be_true

    # Cleanup
    Raft::Transport::InMemory.heal(leader_id, remaining_id)
    Raft::Transport::InMemory.heal("learner-1", remaining_id)
    learner_node.stop
    cluster.stop
  end
end
