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

  it "replayed responder frame fails with different initiator nonce" do
    cookie = "shared-secret"

    # Step 1: Perform a legitimate handshake and capture the responder's frame
    i_read, r_write = IO.pipe
    r_read, i_write = IO.pipe
    initiator_io = PipeIO.new(i_read, i_write)
    responder_io = PipeIO.new(r_read, r_write)

    done = Channel(Nil).new

    spawn do
      Raft::Transport::Handshake.respond(responder_io, cookie)
      done.send(nil)
    end

    # Initiator sends challenge manually to capture the response
    nonce1 = Random::Secure.random_bytes(32)
    hmac1 = OpenSSL::HMAC.digest(:sha256, cookie, nonce1)
    Raft::RPC::Codec.encode(Raft::RPC::Handshake.new(hmac: hmac1, nonce: nonce1), initiator_io)
    initiator_io.flush

    # Read the responder's frame (attacker captures this)
    captured = Raft::RPC::Codec.decode(initiator_io).as(Raft::RPC::Handshake)
    done.receive

    # Step 2: Replay the captured response to a new initiator connection.
    # The new initiator will have a different nonce, so verification must fail.
    i_read2, r_write2 = IO.pipe
    r_read2, i_write2 = IO.pipe
    new_initiator_io = PipeIO.new(i_read2, i_write2)
    fake_responder_io = PipeIO.new(r_read2, r_write2)

    # Fake responder replays the captured frame
    spawn do
      Raft::RPC::Codec.encode(captured, fake_responder_io)
      fake_responder_io.flush
    end

    # New initiator sends its own (different) nonce, then tries to verify
    # the replayed response — the HMAC won't match because it was bound
    # to nonce1, not the new nonce.
    expect_raises(Raft::Error::AuthenticationFailed) do
      Raft::Transport::Handshake.initiate(new_initiator_io, cookie)
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
