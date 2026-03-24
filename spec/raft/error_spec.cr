require "../spec_helper"

describe Raft::Error do
  it "is an Exception" do
    Raft::Error.new("test").is_a?(Exception).should be_true
  end

  describe Raft::Error::NotLeader do
    it "includes leader hint in message" do
      err = Raft::Error::NotLeader.new("node-2")
      err.leader_hint.should eq("node-2")
      err.message.should eq("Not the leader, try node-2")
    end

    it "works without leader hint" do
      err = Raft::Error::NotLeader.new
      err.leader_hint.should be_nil
      err.message.should eq("Not the leader")
    end

    it "is a Raft::Error" do
      Raft::Error::NotLeader.new.is_a?(Raft::Error).should be_true
    end
  end

  describe Raft::Error::Timeout do
    it "can be created with a message" do
      err = Raft::Error::Timeout.new("timed out")
      err.message.should eq("timed out")
    end
  end

  describe Raft::Error::AuthenticationFailed do
    it "has a default message" do
      err = Raft::Error::AuthenticationFailed.new
      err.message.should eq("Authentication failed")
    end
  end

  it "all error types inherit from Raft::Error" do
    Raft::Error::Timeout.new.is_a?(Raft::Error).should be_true
    Raft::Error::Shutdown.new.is_a?(Raft::Error).should be_true
    Raft::Error::UnknownCommand.new.is_a?(Raft::Error).should be_true
    Raft::Error::LogCorrupted.new.is_a?(Raft::Error).should be_true
    Raft::Error::ConnectionFailed.new.is_a?(Raft::Error).should be_true
    Raft::Error::AuthenticationFailed.new.is_a?(Raft::Error).should be_true
  end
end
