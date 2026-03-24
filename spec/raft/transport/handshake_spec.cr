require "../../spec_helper"

describe Raft::Transport::Handshake do
  it "succeeds with matching cookies" do
    i_read, r_write = IO.pipe
    r_read, i_write = IO.pipe
    initiator_io = PipeIO.new(i_read, i_write)
    responder_io = PipeIO.new(r_read, r_write)

    cookie = "shared-secret"
    done = Channel(Nil).new

    spawn do
      Raft::Transport::Handshake.respond(responder_io, cookie)
      done.send(nil)
    end

    Raft::Transport::Handshake.initiate(initiator_io, cookie)
    done.receive
  end

  it "responder rejects mismatched cookie" do
    i_read, r_write = IO.pipe
    r_read, i_write = IO.pipe
    initiator_io = PipeIO.new(i_read, i_write)
    responder_io = PipeIO.new(r_read, r_write)

    # Responder has wrong cookie — its verify! should raise
    expect_raises(Raft::Error::AuthenticationFailed) do
      # Run initiator in background so responder can read its challenge
      spawn do
        Raft::Transport::Handshake.initiate(initiator_io, "good-cookie")
      rescue
        # initiator will fail when pipe closes — expected
      end

      Raft::Transport::Handshake.respond(responder_io, "wrong-cookie")
    end
  end

  it "multiple handshakes on separate pipes all succeed" do
    3.times do
      i_read, r_write = IO.pipe
      r_read, i_write = IO.pipe
      initiator_io = PipeIO.new(i_read, i_write)
      responder_io = PipeIO.new(r_read, r_write)

      done = Channel(Nil).new
      spawn do
        Raft::Transport::Handshake.respond(responder_io, "cookie")
        done.send(nil)
      end
      Raft::Transport::Handshake.initiate(initiator_io, "cookie")
      done.receive
    end
  end
end
