require "socket"

# TCP transport with TLV framing, HMAC-SHA256 authentication, and connection pooling.
#
# Maintains one persistent TCP connection per peer, lazily established on the
# first `send`. Failed connections are retried with exponential backoff
# (100ms initial, doubling up to 10s). Inbound connections are authenticated
# via `Transport::Handshake` before any messages are exchanged.
class Raft::Transport::TCP < Raft::Transport
  @inbox : Channel(RPC::Envelope)?

  def initialize(@bind_address : String, @port : Int32,
                 @peer_addresses : Hash(String, {String, Int32}),
                 @cookie : String)
    @connections = Hash(String, TCPSocket).new
    @connection_mutex = Mutex.new
    @server = nil.as(TCPServer?)
    @running = false
    @backoff = Hash(String, Time::Span).new
    @last_attempt = Hash(String, Time).new
  end

  # Returns the actual port the server is listening on.
  #
  # Useful when binding to port 0 (OS-assigned) in tests.
  def actual_port : Int32
    @server.try(&.local_address.port) || @port
  end

  def start(inbox : Channel(RPC::Envelope)) : Nil
    @running = true
    @inbox = inbox
    server = TCPServer.new(@bind_address, @port)
    @server = server
    spawn accept_loop(server, inbox)
  end

  def send(peer_id : String, message : RPC::Message) : Nil
    return unless @running
    socket = get_or_connect(peer_id)
    return unless socket
    begin
      RPC::Codec.encode(message, socket)
      socket.flush
    rescue ex : IO::Error
      close_connection(peer_id)
    end
  end

  def stop : Nil
    @running = false
    @server.try(&.close)
    @connection_mutex.synchronize do
      @connections.each_value do |sock|
        sock.close rescue nil
      end
      @connections.clear
    end
  end

  private def accept_loop(server : TCPServer, inbox : Channel(RPC::Envelope)) : Nil
    loop do
      break unless @running
      begin
        socket = server.accept
        spawn handle_inbound(socket, inbox)
      rescue ex : IO::Error
        break unless @running
      end
    end
  end

  private def handle_inbound(socket : TCPSocket, inbox : Channel(RPC::Envelope)) : Nil
    Handshake.respond(socket, @cookie)
    # Identify peer by matching the remote address to known peers
    peer_id = identify_peer(socket) || "unknown"
    loop do
      msg = RPC::Codec.decode(socket)
      inbox.send(RPC::Envelope.new(from: peer_id, message: msg))
    end
  rescue ex : Raft::Error::AuthenticationFailed
    socket.close rescue nil
  rescue ex : IO::Error | Raft::Error
    socket.close rescue nil
  end

  private def identify_peer(socket : TCPSocket) : String?
    remote = socket.remote_address
    @peer_addresses.each do |peer_id, addr|
      host, _port = addr
      if remote.address == host || host == "127.0.0.1" || host == "0.0.0.0" || host == "localhost"
        return peer_id
      end
    end
    nil
  end

  private def get_or_connect(peer_id : String) : TCPSocket?
    @connection_mutex.synchronize do
      if socket = @connections[peer_id]?
        return socket unless socket.closed?
        @connections.delete(peer_id)
      end

      return nil if should_back_off?(peer_id)

      begin
        addr = @peer_addresses[peer_id]?
        return nil unless addr
        host, port = addr
        socket = TCPSocket.new(host, port, connect_timeout: 5.seconds)
        socket.tcp_nodelay = true
        Handshake.initiate(socket, @cookie)
        @connections[peer_id] = socket
        reset_backoff(peer_id)
        socket
      rescue
        record_failure(peer_id)
        nil
      end
    end
  end

  private def close_connection(peer_id : String) : Nil
    @connection_mutex.synchronize do
      if socket = @connections.delete(peer_id)
        socket.close rescue nil
      end
    end
  end

  private def should_back_off?(peer_id : String) : Bool
    if last = @last_attempt[peer_id]?
      delay = @backoff[peer_id]? || 100.milliseconds
      return Time.utc - last < delay
    end
    false
  end

  private def record_failure(peer_id : String) : Nil
    @last_attempt[peer_id] = Time.utc
    current = @backoff[peer_id]? || 100.milliseconds
    @backoff[peer_id] = {current * 2, 10.seconds}.min
  end

  private def reset_backoff(peer_id : String) : Nil
    @backoff.delete(peer_id)
    @last_attempt.delete(peer_id)
  end
end
