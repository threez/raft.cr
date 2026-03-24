require "./kv_store"
require "./http_api"

# Cluster topology: 3 nodes on localhost.
NODES = {
  "node-1" => {raft_port: 7001, http_port: 8001},
  "node-2" => {raft_port: 7002, http_port: 8002},
  "node-3" => {raft_port: 7003, http_port: 8003},
}

# Parse --node-id from command line
node_id = "node-1"
ARGV.each_with_index do |arg, idx|
  if arg == "--node-id" && idx + 1 < ARGV.size
    node_id = ARGV[idx + 1]
  end
end

unless NODES.has_key?(node_id)
  STDERR.puts "Unknown node ID: #{node_id}. Valid: #{NODES.keys.join(", ")}"
  exit 1
end

info = NODES[node_id]
peers = NODES.keys.reject { |nid| nid == node_id }

# Build peer address map for TCP transport
peer_addresses = Hash(String, {String, Int32}).new
peers.each do |peer_id|
  peer_info = NODES[peer_id]
  peer_addresses[peer_id] = {"127.0.0.1", peer_info[:raft_port]}
end

# Create data directory
data_dir = "./data/#{node_id}"
Dir.mkdir_p(data_dir) unless Dir.exists?(data_dir)

# Configure and create the Raft node
config = Raft::Config.new(
  cookie: "kv-store-example-cookie",
  election_timeout_min: 150,
  election_timeout_max: 300,
  heartbeat_interval: 50,
  snapshot_threshold: 10,
)

transport = Raft::Transport::TCP.new(
  bind_address: "127.0.0.1",
  port: info[:raft_port],
  peer_addresses: peer_addresses,
  cookie: config.cookie,
)

log = Raft::Log::File.new(data_dir)
kv_store = KVStore.new

node = Raft::Node.new(
  id: node_id,
  peers: peers,
  state_machine: kv_store,
  transport: transport,
  log: log,
  config: config,
)

# Start Raft node and HTTP server
node.start
puts "Raft node #{node_id} started (raft=:#{info[:raft_port]}, http=:#{info[:http_port]})"

api = HttpApi.new(node, kv_store)
api.start(info[:http_port])

# Wait for shutdown signal
shutdown = Channel(Nil).new
Signal::INT.trap { shutdown.send(nil) }
Signal::TERM.trap { shutdown.send(nil) }

puts "Press Ctrl+C to stop"
shutdown.receive

puts "\nShutting down..."
api.stop
node.stop
log.close
puts "Bye!"
