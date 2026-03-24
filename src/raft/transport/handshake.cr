require "openssl/hmac"

# Mutual HMAC-SHA256 cookie authentication for TCP connections.
#
# Uses standard TLV framing (type `0x00` for handshake, `0xFF` for error).
# Both sides exchange a challenge frame and verify the peer holds the same
# cookie. On failure, an `ErrorMessage` frame is sent before closing.
#
# Protocol flow:
# 1. Initiator sends TLV Handshake frame (hmac + nonce)
# 2. Responder verifies, then sends its own TLV Handshake frame
# 3. Initiator verifies the responder's frame
# 4. Both sides are now authenticated — normal TLV messages follow
module Raft::Transport::Handshake
  # Size of the random nonce in bytes.
  NONCE_SIZE = 32
  # Size of the HMAC-SHA256 digest in bytes.
  HMAC_SIZE = 32

  # Performs the initiator side of the handshake.
  #
  # Sends a TLV Handshake challenge, then verifies the responder's challenge.
  # Raises `Error::AuthenticationFailed` if the responder's HMAC is invalid
  # or if the responder sends an error frame.
  def self.initiate(io : IO, cookie : String) : Nil
    nonce = Random::Secure.random_bytes(NONCE_SIZE)
    hmac = OpenSSL::HMAC.digest(:sha256, cookie, nonce)
    RPC::Codec.encode(RPC::Handshake.new(hmac: hmac, nonce: nonce), io)
    io.flush

    verify!(io, cookie)
  end

  # Performs the responder side of the handshake.
  #
  # Verifies the initiator's TLV Handshake challenge, then sends its own.
  # Raises `Error::AuthenticationFailed` if the initiator's HMAC is invalid.
  # Sends a TLV ErrorMessage frame before raising.
  def self.respond(io : IO, cookie : String) : Nil
    verify!(io, cookie)

    nonce = Random::Secure.random_bytes(NONCE_SIZE)
    hmac = OpenSSL::HMAC.digest(:sha256, cookie, nonce)
    RPC::Codec.encode(RPC::Handshake.new(hmac: hmac, nonce: nonce), io)
    io.flush
  end

  # :nodoc:
  protected def self.verify!(io : IO, cookie : String) : Nil
    msg = RPC::Codec.decode(io)

    case msg
    when RPC::Handshake
      expected_hmac = OpenSSL::HMAC.digest(:sha256, cookie, msg.nonce)
      unless constant_time_eq?(msg.hmac, expected_hmac)
        RPC::Codec.encode(RPC::ErrorMessage.new("authentication failed"), io)
        io.flush
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
    a.size.times { |i| result |= a[i] ^ b[i] }
    result == 0
  end
end
