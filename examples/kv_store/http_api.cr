require "http/server"
require "json"

# HTTP API wrapping a Raft node and KVStore state machine.
#
# Routes:
#   GET  /_leader  → 204 if leader, 307 redirect if follower, 503 if unknown
#   GET  /_status  → 200 + JSON with node state and metrics
#   PUT  /:key     → 201 on success, 307 if not leader
#   GET  /:key     → 200 + body, 404 if missing, 307 if not leader
#   DELETE /:key   → 204 on success, 307 if not leader
class HttpApi
  # Maps node IDs to their HTTP ports.
  HTTP_PORTS = {
    "node-1" => 8001,
    "node-2" => 8002,
    "node-3" => 8003,
  }

  def initialize(@node : Raft::Node, @kv_store : KVStore)
    @server = uninitialized HTTP::Server
  end

  def start(port : Int32) : Nil
    @server = HTTP::Server.new do |context|
      handle_request(context)
    end
    @server.bind_tcp("0.0.0.0", port)
    spawn { @server.listen }
    puts "HTTP server listening on http://0.0.0.0:#{port}"
  end

  def stop : Nil
    @server.close
  end

  private def handle_request(context : HTTP::Server::Context) : Nil
    path = context.request.path
    method = context.request.method

    if path == "/_leader"
      handle_leader_check(context)
      return
    end

    if path == "/_status"
      handle_status(context)
      return
    end

    key = path.lstrip('/')
    if key.empty?
      context.response.status = HTTP::Status::BAD_REQUEST
      context.response.print "key required"
      return
    end

    case method
    when "GET"    then handle_get(context, key)
    when "PUT"    then handle_put(context, key)
    when "DELETE" then handle_delete(context, key)
    else
      context.response.status = HTTP::Status::METHOD_NOT_ALLOWED
    end
  end

  private def handle_leader_check(context : HTTP::Server::Context) : Nil
    if @node.role.leader?
      # Redirect to own status so the client gets leader info
      context.response.status = HTTP::Status::TEMPORARY_REDIRECT
      context.response.headers["Location"] = "/_status"
    else
      redirect_to_leader(context, "/_status", @node.leader)
    end
  end

  private def handle_status(context : HTTP::Server::Context) : Nil
    metrics = @node.metrics
    status = {
      "node_id"             => @node.id,
      "role"                => metrics.role,
      "leader"              => @node.leader || "unknown",
      "term"                => metrics.term,
      "commit_index"        => metrics.commit_index,
      "elections_started"   => metrics.elections_started,
      "elections_won"       => metrics.elections_won,
      "proposals_committed" => metrics.proposals_committed,
      "entries_applied"     => metrics.entries_applied,
      "snapshots_installed" => metrics.snapshots_installed,
    }
    context.response.status = HTTP::Status::OK
    context.response.content_type = "application/json"
    context.response.print status.to_json
  end

  private def handle_get(context : HTTP::Server::Context, key : String) : Nil
    # Confirm leadership via quorum round, then read locally
    @node.read(Bytes.empty)
    if value = @kv_store.get(key)
      context.response.status = HTTP::Status::OK
      context.response.content_type = "application/octet-stream"
      context.response.write(value)
    else
      context.response.status = HTTP::Status::NOT_FOUND
    end
  rescue ex : Raft::Error::NotLeader
    redirect_to_leader(context, "/#{key}", ex.leader_hint)
  end

  private def handle_put(context : HTTP::Server::Context, key : String) : Nil
    body = context.request.body.try(&.gets_to_end) || ""
    command = KVStore.encode_put(key, body.to_slice)
    @node.propose(command)
    context.response.status = HTTP::Status::CREATED
  rescue ex : Raft::Error::NotLeader
    redirect_to_leader(context, "/#{key}", ex.leader_hint)
  end

  private def handle_delete(context : HTTP::Server::Context, key : String) : Nil
    command = KVStore.encode_delete(key)
    @node.propose(command)
    context.response.status = HTTP::Status::NO_CONTENT
  rescue ex : Raft::Error::NotLeader
    redirect_to_leader(context, "/#{key}", ex.leader_hint)
  end

  private def redirect_to_leader(context : HTTP::Server::Context, path : String, leader_hint : String?) : Nil
    # Use hint from exception, fall back to node's current leader knowledge
    leader = leader_hint || @node.leader
    if leader && (port = HTTP_PORTS[leader]?)
      context.response.status = HTTP::Status::TEMPORARY_REDIRECT
      context.response.headers["Location"] = "http://127.0.0.1:#{port}#{path}"
      context.response.content_type = "text/plain"
      context.response.print "redirect to leader #{leader} at http://127.0.0.1:#{port}#{path}"
    else
      context.response.status = HTTP::Status::SERVICE_UNAVAILABLE
      context.response.content_type = "text/plain"
      context.response.print "no leader elected yet"
    end
  end
end
