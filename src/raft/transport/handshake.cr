require "openssl/hmac"

# Mutual HMAC-SHA256 cookie authentication for TCP connections.
#
# Uses standard TLV framing (type `0x00` for handshake, `0xFF` for error).
# Both sides exchange a challenge frame and verify the peer holds the same
# cookie. The responder's HMAC is bound to the initiator's nonce, preventing
# replay attacks.
#
# Protocol flow:
# 1. Initiator sends `Handshake(HMAC(cookie, nonce_i), nonce_i)`
# 2. Responder verifies initiator's HMAC
# 3. Responder sends `Handshake(HMAC(cookie, nonce_i || nonce_r), nonce_r)`
# 4. Initiator verifies responder's HMAC using both nonces
# 5. Both sides are now authenticated — normal TLV messages follow
module Raft::Transport::Handshake
  # Size of the random nonce in bytes.
  NONCE_SIZE = 32
  # Size of the HMAC-SHA256 digest in bytes.
  HMAC_SIZE = 32

  # Performs the initiator side of the handshake.
  #
  # Sends a TLV Handshake challenge, then verifies the responder's challenge
  # which must be bound to the initiator's nonce (replay protection).
  # Raises `Error::AuthenticationFailed` if the responder's HMAC is invalid
  # or if the responder sends an error frame.
  def self.initiate(io : IO, cookie : String) : Nil
    nonce = Random::Secure.random_bytes(NONCE_SIZE)
    hmac = OpenSSL::HMAC.digest(:sha256, cookie, nonce)
    RPC::Codec.encode(RPC::Handshake.new(hmac: hmac, nonce: nonce), io)
    io.flush

    verify_response!(io, cookie, nonce)
  end

  # Performs the responder side of the handshake.
  #
  # Verifies the initiator's TLV Handshake challenge, then sends its own
  # response with HMAC bound to the initiator's nonce (replay protection).
  # Raises `Error::AuthenticationFailed` if the initiator's HMAC is invalid.
  # Sends a TLV ErrorMessage frame before raising.
  def self.respond(io : IO, cookie : String) : Nil
    initiator_nonce = verify_challenge!(io, cookie)

    nonce = Random::Secure.random_bytes(NONCE_SIZE)
    # Bind response HMAC to initiator's nonce — prevents replay
    hmac_data = Bytes.new(NONCE_SIZE * 2)
    initiator_nonce.copy_to(hmac_data[0, NONCE_SIZE])
    nonce.copy_to(hmac_data[NONCE_SIZE, NONCE_SIZE])
    hmac = OpenSSL::HMAC.digest(:sha256, cookie, hmac_data)
    RPC::Codec.encode(RPC::Handshake.new(hmac: hmac, nonce: nonce), io)
    io.flush
  end

  # Verifies the initiator's challenge and returns its nonce.
  protected def self.verify_challenge!(io : IO, cookie : String) : Bytes
    msg = RPC::Codec.decode(io)

    case msg
    when RPC::Handshake
      expected_hmac = OpenSSL::HMAC.digest(:sha256, cookie, msg.nonce)
      unless constant_time_eq?(msg.hmac, expected_hmac)
        RPC::Codec.encode(RPC::ErrorMessage.new("authentication failed"), io)
        io.flush
        raise Raft::Error::AuthenticationFailed.new
      end
      msg.nonce
    when RPC::ErrorMessage
      raise Raft::Error::AuthenticationFailed.new(msg.message)
    else
      raise Raft::Error::AuthenticationFailed.new("unexpected message during handshake")
    end
  end

  # Verifies the responder's response, which must include a valid HMAC
  # bound to the initiator's nonce.
  protected def self.verify_response!(io : IO, cookie : String, initiator_nonce : Bytes) : Nil
    msg = RPC::Codec.decode(io)

    case msg
    when RPC::Handshake
      hmac_data = Bytes.new(NONCE_SIZE * 2)
      initiator_nonce.copy_to(hmac_data[0, NONCE_SIZE])
      msg.nonce.copy_to(hmac_data[NONCE_SIZE, NONCE_SIZE])
      expected_hmac = OpenSSL::HMAC.digest(:sha256, cookie, hmac_data)
      unless constant_time_eq?(msg.hmac, expected_hmac)
        raise Raft::Error::AuthenticationFailed.new
      end
    when RPC::ErrorMessage
      raise Raft::Error::AuthenticationFailed.new(msg.message)
    else
      raise Raft::Error::AuthenticationFailed.new("unexpected message during handshake")
    end
  end

  # :nodoc:
  protected def self.constant_time_eq?(a : Bytes, b : Bytes) : Bool
    return false if a.size != b.size
    result = 0_u8
    a.size.times { |idx| result |= a[idx] ^ b[idx] }
    result == 0
  end
end
