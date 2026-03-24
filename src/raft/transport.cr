module Raft
  # Abstract base class for Raft node-to-node communication.
  #
  # Implementations deliver RPC messages between cluster nodes. The library
  # ships with `Transport::InMemory` for testing and `Transport::TCP` for
  # production use.
  abstract class Transport
    # Starts listening for incoming messages.
    #
    # Received messages are wrapped in `RPC::Envelope` (tagged with sender ID)
    # and pushed into the provided *inbox* channel.
    abstract def start(inbox : Channel(RPC::Envelope)) : Nil

    # Sends an RPC message to the peer identified by *peer_id*.
    #
    # Delivery is best-effort. If the peer is unreachable the message is
    # silently dropped — Raft's protocol-level retries handle the loss.
    abstract def send(peer_id : String, message : RPC::Message) : Nil

    # Shuts down the transport, closing all connections and listeners.
    abstract def stop : Nil
  end
end
