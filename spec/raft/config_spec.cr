require "../spec_helper"

describe Raft::Config do
  it "has sensible defaults" do
    config = Raft::Config.new
    config.election_timeout_min.should eq(150)
    config.election_timeout_max.should eq(300)
    config.heartbeat_interval.should eq(50)
    config.max_entries_per_rpc.should eq(100)
    config.cookie.should eq("")
  end

  it "accepts custom values" do
    config = Raft::Config.new(
      election_timeout_min: 200,
      election_timeout_max: 400,
      cookie: "secret",
    )
    config.election_timeout_min.should eq(200)
    config.election_timeout_max.should eq(400)
    config.cookie.should eq("secret")
    config.heartbeat_interval.should eq(50) # unchanged default
  end

  it "properties are mutable" do
    config = Raft::Config.new
    config.heartbeat_interval = 100
    config.heartbeat_interval.should eq(100)
  end
end
